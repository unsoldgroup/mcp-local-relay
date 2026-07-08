import { mkdir, readFile, rename, stat, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { defaultConfigPath, stateDir } from './paths.js';
import type {
  RelayConfig,
  RelayMenuAction,
  RelayMenuActionMethod,
  RelayMenuConfig,
  RelayMode,
  RelayServerConfig,
} from './types.js';

export const defaultAdmin = {
  host: '127.0.0.1',
  port: 3764,
  mcpPath: '/mcp',
};

export function normalizeMode(mode: unknown): RelayMode {
  if (mode === 'posthog-cli') return 'posthog-cli';
  return 'generic-cached';
}

export function normalizeConfig(raw: unknown): RelayConfig {
  if (!raw || typeof raw !== 'object') {
    throw new Error('Config must be a JSON object');
  }
  const input = raw as Partial<RelayConfig>;
  const servers = Array.isArray(input.servers) ? input.servers.map(normalizeServer) : [];
  return {
    admin: {
      host: input.admin?.host || defaultAdmin.host,
      port: Number(input.admin?.port || defaultAdmin.port),
      mcpPath: input.admin?.mcpPath || defaultAdmin.mcpPath,
    },
    servers,
  };
}

export function normalizeServer(input: RelayServerConfig): RelayServerConfig {
  if (!input || typeof input !== 'object') throw new Error('Server config must be an object');
  if (!input.id || !/^[a-zA-Z0-9_-]+$/.test(input.id)) {
    throw new Error('Server id is required and must contain only letters, numbers, _ or -');
  }
  if (!input.remote || input.remote.type !== 'streamable_http') {
    throw new Error(`Server ${input.id} must use remote.type "streamable_http"`);
  }
  if (!input.remote.url) throw new Error(`Server ${input.id} remote.url is required`);
  new URL(input.remote.url);
  return {
    id: input.id,
    name: input.name || input.id,
    enabled: input.enabled !== false,
    mode: normalizeMode(input.mode),
    remote: {
      type: 'streamable_http',
      url: input.remote.url,
      headers: input.remote.headers || {},
    },
    envFile: input.envFile,
    cache: {
      toolsTtlMs: Number(input.cache?.toolsTtlMs || 15 * 60 * 1000),
    },
    menu: normalizeMenu(input.menu),
  };
}

function normalizeMenu(input: unknown): RelayMenuConfig | undefined {
  if (input === undefined) return undefined;
  if (!input || typeof input !== 'object') throw new Error('menu config must be an object');
  const menu = input as RelayMenuConfig;
  if (menu.statusUrl) assertLocalHttpUrl(menu.statusUrl, 'menu.statusUrl');
  const actions = Array.isArray(menu.actions) ? menu.actions.map(normalizeMenuAction) : undefined;
  return {
    statusUrl: menu.statusUrl,
    ttlMs: Number(menu.ttlMs || 15_000),
    actions,
  };
}

function normalizeMenuAction(input: RelayMenuAction): RelayMenuAction {
  if (!input || typeof input !== 'object') throw new Error('menu.actions entries must be objects');
  if (!input.id || !/^[a-zA-Z0-9_-]+$/.test(input.id)) {
    throw new Error('menu action id is required and must contain only letters, numbers, _ or -');
  }
  if (!input.label || typeof input.label !== 'string') {
    throw new Error(`menu action ${input.id} label is required`);
  }
  const action: RelayMenuAction = {
    id: input.id,
    label: input.label,
    systemImage: input.systemImage,
    confirm: input.confirm === true,
  };
  if (input.tool) action.tool = input.tool;
  if (input.args && typeof input.args === 'object' && !Array.isArray(input.args)) {
    action.args = input.args;
  }
  if (input.url) {
    if (input.method) assertLocalHttpUrl(input.url, `menu action ${input.id} url`);
    else assertLocalDisplayUrl(input.url, `menu action ${input.id} url`);
    action.url = input.url;
  }
  if (input.method) {
    action.method = normalizeMethod(input.method);
    if (!action.url) throw new Error(`menu action ${input.id} method requires url`);
  }
  if (action.tool && action.url) {
    throw new Error(`menu action ${input.id} must use only one of tool or url`);
  }
  if (!action.tool && !action.url) {
    throw new Error(`menu action ${input.id} requires tool or url`);
  }
  return action;
}

function normalizeMethod(method: unknown): RelayMenuActionMethod {
  if (method === 'GET' || method === 'POST' || method === 'PUT' || method === 'PATCH' || method === 'DELETE') {
    return method;
  }
  throw new Error('menu action method must be GET, POST, PUT, PATCH, or DELETE');
}

function assertLocalDisplayUrl(raw: string, label: string) {
  const url = new URL(raw);
  if (url.protocol === 'file:') return;
  assertLocalHttpUrl(raw, label);
}

function assertLocalHttpUrl(raw: string, label: string) {
  const url = new URL(raw);
  if (url.protocol !== 'http:') throw new Error(`${label} must use http://127.0.0.1, http://localhost, or file:`);
  if (url.hostname !== '127.0.0.1' && url.hostname !== 'localhost') {
    throw new Error(`${label} must target 127.0.0.1 or localhost`);
  }
}

export async function readConfig(path = defaultConfigPath()): Promise<RelayConfig> {
  const raw = await readFile(path, 'utf8');
  return normalizeConfig(JSON.parse(raw));
}

export async function writeConfig(config: RelayConfig, path = defaultConfigPath()) {
  const normalized = normalizeConfig(config);
  await mkdir(dirname(path), { recursive: true });
  const tmp = `${path}.${process.pid}.tmp`;
  await writeFile(tmp, `${JSON.stringify(normalized, null, 2)}\n`);
  await rename(tmp, path);
}

export async function ensureDefaultConfig(path = defaultConfigPath()) {
  try {
    await stat(path);
  } catch {
    await writeConfig(
      {
        admin: defaultAdmin,
        servers: [],
      },
      path,
    );
  }
}

export function toolsCachePath(serverId: string) {
  return join(stateDir(), `${serverId}.tools.json`);
}
