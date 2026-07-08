# Optional macOS Status Bar

The relay daemon is intentionally headless. A future optional macOS status bar app should be a small SwiftUI `MenuBarExtra` app that reads only the local admin API:

- `GET /status`
- `POST /restart` when added
- `POST /servers/:id/refresh` when added

The first status bar release should show:

- global relay state
- each configured MCP server
- cached tool count
- last refresh time
- last refresh error
- quick actions for opening logs and copying client config

The app should never read env files or display secrets.
