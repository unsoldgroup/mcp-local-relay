import { randomUUID } from 'node:crypto';
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { dirname } from 'node:path';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import {
  CallToolRequestSchema,
  ErrorCode,
  ListToolsRequestSchema,
  McpError,
} from '@modelcontextprotocol/sdk/types.js';
import { loadEnvFile } from './env-file.js';
import { normalizeConfig, normalizeServer, toolsCachePath, writeConfig } from './config.js';
import type { RelayConfig, RelayServerConfig, RelayServerStatus, RelayStatus } from './types.js';

interface ToolDefinition {
  name: string;
  description?: string;
  inputSchema?: unknown;
  [key: string]: unknown;
}

interface RelayState {
  config: RelayServerConfig;
  client?: Client;
  connecting?: Promise<Client>;
  cachedTools: ToolDefinition[];
  cachedAt: number;
  lastRefreshAttemptAt: number;
  lastRefreshError: string;
}

export class RelayManager {
  private readonly states = new Map<string, RelayState>();
  private config: RelayConfig;
  private notifyListChanged: () => Promise<void> = async () => {};
  readonly startedAt = Date.now();

  constructor(
    config: RelayConfig,
    private readonly configPath: string,
  ) {
    this.config = normalizeConfig(config);
    for (const server of this.config.servers) {
      this.states.set(server.id, {
        config: server,
        cachedTools: [],
        cachedAt: 0,
        lastRefreshAttemptAt: 0,
        lastRefreshError: '',
      });
    }
  }

  setToolListChangedNotifier(fn: () => Promise<void>) {
    this.notifyListChanged = fn;
  }

  async start() {
    await Promise.all([...this.states.values()].map((state) => this.loadCache(state)));
    for (const state of this.states.values()) {
      if (state.config.enabled) void this.ensureToolsFresh(state);
    }
  }

