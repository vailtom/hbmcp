/*
 * mcp_protocol.prg - MCP method handlers (dispatch table)
 * Author: Vailton Renato <vailtom at gmail dot com>
 * Release: 2026-05-23
 *
 * Role in the architecture
 * ------------------------
 * Sits between the JSON-RPC framing (mcp_jsonrpc.prg) and the tool storage
 * (mcp_registry.prg). Given a parsed request hash, it decides which method
 * was called, runs the right handler, and returns a JSON string to send
 * back - or NIL when the request was a notification (no response expected).
 *
 * MCP / JSON-RPC concepts touched
 * -------------------------------
 * - The MCP lifecycle: initialize -> initialized -> normal operation
 * - Server capabilities advertisement (what the client may ask for)
 * - tools/list and tools/call - the only MCP methods this MVP implements
 * - ping - a no-op used by clients to keep the connection alive
 * - Notifications: never produce a response, even on error
 *
 * MCP lifecycle
 * -------------
 *
 *      client                                   hbmcp server
 *        |                                          |
 *        |  initialize { protocolVersion, ... } --->|
 *        |<--- result { protocolVersion,            |
 *        |              capabilities, serverInfo }  |
 *        |                                          |
 *        |  notifications/initialized           --->|   (no reply)
 *        |                                          |
 *        |  tools/list                          --->|
 *        |<--- result { tools: [...] }              |
 *        |                                          |
 *        |  tools/call { name, arguments }      --->|
 *        |<--- result { content: [...] }            |
 *        |                                          |
 *        |  ping                                --->|
 *        |<--- result { }                           |
 *        |                                          |
 *        |  ... (more calls) ...                    |
 *        |                                          |
 *        |  EOF on stdin                        --->|   (server exits)
 *
 * Reading order
 * -------------
 * After mcp_jsonrpc.prg and mcp_registry.prg. Followed by mcp_server.prg.
 */

#include "hbmcp.ch"


/* Server identity advertised in the `initialize` response.
   Defaults match the library; the application overrides them via
   MCPSetServerInfo() before calling MCPRun(). */
STATIC s_cServerName    := "hbmcp"
STATIC s_cServerVersion := HBMCP_VERSION


/*
 * MCPSetServerInfo - Override the server identity reported during initialize.
 *
 * Call this BEFORE MCPRun(), typically right after MCPRegisterTool() calls.
 * Affects only the `serverInfo` block in the initialize response; tool
 * registry, protocol version, and capabilities are unchanged.
 *
 * Parameters:
 *   cName    - String. Application name (e.g. "my-erp-mcp"). NIL to leave
 *              the current value untouched.
 *   cVersion - String. Application version (e.g. "1.2.0"). NIL to leave
 *              the current value untouched.
 *
 * Example:
 *   MCPSetServerInfo( "my-erp-mcp", "1.2.0" )
 *   MCPRun()
 */
FUNCTION MCPSetServerInfo( cName, cVersion )
   IF HB_ISSTRING( cName ) .AND. ! Empty( cName )
      s_cServerName := cName
   ENDIF
   IF HB_ISSTRING( cVersion ) .AND. ! Empty( cVersion )
      s_cServerVersion := cVersion
   ENDIF
   RETURN NIL


/*
 * MCPDispatch - Route a parsed request to the right handler.
 *
 * Parameters:
 *   hReq - Hash returned by MCPParse. Expected fields: "method" (required),
 *          "id" (absent on notifications), "params" (optional).
 *
 * Returns:
 *   String  - JSON response to send back, OR
 *   NIL     - request was a notification; do not write anything.
 *
 * Unknown methods produce a JSONRPC_ERR_METHOD_NF error - unless the request
 * was a notification, in which case the spec demands silence.
 */
FUNCTION MCPDispatch( hReq )
   LOCAL cMethod := hb_HGetDef( hReq, "method", "" )
   LOCAL xId     := hb_HGetDef( hReq, "id", NIL )
   LOCAL hParams := hb_HGetDef( hReq, "params", { => } )
   LOCAL lNotif  := MCPIsNotification( hReq )

   SWITCH cMethod
   CASE "initialize"
      /* Phase 1 of the lifecycle. Client tells us who it is and what
         protocol version it would like to speak; we reply with our
         capabilities and the version we actually support. */
      RETURN MCPResult( xId, mcp_handleInitialize( hParams ) )

   CASE "notifications/initialized"
   CASE "initialized"
      /* Phase 2. Pure notification. The client tells us it has digested
         our capabilities and is ready to send real requests. No reply. */
      RETURN NIL

   CASE "ping"
      /* Trivial liveness check. Empty object as result. */
      RETURN MCPResult( xId, { => } )

   CASE "tools/list"
      /* Read-only enumeration of registered tools. */
      RETURN MCPResult( xId, { "tools" => MCPRegistry_List() } )

   CASE "tools/call"
      /* The interesting one - actually run a tool. */
      RETURN mcp_handleToolsCall( xId, hParams )

   OTHERWISE
      IF lNotif
         /* Spec sec. 4.1: never respond to notifications, even unknown ones. */
         RETURN NIL
      ENDIF
      RETURN MCPError( xId, JSONRPC_ERR_METHOD_NF, "Method not found", cMethod )
   ENDSWITCH

   RETURN NIL


