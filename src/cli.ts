import { readFile } from 'node:fs/promises';
import { ensureDefaultConfig, readConfig, writeConfig } from './config.js';
import { installLaunchAgent, launchctl, readLogs, renderLaunchAgent } from './launchd.js';
import { defaultConfigPath, launchAgentPath } from './paths.js';
import { serve } from './service.js';

export async function main(argv = process.argv.slice(2)) {
  const command = argv[0] || 'help';
  const configPath = valueAfter(argv, '--config') || defaultConfigPath();

  if (command === 'serve') {
    await serve({ configPath });
    return;
  }
  if (command === 'init') {
    await ensureDefaultConfig(configPath);
    console.log(`initialized ${configPath}`);
    return;
  }
  if (command === 'install') {
    await ensureDefaultConfig(configPath);
    await installLaunchAgent({ configPath, cliPath: process.argv[1] });
    console.log(`installed ${launchAgentPath()}`);
    return;
  }
  if (command === 'plist') {
    console.log(renderLaunchAgent({ configPath, cliPath: process.argv[1] }));
    return;
  }
  if (command === 'start') {
    console.log((await launchctl('bootstrap')).stdout.trim());
    return;
  }
  if (command === 'stop') {
    console.log((await launchctl('bootout')).stdout.trim());
    return;
  }
  if (command === 'restart') {
    console.log((await launchctl('kickstart')).stdout.trim());
    return;
  }
  if (command === 'status') {
    const config = await readConfig(configPath);
    const host = config.admin?.host || '127.0.0.1';
    const port = config.admin?.port || 3764;
    const response = await fetch(`http://${host}:${port}/status`);
    console.log(await response.text());
    return;
  }
  if (command === 'logs') {
    const logs = await readLogs();
    console.log('--- stdout ---');
    console.log(logs.out);
    console.log('--- stderr ---');
    console.log(logs.err);
    return;
  }
  if (command === 'add') {
    const file = valueAfter(argv, '--file');
    if (!file) throw new Error('add requires --file <server.json>');
    const server = JSON.parse(await readFile(file, 'utf8'));
    const config = await readConfig(configPath);
    config.servers.push(server);
    await writeConfig(config, configPath);
    console.log(`added ${server.id}`);
    return;
  }
  if (command === 'print-config') {
    const config = await readConfig(configPath);
    const url = `http://${config.admin?.host || '127.0.0.1'}:${config.admin?.port || 3764}${config.admin?.mcpPath || '/mcp'}`;
    console.log(JSON.stringify({ mcpServers: { 'mcp-local-relay': { type: 'http', url } } }, null, 2));
    return;
  }
  if (command === 'doctor') {
    await ensureDefaultConfig(configPath);
    const config = await readConfig(configPath);
    console.log(JSON.stringify({ ok: true, configPath, servers: config.servers.length }, null, 2));
    return;
  }
  printHelp();
}

function valueAfter(argv: string[], key: string) {
  const index = argv.indexOf(key);
  return index >= 0 ? argv[index + 1] : undefined;
}

function printHelp() {
  console.log(`mcp-local-relay

Commands:
  serve --config <path>      Run the relay service
  init --config <path>       Create a default config
  install --config <path>    Install macOS LaunchAgent
  start|stop|restart         Control LaunchAgent
  status                     Query local status endpoint
  logs                       Print recent service logs
  add --file <server.json>   Add server config offline
  print-config               Print client MCP config snippet
  doctor                     Validate local config
`);
}
