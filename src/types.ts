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

export interface RelayServerConfig {
  id: string;
  name?: string;
  enabled?: boolean;
  mode?: RelayMode;
  remote: RelayRemoteConfig;
  envFile?: string;
  cache?: RelayCacheConfig;
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