/*
 * mcp_handleInitialize - Build the `initialize` response body.
 *
 * The MCP handshake is symmetric: each side advertises what it supports.
 * Here we advertise:
 *   - protocolVersion: the dated string we'll honor
 *   - capabilities:    which feature sets we implement
 *                      (this MVP only supports "tools")
 *   - serverInfo:      name + version for diagnostics
 *
 * The client may send its own preferred protocolVersion in params; the
 * server is free to accept it or downgrade. We currently always answer
 * with our own version. A future enhancement could negotiate properly.
 */
STATIC FUNCTION mcp_handleInitialize( hParams )
   HB_SYMBOL_UNUSED( hParams )
   RETURN { ;
      "protocolVersion" => HBMCP_PROTOCOL_VERSION, ;
      "capabilities"    => { "tools" => { "listChanged" => .F. } }, ;
      "serverInfo"      => { "name" => s_cServerName, "version" => s_cServerVersion } }


/*
 * mcp_handleToolsCall - Look up a tool and run it inside a safety net.
 *
 * Validation pipeline:
 *   1. The "name" param must match a registered tool.
 *      Wrong/missing name -> JSONRPC_ERR_INVALID_PARAM (protocol-level
 *      error; the client violated the tool contract).
 *   2. The callback is wrapped in BEGIN SEQUENCE so any runtime error
 *      becomes a result with isError=true carrying the JSON-encoded
 *      Harbour error (description, operation, codes, stack, args).
 *      This follows MCP 2024-11-05 - Tools: execution failures live in
 *      `result.isError`, not in JSON-RPC `error`. Inspector/Claude show
 *      the rich payload in the tool result panel; a JSON-RPC error code
 *      would have been collapsed to its `message` and the data hidden.
 *
 * Return-value shaping:
 *   MCP expects `result` to be an object containing a `content` array of
 *   typed items. To keep tool authors' lives easy, this function accepts
 *   either:
 *     - A hash already in MCP shape (must contain a "content" key) - passed
 *       through verbatim, e.g. when the tool wants to return multiple
 *       content items or set isError=.T..
 *     - Anything else - wrapped automatically as a single text content
 *       item. Strings go in raw; everything else is JSON-encoded.
 */
STATIC FUNCTION mcp_handleToolsCall( xId, hParams )
   LOCAL cName    := hb_HGetDef( hParams, "name", "" )
   LOCAL hArgs    := hb_HGetDef( hParams, "arguments", { => } )
   LOCAL hTool, xRet, oErr

   IF ! MCPRegistry_Has( cName )
      RETURN MCPError( xId, JSONRPC_ERR_INVALID_PARAM, "Unknown tool", cName )
   ENDIF
   hTool := MCPRegistry_Get( cName )

   /* Trap any error inside the tool: a crashing callback must never bring
      the whole server down. The error handler block captures the stack
      WHILE THE FRAMES ARE STILL ALIVE (RECOVER would see them already
      unwound), then Break() rethrows so RECOVER receives the same oErr
      with the stack attached via oErr:cargo. */
   BEGIN SEQUENCE WITH {| o | mcp_attachStack( o ), Break( o ) }
      xRet := Eval( hTool[ "callback" ], hArgs )
   RECOVER USING oErr
      RETURN MCPResult( xId, { ;
         "content" => { { "type" => "text", "text" => mcp_errorPretty( oErr, cName ) } }, ;
         "isError" => .T. } )
   END SEQUENCE

   /* Pass-through for tools that already returned the full MCP shape. */
   IF HB_ISHASH( xRet ) .AND. "content" $ xRet
      RETURN MCPResult( xId, xRet )
   ENDIF

   /* Otherwise wrap as a single text item. */
   RETURN MCPResult( xId, { ;
      "content" => { { "type" => "text", "text" => mcp_toText( xRet ) } }, ;
      "isError" => .F. } )


/*
 * mcp_toText - Coerce any return value to a text representation suitable
 * for an MCP "text" content item. Strings stay raw; everything else gets
 * JSON-encoded so structure is preserved in a human-readable form.
 */
STATIC FUNCTION mcp_toText( xVal )
   IF HB_ISSTRING( xVal )
      RETURN xVal
   ENDIF
   RETURN hb_jsonEncode( xVal )


