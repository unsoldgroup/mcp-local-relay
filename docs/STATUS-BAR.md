# Optional macOS Status Bar

The relay daemon is still headless. A macOS `MenuBarExtra` app should read only the local admin API and render the generic menu model exposed by the relay.

## Admin API

- `GET /status` stays lightweight and reports relay/upstream health only.
- `GET /menu` returns menu models for all configured servers.
- `GET /servers/:id/menu` returns one server's menu model.
- `POST /servers/:id/menu/actions/:actionId` executes a menu action.

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

The status bar app should never read env files or display secrets. The relay menu model does not include remote headers, env file contents, or authorization tokens. Detailed menu status is fetched lazily and cached briefly so `/status` remains cheap.
