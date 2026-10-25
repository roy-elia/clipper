# Clipper

Clipboard history for macOS, built to behave like a clipboard manager with pinboards, Paste Stack and an MCP server.

```sh
swift build && .build/debug/Clipper          # menu-bar app, ⇧⌘V opens the shelf
scripts/test.sh                              # unit tests (fails if none ran)
.build/debug/Clipper --selftest              # headless end-to-end checks
.build/debug/Clipper --snapshot <dir>        # renders every screen to PNG
```

## MCP
Settings → "Let AI tools use my clips" starts a loopback-only server at `http://127.0.0.1:47821/mcp`.
Every request needs `Authorization: Bearer <token>` (copy it from Settings; stored 0600 in
`~/Library/Application Support/Clipper/mcp-token`). Tools: search, read_item, create_item, update_item,
delete_item, list_pinboards, create_pinboard, rename_pinboard, delete_pinboard, add_item_to_pinboard,
remove_item_from_pinboard.

For stdio clients:
```json
{ "mcpServers": { "clipper": {
  "command": "/path/to/.build/debug/clipper-mcp-stdio",
  "env": { "MCP_URL": "http://127.0.0.1:47821/mcp", "MCP_TOKEN": "<token>" } } } }
```
