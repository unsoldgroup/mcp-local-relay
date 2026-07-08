export type RelayMode = 'generic-cached' | 'posthog-cli';

export interface RelayListenConfig {
  host?: string;
  port?: number;
  path?: string;
}

export interface RelayRemoteConfig {
  type: 'streamable_http';
  url: string;
  headers?: Record<string, string>;
}

export interface RelayCacheConfig {
  toolsTtlMs?: number;
}

export type RelayMenuState = 'ready' | 'running' | 'paused' | 'attention' | 'error' | 'unknown';
export type RelayMenuActionMethod = 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE';

export interface RelayMenuAction {
  id: string;
  label: string;
  systemImage?: string;
  confirm?: boolean;
  tool?: string;
  args?: Record<string, unknown>;
  url?: string;
  method?: RelayMenuActionMethod;
}

export interface RelayMenuConfig {
  statusUrl?: string;
  ttlMs?: number;
  actions?: RelayMenuAction[];
}

export interface RelayServerConfig {
  id: string;
  name?: string;
  enabled?: boolean;
  mode?: RelayMode;
  remote: RelayRemoteConfig;
  envFile?: string;
  cache?: RelayCacheConfig;
  menu?: RelayMenuConfig;
}

export interface RelayAdminConfig {
  host?: string;
  port?: number;
  mcpPath?: string;
}

export interface RelayConfig {
  admin?: RelayAdminConfig;
  servers: RelayServerConfig[];
}

export interface CachedToolsFile {
  cachedAt: number;
  tools: unknown[];
}

export interface RelayServerStatus {
  id: string;
  name: string;
  enabled: boolean;
  mode: RelayMode;
  remoteUrl: string;
  connected: boolean;
  cachedTools: number;
  cachedAt: number;
  lastRefreshAttemptAt: number;
  lastRefreshError: string;
}

export interface RelayStatus {
  ok: boolean;
  name: string;
  uptimeMs: number;
  sessions: number;
  servers: RelayServerStatus[];
}

export interface RelayMenuStatus {
  id: string;
  title: string;
  summary: string;
  state: RelayMenuState;
  detail: string[];
  actions: RelayMenuAction[];
  cachedAt: number;
  lastError: string;
}
