import { randomUUID } from 'node:crypto';
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { Server as McpServer } from '@modelcontextprotocol/sdk/server/index.js';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import { isInitializeRequest } from '@modelcontextprotocol/sdk/types.js';
import { readConfig } from './config.js';
import { launchctl } from './launchd.js';
import { RelayManager } from './relay-manager.js';

export interface ServeOptions {
  configPath: string;
}

export async function serve(options: ServeOptions) {
  const config = await readConfig(options.configPath);
  const host = config.admin?.host || '127.0.0.1';
  const port = Number(config.admin?.port || 3764);
  const mcpPath = config.admin?.mcpPath || '/mcp';
  const manager = new RelayManager(config, options.configPath);
  const transports = new Map<string, StreamableHTTPServerTransport>();
  const servers = new Map<string, McpServer>();

  manager.setToolListChangedNotifier(async () => {
    for (const server of servers.values()) {
      await server.notification({ method: 'notifications/tools/list_changed' }).catch(() => {});
    }
  });
  await manager.start();

  async function closeSession(transport: StreamableHTTPServerTransport) {
    const sid = transport.sessionId;
    if (!sid) return;
    transports.delete(sid);
    const server = servers.get(sid);
    servers.delete(sid);
    await server?.close();
  }

  async function handleMcp(req: IncomingMessage, res: ServerResponse, body: unknown) {
    const header = req.headers['mcp-session-id'];
    const sid = Array.isArray(header) ? header[0] : header;
    let transport = sid ? transports.get(sid) : undefined;

    if (!transport) {
      if (!isInitializeRequest(body)) {
        json(res, 400, {
          jsonrpc: '2.0',
          error: { code: -32000, message: 'Bad Request: initialize required' },
          id: null,
        });
        return;
      }
      const server = manager.buildMcpServer();
      transport = new StreamableHTTPServerTransport({
        sessionIdGenerator: () => randomUUID(),
        onsessioninitialized: (newSessionId) => {
          transports.set(newSessionId, transport!);
          servers.set(newSessionId, server);
        },
      });
      transport.onclose = () => {
        void closeSession(transport!);
      };
      await server.connect(transport);
    }

    await transport.handleRequest(req, res, body);
  }

  const httpServer = createServer((req, res) => {
    void (async () => {
      const url = new URL(req.url || '/', `http://${req.headers.host || `${host}:${port}`}`);

      if (req.method === 'GET' && url.pathname === '/healthz') {
        json(res, 200, { ok: manager.status(transports.size).ok });
        return;
      }
      if (req.method === 'GET' && url.pathname === '/status') {
        json(res, 200, manager.status(transports.size));
        return;
      }
      if (req.method === 'GET' && url.pathname === '/menu') {
        json(res, 200, { ok: true, servers: await manager.menuStatuses() });
        return;
      }
      const serverMenuMatch = url.pathname.match(/^\/servers\/([^/]+)\/menu$/);
      if (req.method === 'GET' && serverMenuMatch) {
        json(res, 200, await manager.menuStatus(decodeURIComponent(serverMenuMatch[1])));
        return;
      }
      const actionMatch = url.pathname.match(/^\/servers\/([^/]+)\/menu\/actions\/([^/]+)$/);
      if (req.method === 'POST' && actionMatch) {
        const body = await readJsonBody(req);
        const result = await manager.callMenuAction(
          decodeURIComponent(actionMatch[1]),
          decodeURIComponent(actionMatch[2]),
          body,
        );
        json(res, 200, result);
        return;
      }
      if (req.method === 'GET' && url.pathname === '/client-config') {
        json(res, 200, clientConfig(host, port, mcpPath));
        return;
      }
      if (req.method === 'POST' && url.pathname === '/restart') {
        json(res, 202, { ok: true, restarting: true });
        setTimeout(() => {
          void launchctl('kickstart').catch(() => {
            process.exit(0);
          });
        }, 25);
        return;
      }
      const refreshMatch = url.pathname.match(/^\/servers\/([^/]+)\/refresh$/);
      if (req.method === 'POST' && refreshMatch) {
        await manager.refreshServer({ id: decodeURIComponent(refreshMatch[1]) });
        json(res, 200, { ok: true, id: decodeURIComponent(refreshMatch[1]) });
        return;
      }
      if (url.pathname !== mcpPath) {
        json(res, 404, { error: 'not_found' });
        return;
      }
      if (req.method === 'GET' || req.method === 'DELETE') {
        const header = req.headers['mcp-session-id'];
        const sid = Array.isArray(header) ? header[0] : header;
        const transport = sid ? transports.get(sid) : undefined;
        if (!transport) {
          json(res, 400, {
            jsonrpc: '2.0',
            error: { code: -32000, message: 'Bad Request: unknown session' },
            id: null,
          });
          return;
        }
        await transport.handleRequest(req, res);
        return;
      }
      if (req.method !== 'POST') {
        res.writeHead(405, { allow: 'GET, POST, DELETE' });
        res.end();
        return;
      }
      await handleMcp(req, res, await readJsonBody(req));
    })().catch((err) => {
      const message = err instanceof Error ? err.message : String(err);
      if (!res.headersSent) res.writeHead(500, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ jsonrpc: '2.0', error: { code: -32603, message }, id: null }));
    });
  });

  async function shutdown() {
    for (const transport of transports.values()) await transport.close();
    for (const server of servers.values()) await server.close();
    httpServer.close(() => process.exit(0));
  }
  process.on('SIGINT', () => void shutdown());
  process.on('SIGTERM', () => void shutdown());

  await new Promise<void>((resolve) => httpServer.listen(port, host, resolve));
  process.stderr.write(`mcp-local-relay: listening on http://${host}:${port}${mcpPath}\n`);
  return { httpServer, manager };
}

function json(res: ServerResponse, status: number, body: unknown) {
  res.writeHead(status, { 'content-type': 'application/json' });
  res.end(JSON.stringify(body));
}

async function readJsonBody(req: IncomingMessage) {
  const chunks = [];
  for await (const chunk of req) chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
  const raw = Buffer.concat(chunks).toString('utf8');
  return raw.length ? JSON.parse(raw) : undefined;
}

function clientConfig(host: string, port: number, mcpPath: string) {
  const url = `http://${host}:${port}${mcpPath}`;
  return {
    codex: {
      mcp_servers: {
        'mcp-local-relay': { url },
      },
    },
    claude: {
      mcpServers: {
        'mcp-local-relay': { type: 'http', url },
      },
    },
  };
}
