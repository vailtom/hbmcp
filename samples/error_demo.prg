/*
 * error_demo.prg - Runtime-error trap demonstration MCP server
 *
 * Role in the samples set
 * -----------------------
 * Optional, special-purpose. Shows that a tool callback can raise any
 * Harbour runtime error - undeclared variable, division by zero, array
 * out of bounds, NIL operation - and the SERVER WILL NOT CRASH. The lib
 * wraps every Eval(callback, args) in BEGIN SEQUENCE / RECOVER and turns
 * the caught Error object into a tool result with `isError:true`,
 * carrying a JSON payload of description / operation / codes / stack /
 * args (see src/mcp_protocol.prg).
 *
 * Tool authors do NOT write their own try/catch. The lib does it for them.
 *
 * MCP / JSON-RPC concepts touched
 * -------------------------------
 * - Tool execution failure shape: result.isError=true, content[0].text
 *   holds the JSON-encoded error payload. MCP 2024-11-05 - Tools.
 * - Why not a JSON-RPC error -32603: that code is reserved for protocol-
 *   level failures (the client would only see error.message; data is
 *   collapsed by most clients). isError keeps the rich payload visible
 *   in the tool result panel.
 *
 * Reading order
 * -------------
 * Standalone. No relation to dbf_query / mini_erp / slow_demo.
 *
 * Demonstration
 * -------------
 *   printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
 *   {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"crash_undeclared","arguments":{}}}
 *   {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"crash_div_zero","arguments":{}}}
 *   {"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"crash_array_oob","arguments":{}}}
 *   {"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"crash_nil_op","arguments":{}}}
 *   {"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"safe_alive","arguments":{}}}
 *   ' | ./error_demo.exe 2>&1
 *
 * Expected:
 *   - id=2..5: each one comes back as a result with isError:true. The
 *     content[0].text is a multi-line, human-readable Clipper-style
 *     error report: tool name, the reconstructed failing expression
 *     (e.g. "NIL + 1", "1 / 0", "<A>[99]"), a human description naming
 *     the operation, the arguments list, the call stack (with "[lib]"
 *     tagging library frames), and the Harbour error codes on a single
 *     trailing line.
 *   - id=6: regular success result (isError absent or false). The server
 *     is still running.
 *   - Stderr (when 2>&1): MCPLog narration showing each tool entered and
 *     either crashed or returned safely.
 *
 * Build
 * -----
 *   hbmk2 error_demo.hbp
 */

#include "hbmcp.ch"


PROCEDURE Main()

   MCPSetServerInfo( "error-demo-mcp", "1.0.0" )

   /* -----------------------------------------------------------------
    * Tool: crash_undeclared
    *
    * Reads a name that was never declared as LOCAL / STATIC / FIELD /
    * MEMVAR / PRIVATE / PUBLIC. Harbour raises "Variable does not exist".
    * ----------------------------------------------------------------- */
   MCPRegisterTool( ;
      "crash_undeclared", ;
      "Reads an undeclared variable. Raises 'Variable does not exist'.", ;
      { "type" => "object", "properties" => { => }, "required" => {} }, ;
      {| hArgs | tool_undecl( hArgs ) } )

   /* -----------------------------------------------------------------
    * Tool: crash_div_zero
    *
    * Classic divide by zero. Harbour raises a numeric runtime error.
    * ----------------------------------------------------------------- */
   MCPRegisterTool( ;
      "crash_div_zero", ;
      "Computes 1 / 0. Raises a numeric error.", ;
      { "type" => "object", "properties" => { => }, "required" => {} }, ;
      {| hArgs | tool_div_zero( hArgs ) } )

   /* -----------------------------------------------------------------
    * Tool: crash_array_oob
    *
    * Reads past the end of a 3-element array. Raises "Bound error".
    * ----------------------------------------------------------------- */
   MCPRegisterTool( ;
      "crash_array_oob", ;
      "Reads index 99 of a 3-element array. Raises 'Bound error'.", ;
      { "type" => "object", "properties" => { => }, "required" => {} }, ;
      {| hArgs | tool_array_oob( hArgs ) } )

   /* -----------------------------------------------------------------
    * Tool: crash_nil_op
    *
    * Arithmetic on a NIL local. Harbour raises an 'Argument error'.
    * ----------------------------------------------------------------- */
   MCPRegisterTool( ;
      "crash_nil_op", ;
      "Adds 1 to a NIL local. Raises 'Argument error'.", ;
      { "type" => "object", "properties" => { => }, "required" => {} }, ;
      {| hArgs | tool_nil_op( hArgs ) } )

   /* -----------------------------------------------------------------
    * Tool: safe_alive
    *
    * Plain tool used to prove the server survived the previous crashes.
    * ----------------------------------------------------------------- */
   MCPRegisterTool( ;
      "safe_alive", ;
      "Returns a heartbeat hash. Use it AFTER a crash to confirm the server is still up.", ;
      { "type" => "object", "properties" => { => }, "required" => {} }, ;
      {| hArgs | tool_safe_alive( hArgs ) } )

   MCPRun()
   RETURN


STATIC FUNCTION tool_undecl( hArgs )
   HB_SYMBOL_UNUSED( hArgs )
   MCPLog( MCP_LOG_INFO, "[crash_undeclared] about to read xVarThatDoesNotExist" )
   RETURN xVarThatDoesNotExist


STATIC FUNCTION tool_div_zero( hArgs )
   LOCAL n := 1, m := 0
   HB_SYMBOL_UNUSED( hArgs )
   MCPLog( MCP_LOG_INFO, "[crash_div_zero] about to compute 1 / 0" )
   RETURN n / m


STATIC FUNCTION tool_array_oob( hArgs )
   LOCAL aData := { 10, 20, 30 }
   HB_SYMBOL_UNUSED( hArgs )
   MCPLog( MCP_LOG_INFO, "[crash_array_oob] about to read aData[ 99 ]" )
   RETURN aData[ 99 ]


STATIC FUNCTION tool_nil_op( hArgs )
   LOCAL xNothing
   HB_SYMBOL_UNUSED( hArgs )
   MCPLog( MCP_LOG_INFO, "[crash_nil_op] about to compute NIL + 1" )
   RETURN xNothing + 1


STATIC FUNCTION tool_safe_alive( hArgs )
   HB_SYMBOL_UNUSED( hArgs )
   MCPLog( MCP_LOG_INFO, "[safe_alive] server still up" )
   RETURN { "alive" => .T., "uptime_s" => Seconds() }
