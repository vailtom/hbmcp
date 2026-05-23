# dbf_mcp - DBF/NTX MCP server

Harbour read-only MCP server that exposes DBF/NTX navigation to MCP clients (Claude Code, Codex, MCP Inspector). Uses native Harbour DBFNTX RDD.

## Build

From this directory, with MSVC `link.exe` ahead of Git's `link.exe` on
PATH:

```
hbmk2 dbf_mcp.hbp
```

Output: `dbf_mcp.exe`.

## Configuration

INI file `dbf_mcp.ini` next to the executable. See `config.example.ini`.

Environment overrides at startup:

- `DBF_MCP_CONFIG` - alternate INI path
- `DBF_ROOT`       - override `active_root`
- `DBF_MCP_LOG`    - reserved (logging currently via MCPLog/stderr)

## Architecture

This sample uses a custom `dbf_RunLoop()` (not `MCPRun()`). The loop
reads stdin, parses requests, and dispatches each one via `MCPDispatch()`.
Practical reason: the custom loop allows clean shutdown when stdin
closes, while keeping DBF worker lifecycle under explicit control.
To preserve the Python contract of stateful sessions (`open_table` ->
`set_order` -> `seek_record` -> `skip` across calls), every RDD
operation is funneled through a single dedicated worker thread
(`dbf_StartWorker`) via a mutex queue (`hb_mutexNotify` /
`hb_mutexSubscribe`). The worker owns all workareas for the lifetime of
the process.

Files:

- `dbf_mcp.prg`       - entry point + 25 tool registrations
- `dbf_workspace.prg` - worker thread + queue + all RDD ops
- `dbf_filters.prg`   - filter operators, date parsing, projection
- `dbf_config.prg`    - INI load/save, codepage mapping, env overrides

## Tools

| Tool                | Purpose                                                         |
|---------------------|-----------------------------------------------------------------|
| list_roots          | Configured roots + active root + workdir + config path          |
| get_active_root     | Active root and config path                                     |
| set_active_root     | Switch active root by name or path (closes all open tables)     |
| save_config         | Persist current config to the INI file                          |
| list_tables         | DBF files under active root (`recursive` optional)              |
| list_all_indexes    | NTX files under active root (`recursive` optional)              |
| get_table_info      | Fields + same-stem NTX indexes for a table                      |
| list_fields         | List field definitions for a table                              |
| list_indexes        | List same-stem NTX indexes (with key_expr) for a table          |
| open_table          | Open DBF (optional NTX list) and make active                    |
| get_active_table    | Summary of the active table                                     |
| close_active_table  | Close the active table                                          |
| close_table         | Close a specific table                                          |
| close_all_tables    | Close every open table                                          |
| set_order           | Select active index by 1-based number or name                   |
| get_deleted         | Return the current deleted-record visibility flag               |
| set_deleted         | Show/hide deleted records (per-session, applied process-wide)   |
| query_records       | Scan with filters/projection; auto-seek for single eq on index  |
| current_record      | Return the record at current cursor position (without moving)   |
| get_record          | Fetch by physical record number                                 |
| seek_record         | DBSEEK on active index (soft optional)                          |
| records_since       | Soft-seek, then iterate forward to EOF                          |
| go_top              | Move to first record                                            |
| go_bottom           | Move to last record                                             |
| skip                | Advance n records (positive or negative)                        |

Filter shape (`query_records` `filters` argument):

```json
[ { "field": "EST_KEY", "op": "eq", "value": 14281 } ]
```

Ops: `eq, ne, lt, lte, gt, gte, contains, startswith, endswith, in, between`.
`between` value: `{ "min": ..., "max": ... }`. Dates accept `YYYY-MM-DD`
or `YYYYMMDD`.

## Filters for LLM agents

`query_records.filters` accepts:

- Object format: `[{"field":"EST_COD","op":"eq","value":"11"}]`
- String format: `"EST_COD = '11'"` or `["EST_COD = '11'"]`
- Mixed array: `["EST_GRUPO = '13'", {"field":"EST_SUB","op":"eq","value":"03"}]`

String operators: `=`, `!=`, `<`, `<=`, `>`, `>=`.

Object operators: `eq, ne, lt, lte, gt, gte, contains, startswith, endswith, in, between`.

String filter syntax (v1) does not support `AND`, `OR`, or parentheses.

## Encoding

DBF character fields are read in the configured `encoding` (default
`cp850`) and translated to UTF-8 before being returned to the JSON-RPC
layer. Mappings: cp850 -> PT850, cp1252 -> PTWIN, iso-8859-1 -> PTISO,
utf-8 -> UTF8. Other encodings are passed through to `hb_Translate`
verbatim.

## Smoke test

```
echo {"jsonrpc":"2.0","id":1,"method":"initialize","params":{}} | dbf_mcp.exe
echo {"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}  | dbf_mcp.exe
```

`tools/list` should report 25 tools whose names match the table above.
Expected quick check: the result payload contains a `tools` array with
exactly 25 entries.

## Concurrency notes

- Only one worker thread executes RDD code. Slow scans block other tool
  calls in the same MCP session. This matches the Python build, which is
  also effectively single-threaded under FastMCP's stdio transport.
- All tool callbacks are non-blocking-fast: they enqueue and wait.
- Errors raised in the worker (missing table, bad seek value, etc.) are
  returned to the caller as `{ "error": "..." }` hashes inside the tool
  result payload, not as JSON-RPC error objects.
