// Run a sequence of tool calls against one peekaboo-cua process.
// usage: node scripts/mcp-steps.mjs <bin> '<json array of [tool, args, delayAfterMs?]>'
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
const [bin, stepsJson] = process.argv.slice(2);
const child = spawn(bin, [], { stdio: ['pipe', 'pipe', 'inherit'] });
const rl = createInterface({ input: child.stdout });
const pending = new Map(); let id = 1;
rl.on('line', (l) => { const m = JSON.parse(l); pending.get(m.id)?.(m); });
const rpc = (method, params = {}) => new Promise((r) => { const i = id++; pending.set(i, r); child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: i, method, params }) + '\n'); });
await rpc('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'steps', version: '0' } });
let lastText = '';
for (const [tool, rawArgs, delay] of JSON.parse(stepsJson)) {
  // "$id:Seven" resolves to the index of the element with that identifier in the last text.
  const args = JSON.parse(JSON.stringify(rawArgs), (k, v) => typeof v === 'string' && v.startsWith('$id:')
    ? Number(lastText.match(new RegExp(`\\[(\\d+)\\][^\\n]*id=${v.slice(4)}\\b`))[1]) : v);
  const t = performance.now();
  const res = await rpc('tools/call', { name: tool, arguments: args });
  const text = res.result.content.find((c) => c.type === 'text')?.text ?? '';
  if (tool === 'get_app_state') lastText = text;
  console.log(`## ${tool} ${JSON.stringify(args)} -> ${Math.round(performance.now() - t)} ms${res.result.isError ? ' ERROR' : ''}\n${text.split('\n').slice(0, 14).join('\n')}`);
  if (delay) await new Promise((r) => setTimeout(r, delay));
}
child.kill();
