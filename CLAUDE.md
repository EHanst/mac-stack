# mac-stack (VibeCockpit)

## Code search (RAG)
The `vibecockpit` MCP server (`.mcp.json`) indexes this repo. Its tool schemas are deferred: load them first with
`ToolSearch select:mcp__vibecockpit__search_code,mcp__vibecockpit__index_workspace`.

- Use `search_code` first for "where/how is X implemented" and concept questions, then Read the hits. Skip it for exact symbols/strings (grep) and files whose path you know.
- The app watches each open project folder and re-indexes `.swift` changes within about a second (`WorkspaceWatcher`), so edits are searchable without a manual step. If results look stale or a file is missing, call `index_workspace` (optionally with `path`).
- "No results" can mean the index is empty or stale, not that the code doesn't exist; fall back to grep.
- Errors: report the message; don't retry in a loop. The app must be running (menu bar).

Architecture constraints and the full stack live in `CLAUD.md` (not auto-loaded; read it when changing app architecture).