  buildMcpServer() {
    const server = new Server(
      { name: 'mcp-local-relay', version: '0.1.0' },
      {
        capabilities: { tools: { listChanged: true } },
        instructions:
          'Persistent local MCP relay. Use relay_* tools to hot-add, refresh, enable, or inspect upstream MCP servers.',
      },
    );
    server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: this.listTools() }));
    server.setRequestHandler(CallToolRequestSchema, async (request) => {
      return await this.callTool(request.params.name, request.params.arguments || {});
    });
    return server;
  }

  status(sessions = 0): RelayStatus {
    const servers = [...this.states.values()].map((state): RelayServerStatus => ({
      id: state.config.id,
      name: state.config.name || state.config.id,
      enabled: state.config.enabled !== false,
      mode: state.config.mode || 'generic-cached',
      remoteUrl: state.config.remote.url,
      connected: Boolean(state.client),
      cachedTools: state.cachedTools.length,
      cachedAt: state.cachedAt,
      lastRefreshAttemptAt: state.lastRefreshAttemptAt,
      lastRefreshError: state.lastRefreshError,
    }));
    return {
      ok: servers.every((server) => !server.enabled || !server.lastRefreshError),
      name: 'mcp-local-relay',
      uptimeMs: Date.now() - this.startedAt,
      sessions,
      servers,
    };
  }

  listTools(): ToolDefinition[] {
    const tools = [...managementTools];
    for (const state of this.states.values()) {
      if (state.config.enabled === false) continue;
      void this.ensureToolsFresh(state);
      for (const tool of state.cachedTools) {
        tools.push(this.localizeTool(state.config.id, tool));
      }
    }
    return tools;
  }

  async callTool(name: string, args: unknown) {
    if (name.startsWith('relay_')) return await this.callManagementTool(name, args);
    const parsed = parseLocalToolName(name);
    if (!parsed) {
      throw new McpError(ErrorCode.InvalidParams, `Unknown relay tool: ${name}`);
    }
    const state = this.requireState(parsed.serverId);
    if (state.config.enabled === false) {
      throw new McpError(ErrorCode.InvalidParams, `Relay server disabled: ${parsed.serverId}`);
    }
    await this.ensureToolsFresh(state, true);
    const exists = state.cachedTools.some((tool) => tool.name === parsed.toolName);
    if (!exists) throw new McpError(ErrorCode.InvalidParams, `Unknown upstream tool: ${parsed.toolName}`);
    const client = await this.getClient(state);
    try {
      return await client.callTool(
        { name: parsed.toolName, arguments: args as Record<string, unknown> },
        undefined,
        { timeout: 120000 },
      );
    } catch (err) {
      this.resetClient(state);
      throw err;
    }
  }

  async addServer(input: unknown) {
    const server = normalizeServer(input as RelayServerConfig);
    if (this.states.has(server.id)) {
      throw new McpError(ErrorCode.InvalidParams, `Relay server already exists: ${server.id}`);
    }
    const state: RelayState = {
      config: server,
      cachedTools: [],
      cachedAt: 0,
      lastRefreshAttemptAt: 0,
      lastRefreshError: '',
    };
    await this.refreshTools(state);
    this.config.servers.push(server);
    await writeConfig(this.config, this.configPath);
    this.states.set(server.id, state);
    await this.notifyListChanged();
    return { content: textJson({ ok: true, id: server.id, cachedTools: state.cachedTools.length }) };
  }

  async updateServer(input: unknown) {
    const server = normalizeServer(input as RelayServerConfig);
    const existing = this.requireState(server.id);
    this.resetClient(existing);
    existing.config = server;
    existing.cachedTools = [];
    existing.cachedAt = 0;
    await this.refreshTools(existing);
    this.config.servers = this.config.servers.map((item) => (item.id === server.id ? server : item));
    await writeConfig(this.config, this.configPath);
    await this.notifyListChanged();
    return { content: textJson({ ok: true, id: server.id, cachedTools: existing.cachedTools.length }) };
  }

  async removeServer(input: unknown) {
    const id = readId(input);
    const state = this.requireState(id);
    this.resetClient(state);
    this.states.delete(id);
    this.config.servers = this.config.servers.filter((server) => server.id !== id);
    await writeConfig(this.config, this.configPath);
    await this.notifyListChanged();
    return { content: textJson({ ok: true, id }) };
  }

  async setEnabled(input: unknown, enabled: boolean) {
    const id = readId(input);
    const state = this.requireState(id);
    state.config.enabled = enabled;
    this.config.servers = this.config.servers.map((server) =>
      server.id === id ? { ...server, enabled } : server,
    );
    if (enabled) await this.ensureToolsFresh(state, true);
    else this.resetClient(state);
    await writeConfig(this.config, this.configPath);
    await this.notifyListChanged();
    return { content: textJson({ ok: true, id, enabled }) };
  }

  async refreshServer(input: unknown) {
    const id = readId(input);
    const state = this.requireState(id);
    await this.refreshTools(state);
    await this.notifyListChanged();
    return { content: textJson({ ok: true, id, cachedTools: state.cachedTools.length }) };
  }

  async validateServer(input: unknown) {
    const server = normalizeServer(input as RelayServerConfig);
    const state: RelayState = {
      config: server,
      cachedTools: [],
      cachedAt: 0,
      lastRefreshAttemptAt: 0,
      lastRefreshError: '',
    };
    await this.refreshTools(state);
    this.resetClient(state);
    return { content: textJson({ ok: true, id: server.id, tools: state.cachedTools.length }) };
  }

  private async callManagementTool(name: string, args: unknown) {
    switch (name) {
      case 'relay_list_servers':
      case 'relay_get_status':
        return { content: textJson(this.status()) };
      case 'relay_add_server':
        return await this.addServer(args);
      case 'relay_update_server':
        return await this.updateServer(args);
      case 'relay_remove_server':
        return await this.removeServer(args);
      case 'relay_enable_server':
        return await this.setEnabled(args, true);
      case 'relay_disable_server':
        return await this.setEnabled(args, false);
      case 'relay_refresh_tools':
        return await this.refreshServer(args);
      case 'relay_validate_server':
        return await this.validateServer(args);
      case 'relay_get_client_config':
        return {
          content: textJson({
            codex: {
              mcp_servers: {
                'mcp-local-relay': {
                  url: `http://${this.config.admin?.host || '127.0.0.1'}:${this.config.admin?.port || 3764}${this.config.admin?.mcpPath || '/mcp'}`,
                },
              },
            },
            claude: {
              mcpServers: {
                'mcp-local-relay': {
                  type: 'http',
                  url: `http://${this.config.admin?.host || '127.0.0.1'}:${this.config.admin?.port || 3764}${this.config.admin?.mcpPath || '/mcp'}`,
                },
              },
            },
          }),
        };
      default:
        throw new McpError(ErrorCode.InvalidParams, `Unknown management tool: ${name}`);
    }
  }

  private async getClient(state: RelayState) {
    if (state.client) return state.client;
    if (state.connecting) return await state.connecting;
    state.connecting = this.connectClient(state);
    try {
      return await state.connecting;
    } finally {
      state.connecting = undefined;
    }
  }

  private async connectClient(state: RelayState) {
    const env = await loadEnvFile(state.config.envFile);
    const headers = this.headersFor(state.config, env);
    const client = new Client({ name: `mcp-local-relay-${state.config.id}`, version: '0.1.0' }, {
      capabilities: {},
    });
    const transport = new StreamableHTTPClientTransport(new URL(state.config.remote.url), {
      requestInit: { headers },
      reconnectionOptions: {
        initialReconnectionDelay: 1000,
        maxReconnectionDelay: 10000,
        reconnectionDelayGrowFactor: 1.5,
        maxRetries: 3,
      },
    });
    transport.onerror = (err) => {
      state.lastRefreshError = err instanceof Error ? err.message : String(err);
    };
    await client.connect(transport, { timeout: 20000 });
    state.client = client;
    return client;
  }

  private headersFor(config: RelayServerConfig, env: Record<string, string>) {
    const headers: Record<string, string> = { ...(config.remote.headers || {}) };
    if (config.mode === 'posthog-cli') {
      headers['x-posthog-mcp-consumer'] ||= 'mcp-local-relay';
      headers['x-posthog-mcp-mode'] ||= 'cli';
      const token = env.POSTHOG_MCP_API_TOKEN || env.POSTHOG_PERSONAL_API_KEY || env.POSTHOG_API_KEY;
      if (token && !headers.Authorization) headers.Authorization = `Bearer ${token}`;
    }
    return headers;
  }

  private async ensureToolsFresh(state: RelayState, force = false) {
    const ttl = state.config.cache?.toolsTtlMs || 15 * 60 * 1000;
    if (!force && state.cachedTools.length > 0 && Date.now() - state.cachedAt < ttl) {
      return state.cachedTools;
    }
    try {
      return await this.refreshTools(state);
    } catch (err) {
      state.lastRefreshError = err instanceof Error ? err.message : String(err);
      return state.cachedTools;
    }
  }

  private async refreshTools(state: RelayState) {
    state.lastRefreshAttemptAt = Date.now();
    const client = await this.getClient(state);
    const result = await client.listTools(undefined, { timeout: 20000 });
    state.cachedTools = normalizeTools(result);
    state.cachedAt = Date.now();
    state.lastRefreshError = '';
    await this.saveCache(state);
    return state.cachedTools;
  }

  private async loadCache(state: RelayState) {
    try {
      const parsed = JSON.parse(await readFile(toolsCachePath(state.config.id), 'utf8'));
      state.cachedTools = normalizeTools(parsed);
      state.cachedAt = Number(parsed.cachedAt || 0);
    } catch {
      state.cachedTools = [];
      state.cachedAt = 0;
    }
  }

  private async saveCache(state: RelayState) {
    const path = toolsCachePath(state.config.id);
    await mkdir(dirname(path), { recursive: true });
    const tmp = `${path}.${process.pid}.${randomUUID()}.tmp`;
    await writeFile(tmp, JSON.stringify({ cachedAt: state.cachedAt, tools: state.cachedTools }, null, 2));
    await rename(tmp, path);
  }

  private resetClient(state: RelayState) {
    const client = state.client;
    state.client = undefined;
    state.connecting = undefined;
    if (client) void client.close().catch(() => {});
  }

  private requireState(id: string) {
    const state = this.states.get(id);
    if (!state) throw new McpError(ErrorCode.InvalidParams, `Unknown relay server: ${id}`);
    return state;
  }

  private localizeTool(serverId: string, tool: ToolDefinition): ToolDefinition {
    return {
      ...tool,
      name: localToolName(serverId, tool.name),
      description: `[${serverId}] ${tool.description || tool.name}`,
    };
  }
}

