/*
 * mcp_jsonrpc.prg - JSON-RPC 2.0 framing for MCP
 * Author: Vailton Renato <vailtom at gmail dot com>
 * Release: 2026-05-23
 *
 * Role in the architecture
 * ------------------------
 * The lowest layer of the library. Knows only about JSON-RPC, not about MCP.
 * It can parse an incoming line into a request hash, and it can build either
 * a success ("result") or an error response, both as JSON strings ready to
 * write to stdout. It does NOT touch stdin, stdout, or the tool registry -
 * those belong to higher layers.
 *
 * MCP / JSON-RPC concepts touched
 * -------------------------------
 * - JSON-RPC 2.0 message shapes (request, response, notification, error)
 * - The `id` field as the request/response correlator
 * - Notifications: requests without an `id`, never get a response
 *
 * Wire format (one message = one LF-terminated line)
 * --------------------------------------------------
 *   request       { "jsonrpc":"2.0", "id":N, "method":"foo", "params":{...} }
 *   notification  { "jsonrpc":"2.0",          "method":"foo", "params":{...} }
 *   result reply  { "jsonrpc":"2.0", "id":N, "result":{...} }
 *   error  reply  { "jsonrpc":"2.0", "id":N, "error":{ "code":..,"message":"..","data":.. } }
 *
 * Reading order
 * -------------
 * Start here. Then read mcp_registry.prg, mcp_protocol.prg, mcp_server.prg.
 */

#include "hbmcp.ch"


/*
 * MCPParse - Decode one JSON-RPC line into a Harbour hash.
 *
 * Parameters:
 *   cLine - String. One complete JSON-RPC message. CR/LF already stripped
 *           by the caller. Must be a JSON object (not an array).
 *
 * Returns:
 *   Hash on success, e.g. { "jsonrpc" => "2.0", "id" => 1, "method" => "ping" }
 *   NIL  if the input isn't valid JSON, OR is valid JSON but not an object.
 *        (Spec says batch arrays are allowed; we don't support them - MCP
 *        doesn't use them either.)
 *
 * Example:
 *   hReq := MCPParse( '{"jsonrpc":"2.0","id":1,"method":"ping"}' )
 *   // hReq[ "method" ] == "ping"
 */
FUNCTION MCPParse( cLine )
   LOCAL xVal := hb_jsonDecode( cLine )
   IF ! HB_ISHASH( xVal )
      RETURN NIL
   ENDIF
   RETURN xVal


/*
 * MCPResult - Build a JSON-RPC success response as a JSON string.
 *
 * Parameters:
 *   xId     - The id from the original request. Echo it back unchanged so
 *             the client can match the response. Can be a number or string.
 *             NIL is allowed but semantically meaningless (notifications
 *             should never get a response).
 *   xResult - The "result" payload. Any JSON-serializable value: hash,
 *             array, string, number, logical.
 *
 * Returns:
 *   String - encoded JSON, no trailing newline. The caller adds the LF.
 *
 * Example:
 *   cJson := MCPResult( 1, { "ok" => .T. } )
 *   // '{"jsonrpc":"2.0","id":1,"result":{"ok":true}}'
 */
FUNCTION MCPResult( xId, xResult )
   LOCAL hMsg := { "jsonrpc" => "2.0", "id" => xId, "result" => xResult }
   RETURN hb_jsonEncode( hMsg )


/*
 * MCPError - Build a JSON-RPC error response as a JSON string.
 *
 * Parameters:
 *   xId   - Same as MCPResult. May be NIL when the request itself was so
 *           broken that we never recovered an id (e.g. parse error before
 *           parsing). Spec says respond with id=null in that case.
 *   nCode - Numeric error code. Prefer the JSONRPC_ERR_* constants from
 *           hbmcp.ch for spec-defined errors.
 *   cMsg  - Short human-readable description. Free-form.
 *   xData - Optional extra data attached to the error. Anything JSON-
 *           serializable. Omitted (the field is not emitted) when NIL.
 *
 * Returns:
 *   String - encoded JSON, no trailing newline.
 *
 * Example:
 *   cJson := MCPError( 7, JSONRPC_ERR_METHOD_NF, "Method not found", "foo/bar" )
 */
FUNCTION MCPError( xId, nCode, cMsg, xData )
   LOCAL hErr := { "code" => nCode, "message" => cMsg }
   LOCAL hMsg
   IF xData != NIL
      hErr[ "data" ] := xData
   ENDIF
   hMsg := { "jsonrpc" => "2.0", "id" => xId, "error" => hErr }
   RETURN hb_jsonEncode( hMsg )


/*
 * MCPIsNotification - True if the request has no "id" field.
 *
 * Notifications, per JSON-RPC 2.0 sec. 4.1, are fire-and-forget. The server
 * MUST NOT respond to them, even on error. MCP uses them for events like
 * `notifications/initialized` (the client telling the server it's ready
 * after initialize) and `notifications/cancelled`.
 *
 * Parameters:
 *   hReq - Hash returned by MCPParse, or any other value.
 *
 * Returns:
 *   Logical - .T. only when the parameter is a hash and lacks "id".
 */
FUNCTION MCPIsNotification( hReq )
   RETURN HB_ISHASH( hReq ) .AND. ! ( "id" $ hReq )
