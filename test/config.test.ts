import test from 'node:test';
import assert from 'node:assert/strict';
import { normalizeConfig } from '../src/config.js';

test('normalizes minimal config', () => {
  const config = normalizeConfig({
    servers: [
      {
        id: 'posthog',
        mode: 'posthog-cli',
        remote: { type: 'streamable_http', url: 'https://mcp.posthog.com/mcp' },
      },
    ],
  });
  assert.equal(config.admin?.host, '127.0.0.1');
  assert.equal(config.admin?.port, 3764);
  assert.equal(config.servers[0].enabled, true);
  assert.equal(config.servers[0].mode, 'posthog-cli');
});

test('rejects invalid server id', () => {
  assert.throws(() =>
    normalizeConfig({
      servers: [
        {
          id: '../bad',
          remote: { type: 'streamable_http', url: 'https://example.com/mcp' },
        },
      ],
    }),
  );
});