function normalizeTools(value: unknown): ToolDefinition[] {
  const input = value as { tools?: ToolDefinition[] };
  return Array.isArray(input?.tools)
    ? input.tools.filter((tool) => tool && typeof tool.name === 'string')
    : [];
}

function localToolName(serverId: string, toolName: string) {
  return `${serverId}__${toolName.replace(/[^a-zA-Z0-9_-]/g, '_')}`;
}

function parseLocalToolName(name: string) {
  const index = name.indexOf('__');
  if (index < 1) return undefined;
  return { serverId: name.slice(0, index), toolName: name.slice(index + 2) };
}

function readId(input: unknown) {
  const obj = input as { id?: unknown };
  if (!obj || typeof obj.id !== 'string') {
    throw new McpError(ErrorCode.InvalidParams, 'Expected { "id": string }');
  }
  return obj.id;
}

function textJson(value: unknown) {
  return [{ type: 'text' as const, text: JSON.stringify(value, null, 2) }];
}

const idOnlySchema = {
  type: 'object',
  properties: { id: { type: 'string' } },
  required: ['id'],
};

const serverSchema = {
  type: 'object',
  properties: {
    id: { type: 'string' },
    name: { type: 'string' },
    enabled: { type: 'boolean' },
    mode: { type: 'string', enum: ['generic-cached', 'posthog-cli'] },
    remote: {
      type: 'object',
      properties: {
        type: { type: 'string', enum: ['streamable_http'] },
        url: { type: 'string' },
        headers: { type: 'object', additionalProperties: { type: 'string' } },
      },
      required: ['type', 'url'],
    },
    envFile: { type: 'string' },
    cache: {
      type: 'object',
      properties: { toolsTtlMs: { type: 'number' } },
    },
  },
  required: ['id', 'remote'],
};

