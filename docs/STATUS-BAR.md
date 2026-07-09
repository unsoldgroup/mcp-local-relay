# Optional macOS Status Bar

The relay daemon stays headless. The optional macOS status bar app is a small SwiftUI `MenuBarExtra` package in `macos/McpLocalRelayStatusBar` that reads only the local admin API and renders the generic menu model exposed by the relay.

## Admin API

- `GET /status` stays lightweight and reports relay/upstream health only.
- `GET /menu` returns menu models for all configured servers.
- `GET /servers/:id/menu` returns one server's menu model.
- `POST /servers/:id/menu/actions/:actionId` executes a menu action.
- `GET /client-config`
- `POST /restart`
- `POST /servers/:id/refresh`

The status bar app shows aggregate relay status, per-server menu metadata, restart and refresh controls, log-folder access, and client config copy actions.

Action requests may include:

```json
{
  "confirm": true,
  "args": {
    "force": true
  }
}
```

Actions with `confirm: true` are rejected unless the request includes `"confirm": true`.

## MCP Tool Convention

For portable menu metadata, an upstream MCP server can expose either:

```text
relay_menu_status
```

or:

```text
<server-id>_menu_status
```

The tool should return text JSON:

```json
{
  "title": "Mail Index",
  "summary": "Ready - 23 tools - 3 accounts",
  "state": "ready",
  "detail": [
    "Last sync 4m ago",
    "Indexed 128,304 messages",
    "0 account errors"
  ],
  "actions": [
    {
      "id": "sync_now",
      "label": "Sync Now",
      "systemImage": "arrow.triangle.2.circlepath",
      "tool": "mail_index_sync_now"
    },
    {
      "id": "open_index",
      "label": "Open Index Folder",
      "systemImage": "folder",
      "url": "file:///Users/al/.local/state/mail-index"
    }
  ]
}
```

Tool actions name upstream tools. The relay calls them against the selected upstream server and merges configured action `args` with request `args`.

## Compact Views

Menu actions may include a small `view` payload for at-a-glance data. The status bar app renders this inline as a compact submenu instead of executing a tool call. Keep payloads capped; do not stream full logs or ledgers through the menu model.

```json
{
  "id": "open_ledger",
  "label": "Open Ledger",
  "systemImage": "list.bullet.rectangle",
  "view": {
    "type": "table",
    "title": "Corpus Ledger",
    "summary": "42 done - 0 failed - 1 needs human",
    "refreshSeconds": 10,
    "density": "compact",
    "columns": [
      { "id": "status", "label": "", "kind": "status" },
      { "id": "plan", "label": "Plan" },
      { "id": "state", "label": "State" },
      { "id": "result", "label": "Result" },
      { "id": "age", "label": "Age" }
    ],
    "rows": [
      {
        "status": "success",
        "plan": "Safe Travels Sailaway Essential",
        "state": "OR",
        "result": "done",
        "age": "6m ago"
      }
    ],
    "footerActions": [
      {
        "id": "open_full_ledger",
        "label": "Open Full Ledger",
        "systemImage": "arrow.up.forward.app",
        "url": "file:///Users/al/code/insurance-corpus/eval/batch/codex-ledger.jsonl"
      }
    ]
  }
}
```

Supported row status tokens are `success`, `running`, `warning`, `error`, `paused`, and `neutral`. Servers provide semantics only; the native app chooses icons and colors.

## Configured Local Admin Actions

For local HTTP admin surfaces, a server config may include menu metadata:

```json
{
  "id": "mail-index",
  "remote": {
    "type": "streamable_http",
    "url": "http://127.0.0.1:3765/mcp"
  },
  "menu": {
    "statusUrl": "http://127.0.0.1:3765/status",
    "ttlMs": 15000,
    "actions": [
      {
        "id": "sync_now",
        "label": "Sync Now",
        "method": "POST",
        "url": "http://127.0.0.1:3765/sync"
      }
    ]
  }
}
```

HTTP admin actions must target `http://127.0.0.1` or `http://localhost`. File URLs are allowed only as display/open actions for the menu-bar app.

## Security

The status bar app should never read env files or display secrets. The relay menu model does not include remote headers, env file contents, or authorization tokens. Detailed menu status is fetched lazily and cached briefly so `/status` remains cheap. It opens the relay log folder with Finder instead of rendering log contents inline.

Run from a checkout:

```sh
cd macos/McpLocalRelayStatusBar
swift run
```

Install from a checkout:

```sh
pnpm install:status-bar
```

The installer builds a release binary, wraps it in
`~/Applications/Mcp Local Relay Status Bar.app`, registers a user LaunchAgent
so it opens at login, and opens the app immediately.

Uninstall:

```sh
pnpm uninstall:status-bar
```
