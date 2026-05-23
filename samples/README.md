# hbmcp samples

Suggested reading order. Each sample is self-contained: its source file
opens with a narration block explaining what it teaches and how to run it.

| # | Sample           | What it shows                                                            |
|---|------------------|--------------------------------------------------------------------------|
| 1 | `echo_server`    | Minimal MCP server: registration of tools, schema basics, MCPRun loop.   |
| 2 | `fs_tools`       | Real-world I/O tools (cwd listing, file head, file info) and enum schema.|
| 3 | `dbf_query`      | DBF as MCP data source: auto-generated DBF, scan + filter, hash returns. |
| 4 | `mini_erp`       | End-to-end: customers + invoices, computed balances, date math, top-N.   |
| 5 | `slow_demo`      | Slow tools to observe MT in action (sleep, busy-loop, tick).             |
| 6 | `error_demo`     | Tools that crash on purpose. Lib traps the RTE and returns a Clipper-style report. |

## Build any sample

```sh
hbmk2 <name>.hbp
```

The `.hbp` already passes `-gtcgi`, `-mt`, links `hbmcp`, and sets the
include path.

To build all samples at once:

```bat
compile_all.bat
```

Run every sample from this `samples/` directory. `dbf_query` and `mini_erp`
use the relative path `data/customers.dbf`, so launching them from elsewhere
creates a `data/` folder in the wrong place.

## Try a sample interactively

```bat
inspect.bat <name>
```

(Browser UI, requires Node.js 18+. The script checks prerequisites and
guides the user if something is missing.)

## Pipe JSON-RPC manually

```sh
printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}\n{"jsonrpc":"2.0","id":2,"method":"tools/list"}\n' | ./<name>.exe
```

## Data directory

- `dbf_query` creates `samples/data/customers.dbf` on first run.
- `mini_erp` creates `samples/data/customers.dbf` (if missing) **and**
  `samples/data/invoices.dbf` on first run.

If a file already exists, the sample validates its structure and reuses it.
To regenerate, delete the file and rerun.

