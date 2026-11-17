# reminders-mcp — Apple Reminders MCP server

Pure Swift (EventKit), one binary, no dependencies.

| Tool | What it does |
|---|---|
| `reminders_list_lists` | Lists with open counts |
| `reminders_list` | Open reminders, soonest due first. Filter by list, `dueBefore`, or text |
| `reminders_create` | Title, list, due (`YYYY-MM-DD` or `YYYY-MM-DD HH:MM` with a notification), notes, priority, URL |
| `reminders_update` | Change any field, move to another list, or clear the due date |
| `reminders_complete` | Complete one or many |
| `reminders_delete` | Delete |

```bash
swift build -c release
claude mcp add reminders-mcp -s user "$PWD/.build/release/reminders-mcp"
```