/*
 * mcp_attachStack - Capture the call stack into oErr:cargo.
 *
 * MUST run from inside the BEGIN SEQUENCE error handler block, BEFORE the
 * Break() call. Once Break runs, BEGIN SEQUENCE unwinds and ProcName()
 * no longer sees the original frames. We start at frame 2 to skip this
 * helper itself; the tool callback typically appears within the first
 * few frames.
 */
STATIC PROCEDURE mcp_attachStack( oErr )
   LOCAL aStack := {}, n := 2, cName, cFile
   IF ! HB_ISOBJECT( oErr )
      RETURN
   ENDIF
   DO WHILE n < 40
      cName := ProcName( n )
      IF Empty( cName )
         EXIT
      ENDIF
      cFile := ProcFile( n )
      AAdd( aStack, { ;
         "file" => iif( Empty( cFile ), "?", cFile ), ;
         "line" => ProcLine( n ), ;
         "func" => cName } )
      n++
   ENDDO
   oErr:cargo := aStack
   RETURN


/*
 * mcp_errorPretty - Build a Clipper-style human-readable error report.
 *
 * Returns a multi-line string suitable for content[0].text. Inspector and
 * Claude Desktop render it verbatim in the tool result panel, giving a
 * feel close to the classic Clipper ERRORSYS dialog.
 *
 * Format:
 *   Tool '<name>' failed.
 *
 *     <reconstructed expression>           // e.g. NIL + 1, 1 / 0, <A>[99]
 *     <human description in operation>     // e.g. "Argument error in operation '+'"
 *
 *   Arguments:                              // only when args are present
 *     <arg1>
 *     <arg2>
 *
 *   Stack (top = tool, bottom = lib):
 *     <file>:<line>  <FUNC>  [lib]?
 *     ...
 *
 *   Codes: genCode=N subCode=N osCode=N severity=N subSystem=BASE
 */
STATIC FUNCTION mcp_errorPretty( oErr, cToolName )
   LOCAL cDesc, cOp, aArgs, aLines, x, cOut, lFirst
   LOCAL cExpr, cHuman, aStack, aFrames

   IF ! HB_ISOBJECT( oErr )
      RETURN "Tool '" + hb_CStr( cToolName ) + "' failed (unknown error)."
   ENDIF

   cDesc  := hb_CStr( oErr:description )
   cOp    := hb_CStr( oErr:operation )
   aArgs  := iif( HB_ISARRAY( oErr:args ), mcp_safeArgs( oErr:args ), {} )
   aStack := iif( HB_ISARRAY( oErr:cargo ), oErr:cargo, {} )
   cExpr  := mcp_renderExpr( cOp, aArgs, oErr:genCode )
   cHuman := mcp_humanDesc( cDesc, cOp )

   aLines := {}
   AAdd( aLines, "Tool '" + hb_CStr( cToolName ) + "' failed." )
   AAdd( aLines, "" )
   AAdd( aLines, "  " + cExpr )
   AAdd( aLines, "  " + cHuman )

   IF ! Empty( aArgs )
      AAdd( aLines, "" )
      AAdd( aLines, "Arguments:" )
      FOR EACH x IN aArgs
         AAdd( aLines, "  " + mcp_renderVal( x ) )
      NEXT
   ENDIF

   IF ! Empty( aStack )
      AAdd( aLines, "" )
      AAdd( aLines, "Stack (top = tool, bottom = lib):" )
      aFrames := mcp_renderStack( aStack )
      FOR EACH x IN aFrames
         AAdd( aLines, "  " + x )
      NEXT
   ENDIF

   AAdd( aLines, "" )
   AAdd( aLines, hb_StrFormat( "Codes: genCode=%1$d subCode=%2$d osCode=%3$d severity=%4$d subSystem=%5$s", ;
      oErr:genCode, oErr:subCode, oErr:osCode, oErr:severity, hb_CStr( oErr:subSystem ) ) )

   cOut := ""
   lFirst := .T.
   FOR EACH x IN aLines
      IF ! lFirst ; cOut += Chr( 10 ) ; ENDIF
      cOut += x
      lFirst := .F.
   NEXT
   RETURN cOut


/*
 * mcp_renderExpr - Reconstruct the offending expression from operation + args.
 *
 * Examples:
 *   + with {NIL,1}            -> "NIL + 1"
 *   / with {1,0}              -> "1 / 0"
 *   array access with {arr,9} -> "<A>[9]"
 *   EG_NOVAR with op=NAME     -> "NAME"
 *   fallback                  -> "op(arg1, arg2)"
 */
