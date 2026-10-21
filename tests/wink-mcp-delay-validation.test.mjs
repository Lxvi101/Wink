import assert from 'node:assert/strict';
import test from 'node:test';
import { WinkMCPWrapper } from '../wink-mcp.js';
test('zero delays are explicit rather than replaced by defaults', () => {
  const wrapper = new WinkMCPWrapper({ initialDelayMs: 0, maxDelayMs: 0, shutdownTimeoutMs: 0 });
  assert.equal(wrapper.initialDelayMs, 0);
  assert.equal(wrapper.maxDelayMs, 0);
  assert.equal(wrapper.shutdownTimeoutMs, 0);
});
test('invalid delays cannot become Node one-millisecond timers', () => {
  for (const name of ['initialDelayMs', 'maxDelayMs', 'shutdownTimeoutMs']) {
    for (const value of [-1, NaN, Infinity, 2_147_483_648, '50']) {
      assert.throws(() => new WinkMCPWrapper({ [name]: value }), RangeError);
    }
  }
});
