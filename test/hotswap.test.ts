import { randomUUID } from 'node:crypto';
import { createServer } from 'node:http';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import assert from 'node:assert/strict';
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import {
  CallToolRequestSchema,
  isInitializeRequest,
  ListToolsRequestSchema,
} from '@modelcontextprotocol/sdk/types.js';
import { RelayManager } from '../src/relay-manager.js';

test('hot-adds upstream server and calls localized tool', async (t) => {
  const upstream = await startMockMcpServer().catch((err: unknown) => {
    if (err && typeof err === 'object' && 'code' in err && err.code === 'EPERM') {
      t.skip('local listen is blocked by the current sandbox');
      return undefined;
    }
    throw err;
  });
  if (!upstream) return;
  const dir = await mkdtemp(join(tmpdir(), 'mcp-local-relay-'));
  const manager = new RelayManager({ servers: [] }, join(dir, 'config.json'));

  try {
    await manager.addServer({
      id: 'echo',
      remote: { type: 'streamable_http', url: upstream.url },
    });

    const names = manager.listTools().map((tool) => tool.name);
    assert.ok(names.includes('relay_add_server'));
    assert.ok(names.includes('echo__echo'));

    const result = await manager.callTool('echo__echo', { message: 'hello' });
    assert.deepEqual(result, {
      content: [{ type: 'text', text: 'hello' }],
    });
  } finally {
    await upstream.close();
    await rm(dir, { recursive: true, force: true });
  }
});

async function startMockMcpServer() {
  const transports = new Map<string, StreamableHTTPServerTransport>();
  const servers = new Map<string, Server>();
  const httpServer = createServer((req, res) => {
    void (async () => {
      const url = new URL(req.url || '/', `http://${req.headers.host}`);
      if (url.pathname !== '/mcp') {
        res.writeHead(404);
        res.end();
        return;
      }
      const header = req.headers['mcp-session-id'];
      const sid = Array.isArray(header) ? header[0] : header;
      let transport = sid ? transports.get(sid) : undefined;

      if (req.method === 'GET' || req.method === 'DELETE') {
        if (!transport) {
          res.writeHead(400);
          res.end();
          return;
        }
        await transport.handleRequest(req, res);
        return;
      }

      const chunks = [];
      for await (const chunk of req) chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
      const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));

      if (!transport) {
        assert.ok(isInitializeRequest(body));
        const server = new Server({ name: 'mock-upstream', version: '1.0.0' }, {
          capabilities: { tools: {} },
        });
        server.setRequestHandler(ListToolsRequestSchema, async () => ({
          tools: [
            {
              name: 'echo',
              description: 'Echo a message',
              inputSchema: {
                type: 'object',
                properties: { message: { type: 'string' } },
                required: ['message'],
              },
            },
          ],
        }));
        server.setRequestHandler(CallToolRequestSchema, async (request) => ({
          content: [{ type: 'text', text: String(request.params.arguments?.message || '') }],
        }));
        transport = new StreamableHTTPServerTransport({
          sessionIdGenerator: () => randomUUID(),
          onsessioninitialized: (newSessionId) => {
            transports.set(newSessionId, transport!);
            servers.set(newSessionId, server);
          },
        });
        await server.connect(transport);
      }

      await transport.handleRequest(req, res, body);
    })().catch((err) => {
      res.writeHead(500, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: err instanceof Error ? err.message : String(err) }));
    });
  });

  await new Promise<void>((resolve, reject) => {
    httpServer.once('error', reject);
    httpServer.listen(0, '127.0.0.1', () => {
      httpServer.off('error', reject);
      resolve();
    });
  });
  const address = httpServer.address();
  assert.ok(address && typeof address === 'object');
  return {
    url: `http://127.0.0.1:${address.port}/mcp`,
    close: async () => {
      for (const transport of transports.values()) await transport.close();
      for (const server of servers.values()) await server.close();
      await new Promise<void>((resolve) => httpServer.close(() => resolve()));
    },
  };
}
