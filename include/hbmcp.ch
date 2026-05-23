/*
 * hbmcp.ch - Public include for the hbmcp library
 * Author: Vailton Renato <vailtom at gmail dot com>
 * Release: 2026-05-23
 *
 * Role in the architecture
 * ------------------------
 * Every .prg in this project (library, samples, tests) starts with
 * `#include "hbmcp.ch"`. This file is the single source of truth for
 * protocol-level constants. It has no Harbour code - only #defines.
 *
 * What's in here, and why
 * -----------------------
 * 1. Library version
 *      Reported by the server in the `initialize` response under
 *      `serverInfo.version`. Bump on every release.
 *
 * 2. MCP protocol version
 *      The dated string negotiated during the `initialize` handshake.
 *      Clients send the version they want; servers reply with the
 *      version they'll actually speak. We currently support 2024-11-05.
 *
 * 3. JSON-RPC 2.0 standard error codes
 *      Defined verbatim by the JSON-RPC 2.0 specification, section 5.1
 *      ("Error object"). Never invent new values in this range -
 *      anything from -32768 to -32000 is reserved by the spec.
 *      Application-level errors should use codes outside that range.
 *
 * 4. Log levels
 *      Used by MCPLog() in mcp_server.prg. Numerically ordered so the
 *      level threshold can be compared with `<`.
 */

#ifndef _HBMCP_CH_
#define _HBMCP_CH_

/* --- Library version --- */

#define HBMCP_VERSION             "1.0.0"

/* --- MCP protocol version ---
 *
 * Dated, NOT semver. The MCP spec is versioned by release date.
 * See: https://modelcontextprotocol.io/specification
 */
#define HBMCP_PROTOCOL_VERSION    "2024-11-05"

/* --- JSON-RPC 2.0 standard error codes (spec sec. 5.1) ---
 *
 * Code     | Meaning             | When to use
 * ---------|---------------------|--------------------------------------------
 * -32700   | Parse error         | Server received invalid JSON
 * -32600   | Invalid Request     | JSON parsed but is not a valid Request obj
 * -32601   | Method not found    | The requested method does not exist
 * -32602   | Invalid params      | Method exists but params are wrong
 * -32603   | Internal error      | Server-side error during method execution
 *
 * Codes from -32000 to -32099 are reserved for "Server error" - implementation
 * defined. We don't use them yet. Anything outside -32768..-32000 is free for
 * application-level errors.
 */
#define JSONRPC_ERR_PARSE         -32700
#define JSONRPC_ERR_INVALID_REQ   -32600
#define JSONRPC_ERR_METHOD_NF     -32601
#define JSONRPC_ERR_INVALID_PARAM -32602
#define JSONRPC_ERR_INTERNAL      -32603

/* --- Log levels (used by MCPLog / MCPSetLogLevel) ---
 *
 * Ordered low-to-high. Messages below the current threshold are dropped.
 * Logs always go to stderr - stdout is reserved for the JSON-RPC stream.
 */
#define MCP_LOG_DEBUG    0
#define MCP_LOG_INFO     1
#define MCP_LOG_WARN     2
#define MCP_LOG_ERROR    3

#endif
