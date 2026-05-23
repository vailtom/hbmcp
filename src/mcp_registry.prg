/*
 * mcp_registry.prg - Tool registry (singleton, in-process)
 * Author: Vailton Renato <vailtom at gmail dot com>
 * Release: 2026-05-23
 *
 * Role in the architecture
 * ------------------------
 * Holds the set of tools the server exposes. Pure storage: no JSON, no
 * stdin/stdout. The application populates the registry once at startup by
 * calling MCPRegisterTool() (defined in mcp_server.prg); the protocol layer
 * reads from it when answering `tools/list` and `tools/call`.
 *
 * MCP / JSON-RPC concepts touched
 * -------------------------------
 * - MCP "tool": a named function the client (LLM) can invoke
 * - JSON Schema: each tool declares the shape of its arguments so the
 *   client knows what to send and how to display the form
 *
 * Why a STATIC hash instead of OOP/instance state
 * -----------------------------------------------
 * An MCP server is a one-shot process: spawned by the client, fed stdin,
 * killed on disconnect. There is exactly one registry per process, and its
 * lifetime equals the process lifetime. A module-level STATIC hash is the
 * simplest fit for that lifecycle and matches the way most legacy Harbour
 * code already organizes process-global state.
 *
 * Internal record shape
 * ---------------------
 *   s_hTools[ cName ] = { ;
 *      "description" => "...",       // human-readable
 *      "schema"      => { ... },     // JSON Schema (hash, as-is)
 *      "callback"    => bCallback }  // {| hArgs | ... }
 *
 * Reading order
 * -------------
 * After mcp_jsonrpc.prg. Followed by mcp_protocol.prg.
 */

#include "hbmcp.ch"


STATIC s_hTools := { => }


/*
 * MCPRegistry_Add - Insert or replace a tool definition.
 *
 * Validates inputs softly: non-string names and non-block callbacks are
 * rejected. A missing description becomes "", a missing/invalid schema
 * becomes the empty object schema `{ "type" => "object" }` so that
 * `tools/list` always returns valid JSON Schema.
 *
 * Parameters:
 *   cName     - String, non-empty. The name the client uses in tools/call.
 *   cDesc     - String. May be NIL/empty.
 *   hSchema   - Hash. JSON Schema describing the tool's arguments.
 *   bCallback - Code block. Receives hArgs (hash), returns any value.
 *
 * Returns:
 *   Logical - .T. on success, .F. on invalid input.
 */
FUNCTION MCPRegistry_Add( cName, cDesc, hSchema, bCallback )
   IF ! HB_ISSTRING( cName ) .OR. Empty( cName )
      RETURN .F.
   ENDIF
   IF ! HB_ISBLOCK( bCallback )
      RETURN .F.
   ENDIF
   s_hTools[ cName ] := { ;
      "description" => iif( HB_ISSTRING( cDesc ), cDesc, "" ), ;
      "schema"      => iif( HB_ISHASH( hSchema ), hSchema, { "type" => "object" } ), ;
      "callback"    => bCallback }
   RETURN .T.


/*
 * MCPRegistry_Get - Fetch the internal record for a tool, or NIL.
 *
 * Used by the tools/call handler. Returns the full record (description,
 * schema, callback) so the caller can both invoke and report on it.
 */
FUNCTION MCPRegistry_Get( cName )
   IF cName $ s_hTools
      RETURN s_hTools[ cName ]
   ENDIF
   RETURN NIL


/*
 * MCPRegistry_Has - Cheap existence check.
 *
 * Preferred over MCPRegistry_Get() != NIL when you only need to validate
 * a tool name (e.g. before dispatching tools/call).
 */
FUNCTION MCPRegistry_Has( cName )
   RETURN cName $ s_hTools


/*
 * MCPRegistry_List - Render the registry as the `tools/list` payload.
 *
 * The MCP spec defines the response shape exactly:
 *   { "tools": [ { "name":.., "description":.., "inputSchema":.. }, ... ] }
 * This function returns just the inner array; the protocol handler wraps it
 * into the outer object before sending it back.
 *
 * Returns:
 *   Array of hashes, one per registered tool, in insertion order
 *   (Harbour hashes preserve insertion order).
 */
FUNCTION MCPRegistry_List()
   LOCAL aOut := {}
   LOCAL cName, hTool
   FOR EACH cName IN hb_HKeys( s_hTools )
      hTool := s_hTools[ cName ]
      AAdd( aOut, { ;
         "name"        => cName, ;
         "description" => hTool[ "description" ], ;
         "inputSchema" => hTool[ "schema" ] } )
   NEXT
   RETURN aOut


/*
 * MCPRegistry_Clear - Reset the registry. Used by tests; rarely needed
 * by application code, since the registry's natural lifetime is one
 * process.
 */
FUNCTION MCPRegistry_Clear()
   s_hTools := { => }
   RETURN NIL