const managementTools: ToolDefinition[] = [
  {
    name: 'relay_list_servers',
    description: 'List configured upstream MCP servers and their health.',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'relay_get_status',
    description: 'Return aggregate relay status including cached tool counts and last refresh errors.',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'relay_add_server',
    description: 'Hot-add an upstream MCP server, validate it, cache tools, persist config, and emit tools/list_changed.',
    inputSchema: serverSchema,
  },
  {
    name: 'relay_update_server',
    description: 'Replace an existing upstream MCP server config after validation.',
    inputSchema: serverSchema,
  },
  {
    name: 'relay_remove_server',
    description: 'Remove an upstream MCP server and emit tools/list_changed.',
    inputSchema: idOnlySchema,
  },
  {
    name: 'relay_enable_server',
    description: 'Enable an upstream MCP server and refresh its tool cache.',
    inputSchema: idOnlySchema,
  },
  {
    name: 'relay_disable_server',
    description: 'Disable an upstream MCP server and hide its tools.',
    inputSchema: idOnlySchema,
  },
  {
    name: 'relay_refresh_tools',
    description: 'Refresh cached tools for one upstream MCP server.',
    inputSchema: idOnlySchema,
  },
  {
    name: 'relay_validate_server',
    description: 'Validate an upstream MCP server config without persisting it.',
    inputSchema: serverSchema,
  },
  {
    name: 'relay_get_client_config',
    description: 'Print Codex and Claude MCP config snippets for this local relay.',
    inputSchema: { type: 'object', properties: {} },
  },
];