STATIC FUNCTION mcp_renderExpr( cOp, aArgs, nGenCode )
   LOCAL nLen := Len( aArgs ), aOps, cBuf, x, lFirst

   /* EG_NOVAR (14): operation field holds the missing variable name. */
   IF nGenCode == 14
      RETURN cOp
   ENDIF

   /* Infix binary operators. */
   aOps := { "+", "-", "*", "/", "^", "%", "=", "==", "!=", "<>", "<", ">", "<=", ">=", ":=" }
   IF nLen == 2 .AND. AScan( aOps, cOp ) > 0
      RETURN mcp_renderVal( aArgs[ 1 ] ) + " " + cOp + " " + mcp_renderVal( aArgs[ 2 ] )
   ENDIF

   /* Array subscript. */
   IF cOp == "array access" .AND. nLen >= 2
      RETURN mcp_renderVal( aArgs[ 1 ] ) + "[" + mcp_renderVal( aArgs[ 2 ] ) + "]"
   ENDIF

   /* Fallback: f(a, b, c) */
   cBuf   := cOp + "("
   lFirst := .T.
   FOR EACH x IN aArgs
      IF ! lFirst ; cBuf += ", " ; ENDIF
      cBuf   += mcp_renderVal( x )
      lFirst := .F.
   NEXT
   cBuf += ")"
   RETURN cBuf


/*
 * mcp_renderVal - Format one scalar value for the error report.
 * Args were already passed through mcp_safeArgs, so non-scalars arrive
 * here as "<TYPE>" placeholder strings.
 */
STATIC FUNCTION mcp_renderVal( xVal )
   IF xVal == NIL
      RETURN "NIL"
   ELSEIF HB_ISSTRING( xVal )
      /* "<A>" / "<H>" placeholders coming from safeArgs pass through;
         real strings get quoted. */
      IF Left( xVal, 1 ) == "<" .AND. Right( xVal, 1 ) == ">"
         RETURN xVal
      ENDIF
      RETURN '"' + xVal + '"'
   ELSEIF HB_ISNUMERIC( xVal )
      RETURN hb_NToS( xVal )
   ELSEIF HB_ISLOGICAL( xVal )
      RETURN iif( xVal, ".T.", ".F." )
   ELSEIF HB_ISDATE( xVal )
      RETURN DToC( xVal )
   ENDIF
   RETURN "<" + ValType( xVal ) + ">"


/*
 * mcp_humanDesc - Translate the raw Harbour error description into a
 * sentence that names the operation it occurred in. Falls back to the
 * original description for unknown classes.
 */
STATIC FUNCTION mcp_humanDesc( cDesc, cOp )
   SWITCH cDesc
   CASE "Argument error"
      RETURN "Argument error in operation '" + cOp + "'"
   CASE "Zero divisor"
      RETURN "Division by zero in operation '" + cOp + "'"
   CASE "Bound error"
      RETURN "Array index out of range in operation '" + cOp + "'"
   CASE "Variable does not exist"
      RETURN "Undeclared variable"
   ENDSWITCH
   IF ! Empty( cOp )
      RETURN cDesc + " in operation '" + cOp + "'"
   ENDIF
   RETURN cDesc


/*
 * mcp_renderStack - Format the structured stack frames captured by
 * mcp_attachStack. Frames whose source file is under "src/" or "src\\"
 * (the library itself) get tagged "[lib]" so the reader's eye jumps
 * straight to the application frames.
 */
STATIC FUNCTION mcp_renderStack( aFrames )
   LOCAL aOut := {}, hFrame, cFile, cTag
   FOR EACH hFrame IN aFrames
      cFile := hb_HGetDef( hFrame, "file", "?" )
      cTag  := iif( "src\" $ cFile .OR. "src/" $ cFile, "  [lib]", "" )
      AAdd( aOut, hb_StrFormat( "%1$s:%2$d  %3$s%4$s", ;
         cFile, ;
         hb_HGetDef( hFrame, "line", 0 ), ;
         hb_HGetDef( hFrame, "func", "?" ), ;
         cTag ) )
   NEXT
   RETURN aOut


/*
 * mcp_safeArgs - Sanitize Error :args for JSON encoding. Workareas,
 * code blocks, objects, hashes-with-cycles all break hb_jsonEncode or
 * produce noise. Scalars pass through; anything else collapses to a
 * "<TYPE>" tag so the client at least knows what was passed in.
 */
STATIC FUNCTION mcp_safeArgs( aArgs )
   LOCAL aOut := {}, x
   FOR EACH x IN aArgs
      IF x == NIL .OR. HB_ISSTRING( x ) .OR. HB_ISNUMERIC( x ) .OR. ;
         HB_ISLOGICAL( x ) .OR. HB_ISDATE( x )
         AAdd( aOut, x )
      ELSE
         AAdd( aOut, hb_StrFormat( "<%1$s>", ValType( x ) ) )
      ENDIF
   NEXT
   RETURN aOut
