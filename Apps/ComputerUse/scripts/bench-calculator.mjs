// Drives wink-cua over MCP stdio: 7 + 8 = on Calculator, with timings.
// usage: node scripts/bench-calculator.mjs [path/to/wink-cua] [trials]
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';

const bin = process.argv[2] ?? new URL('../.build/release/wink-cua', import.meta.url).pathname;
const trials = Number(process.argv[3] ?? 3);
const child = spawn(bin, [], { stdio: ['pipe', 'pipe', 'inherit'] });
const rl = createInterface({ input: child.stdout });
const pending = new Map();
let nextId = 1;
rl.on('line', (line) => {
  const msg = JSON.parse(line);
  pending.get(msg.id)?.(msg);
  pending.delete(msg.id);
});
const rpc = (method, params = {}) => new Promise((resolve) => {
  const id = nextId++;
  pending.set(id, resolve);
  child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
});
const call = async (name, args) => {
  const t = performance.now();
  const res = await rpc('tools/call', { name, arguments: args });
  const ms = performance.now() - t;
  const text = res.result.content.find((c) => c.type === 'text')?.text ?? '';
  const image = res.result.content.find((c) => c.type === 'image');
  return { ms, text, isError: res.result.isError, imageBytes: image ? Buffer.from(image.data, 'base64').length : 0 };
};
const median = (xs) => [...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)];

await rpc('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'bench', version: '0' } });
const app = process.env.CUA_APP ?? 'com.apple.calculator';
const first = await call('get_app_state', { app, full: true });
const index = (text, id) => Number(text.match(new RegExp(`\\[(\\d+)\\][^\\n]*id=(${id})\\b`))[1]);
const keysFrom = (text) => ({ seven: index(text, 'Seven'), plus: index(text, 'Add'), eight: index(text, 'Eight'), equals: index(text, 'Equals') });
const warmFull = [], warmDiff = [], clickAct = [], clickTotal = [], arith = [];
for (let i = 0; i < 5; i++) warmFull.push((await call('get_app_state', { app, full: true })).ms);
for (let i = 0; i < 5; i++) warmDiff.push((await call('get_app_state', { app, screenshot: false })).ms);
let lastText = '';
for (let t = 0; t < trials; t++) {
  await call('press_key', { app, key: 'Escape Escape', observe: false });
  const keys = keysFrom((await call('get_app_state', { app, full: true, screenshot: false })).text);
  const start = performance.now();
  for (const k of ['seven', 'plus', 'eight', 'equals']) {
    const r = await call('click', { app, element_index: keys[k] });
    if (r.isError) throw new Error(r.text);
    clickTotal.push(r.ms); process.env.VERBOSE && console.log(k, Math.round(r.ms), r.text.split("\n").slice(4).join(" | ").slice(0, 300));
    clickAct.push(Number(r.text.match(/\((\d+) ms\)/)[1]));
    lastText = r.text;
  }
  arith.push(performance.now() - start);
  const state = await call('get_app_state', { app, screenshot: false, full: true });
  const ok = /value="‎?15‎?"/.test(state.text);
  console.log(`trial ${t + 1}: result 15 ${ok ? 'OK' : 'MISSING'}; ${Math.round(arith.at(-1))} ms for 4 clicks incl. settled diffs`);
}
console.log({
  firstFullStateMs: Math.round(first.ms), firstImageBytes: first.imageBytes, fullTextChars: first.text.length,
  warmFullWithScreenshotMs: Math.round(median(warmFull)), warmDiffNoScreenshotMs: Math.round(median(warmDiff)),
  clickDispatchMs: median(clickAct), clickWithSettledDiffMs: Math.round(median(clickTotal)),
  fourClickArithmeticMs: Math.round(median(arith)),
});
console.log('--- last click result ---\n' + lastText);
child.kill();
