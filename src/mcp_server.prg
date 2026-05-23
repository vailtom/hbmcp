/*
 * mcp_server.prg - Public API and the stdin/stdout main loop
 * Author: Vailton Renato <vailtom at gmail dot com>
 * Release: 2026-05-23
 *
 * Role in the architecture
 * ------------------------
 * The face of the library. Application code only ever needs to call:
 *   MCPRegisterTool() - declare a tool
 *   MCPRun()          - hand control to the server loop
 *   MCPLog()          - write to stderr (optional)
 *
 * MCP / JSON-RPC concepts touched
 * -------------------------------
 * - stdio transport: stdin = inbound JSON-RPC, stdout = outbound JSON-RPC
 * - Newline-delimited framing: exactly one message per line
 * - stdout is RESERVED for the protocol. Anything else printed there (a
 *   stray ? statement, a debug echo) will corrupt the stream and the
 *   client will disconnect. Use MCPLog() / OutErr() for diagnostics.
 *
 * Main loop (multi-threaded)
 * --------------------------
 *
 *     +------------+      +-----------+      +--------------+
 *     |   stdin    | ---> | readLine  | ---> |   MCPParse   |
 *     |  (client)  |      | (LF term) |      | (jsonrpc.prg)|
 *     +------------+      +-----------+      +------+-------+
 *                                                   |
 *                              tools/call           |   initialize / tools/list / ping / notifications
 *                                +------------------+------------------+
 *                                |                                     |
 *                                v                                     v
 *                       hb_threadStart                          mcp_dispatch_sync
 *                       mcp_worker( hReq )                      (this thread)
 *                                |                                     |
 *                       hb_cdpSelect("UTF8")                            |
 *                       MCPDispatch                                     |
 *                                |                                     |
 *                                +-----------------+-------------------+
 *                                                  |
 *                                       +----------v----------+
 *                                       | mcp_writeLine       |
 *                                       |   mutex stdout      |
 *                                       |   OutStd + LF       |
 *                                       +---------------------+
 *
 * tools/call runs in its own preemptive thread so a slow tool does not
 * block the stdin reader or other clients. Reader stays single-threaded
 * (only one FRead(0) at a time). stdout writes are mutex-serialized so
 * worker responses never interleave bytes on the wire. EOF on stdin
 * breaks the loop; pending worker threads are joined before return.
 *
 * Build requirement
 * -----------------
 * The library and every executable that links it MUST be built with -mt.
 * STATIC vars in this file (mutex handles, log level, server identity)
 * assume Harbour MT runtime.
 *
 * Application contract
 * --------------------
 * - Call MCPRegisterTool() and MCPSetServerInfo() BEFORE MCPRun(). The
 *   registry is treated as read-only once MCPRun starts; concurrent
 *   workers iterate it without locking.
 * - Tool callbacks must own their own RDD workareas - open, scan, close
 *   inside the callback. A workarea opened in thread A is invisible to
 *   thread B.
 *
 * Reading order
 * -------------
 * Last file in the library. After mcp_jsonrpc.prg, mcp_registry.prg,
 * mcp_protocol.prg. Then read samples/echo_server.prg for a usage example.
 */

#include "hbmcp.ch"


STATIC s_nLogLevel := MCP_LOG_INFO

/* Shared output mutexes. Created in MCPRun() to ensure they exist before
   any worker thread starts. Multiple threads may write to stdout/stderr,
   but each line must reach the wire atomically. */
STATIC s_hStdoutMutex
STATIC s_hStderrMutex


/*
 * MCPRegisterTool - Public wrapper around the registry.
 *
 * Defined here (not in mcp_registry.prg) so application code sees a single
 * "public surface" file. Same semantics as MCPRegistry_Add().
 *
 * Parameters:
 *   cName     - Tool name (string, non-empty). Must be unique.
 *   cDesc     - Human-readable description.
 *   hSchema   - JSON Schema (as a Harbour hash) describing the arguments.
 *   bCallback - Code block {| hArgs | ... } returning the tool's result.
 *
 * Returns:
 *   Logical - .T. on success.
 *
 * Example:
 *   MCPRegisterTool( ;
 *      "sum", "Adds two integers.", ;
 *      { "type" => "object", ;
 *        "properties" => { ;
 *           "a" => { "type" => "integer" }, ;
 *           "b" => { "type" => "integer" } }, ;
 *        "required" => { "a", "b" } }, ;
 *      {| hArgs | hb_NToS( hArgs[ "a" ] + hArgs[ "b" ] ) } )
 */
FUNCTION MCPRegisterTool( cName, cDesc, hSchema, bCallback )
   RETURN MCPRegistry_Add( cName, cDesc, hSchema, bCallback )


/*
 * MCPSetLogLevel - Set the stderr log threshold. Returns the previous level
 * so callers can save/restore around a noisy section.
 */
FUNCTION MCPSetLogLevel( nLevel )
   LOCAL nOld := s_nLogLevel
   IF HB_ISNUMERIC( nLevel )
      s_nLogLevel := nLevel
   ENDIF
   RETURN nOld


/*
 * MCPLog - Emit a single log line to stderr, gated by level threshold.
 *
 * stderr is used (never stdout) because the JSON-RPC stream owns stdout.
 * Anything you write to stdout will be parsed by the client as a message
 * and almost certainly fail.
 *
 * Parameters:
 *   nLevel - One of MCP_LOG_DEBUG / INFO / WARN / ERROR.
 *   cMsg   - Free-form text. hb_CStr() is used so non-string values pass
 *            through without crashing.
 */
FUNCTION MCPLog( nLevel, cMsg )
   LOCAL cLevel, cLine
   IF ! HB_ISNUMERIC( nLevel ) .OR. nLevel < s_nLogLevel
      RETURN NIL
   ENDIF
   SWITCH nLevel
   CASE MCP_LOG_DEBUG ; cLevel := "DEBUG" ; EXIT
   CASE MCP_LOG_INFO  ; cLevel := "INFO"  ; EXIT
   CASE MCP_LOG_WARN  ; cLevel := "WARN"  ; EXIT
   CASE MCP_LOG_ERROR ; cLevel := "ERROR" ; EXIT
   OTHERWISE          ; cLevel := "?"
   ENDSWITCH
   cLine := hb_StrFormat( "[%1$s] %2$s%3$s", cLevel, hb_CStr( cMsg ), hb_eol() )
   IF s_hStderrMutex != NIL
      hb_mutexLock( s_hStderrMutex )
      OutErr( cLine )
      hb_mutexUnlock( s_hStderrMutex )
   ELSE
      OutErr( cLine )
   ENDIF
   RETURN NIL


/*
 * MCPRun - Hand control to the server. Blocks until stdin closes.
 *
 * Per-iteration:
 *   1. Read one line from stdin (LF-terminated; CR is stripped).
 *   2. Skip empty lines (defensive; spec says one message per line, but
 *      blank lines are sometimes injected by tooling).
 *   3. Parse. On parse failure, emit a JSONRPC_ERR_PARSE with id=null
 *      (the spec says id MUST be null when it can't be determined).
 *   4. Dispatch. The protocol layer returns either a JSON string or NIL.
 *   5. Write the response (if any) followed by an LF.
 *
 * Encoding:
 *   MCP messages are UTF-8. We explicitly REQUEST the UTF-8 codepage and
 *   select it at startup so Harbour string operations don't mojibake
 *   non-ASCII content.
 *
 * Returns:
 *   0 on clean EOF.
 */
FUNCTION MCPRun()
   LOCAL cLine, hReq, cMethod

   s_hStdoutMutex := hb_mutexCreate()
   s_hStderrMutex := hb_mutexCreate()

   REQUEST HB_CODEPAGE_UTF8
   hb_cdpSelect( "UTF8" )

   MCPLog( MCP_LOG_INFO, "hbmcp " + HBMCP_VERSION + " ready (protocol " + HBMCP_PROTOCOL_VERSION + ")" )

   DO WHILE ( cLine := mcp_readLine() ) != NIL
      IF Empty( cLine )
         LOOP
      ENDIF

      hReq := MCPParse( cLine )
      IF hReq == NIL
         mcp_writeLine( MCPError( NIL, JSONRPC_ERR_PARSE, "Parse error" ) )
         LOOP
      ENDIF

      cMethod := hb_HGetDef( hReq, "method", "" )
      IF cMethod == "tools/call"
         /* Offload to a worker thread. Reader continues immediately, so
            cheap requests (ping, tools/list) interleave with slow tools. */
         hb_threadStart( {| hR | mcp_worker( hR ) }, hReq )
      ELSE
         mcp_dispatch_sync( hReq )
      ENDIF
   ENDDO

   /* Wait for workers still running on a tool callback so their JSON
      responses reach the client before the process exits. */
   hb_threadWaitForAll()

   MCPLog( MCP_LOG_INFO, "stdin closed, exiting" )
   RETURN 0


/*
 * mcp_worker - Entry point for a per-call worker thread.
 *
 * Each thread sets its own codepage (Harbour MT codepage state is per-
 * thread; the main thread's hb_cdpSelect does not propagate). Then it
 * runs the normal dispatch path; the write helper handles serialization.
 */
STATIC PROCEDURE mcp_worker( hReq )
   LOCAL cResp
   hb_cdpSelect( "UTF8" )
   cResp := MCPDispatch( hReq )
   IF cResp != NIL
      mcp_writeLine( cResp )
   ENDIF
   RETURN


/*
 * mcp_dispatch_sync - Inline dispatch used on the reader thread for
 * cheap and lifecycle-critical methods (initialize, tools/list, ping,
 * notifications). Keeps message ordering deterministic for them.
 */
STATIC PROCEDURE mcp_dispatch_sync( hReq )
   LOCAL cResp := MCPDispatch( hReq )
   IF cResp != NIL
      mcp_writeLine( cResp )
   ENDIF
   RETURN


/*
 * mcp_readLine - Read one LF-terminated line from stdin (file handle 0).
 *
 * Reads one byte at a time. Inefficient for huge messages, but correct and
 * portable across Windows/Linux without worrying about console buffering.
 *
 * Conventions:
 *   - Returns NIL on EOF (clean shutdown signal).
 *   - Returns "" for an empty line (client sent just a "\n").
 *   - Strips a trailing CR if any (Windows clients may send CRLF).
 *
 * Why FRead() byte-at-a-time instead of a higher-level helper:
 *   We need to know exactly when a single message ends. Bulk reads would
 *   either block waiting for more bytes than the client sent, or read past
 *   a newline and have to be re-buffered. One byte at a time keeps the
 *   logic trivial.
 */
STATIC FUNCTION mcp_readLine()
   LOCAL cBuf := ""
   LOCAL cByte := Space( 1 )
   LOCAL nRead

   DO WHILE .T.
      nRead := FRead( 0, @cByte, 1 )
      IF nRead <= 0
         /* EOF or error: if we already have content, treat it as the last
            line; otherwise signal end-of-stream to the caller. */
         IF Empty( cBuf )
            RETURN NIL
         ENDIF
         RETURN cBuf
      ENDIF
      IF cByte == Chr( 10 )       /* LF: end of message */
         EXIT
      ENDIF
      IF cByte == Chr( 13 )       /* CR (from CRLF): drop silently */
         LOOP
      ENDIF
      cBuf += cByte
   ENDDO
   RETURN cBuf


/*
 * mcp_writeLine - Write one JSON message to stdout, terminated by LF.
 *
 * Uses OutStd() to bypass any GT buffering. We append exactly one LF
 * (Chr(10)); CRLF would be wrong on the wire - the MCP transport is
 * byte-exact newline-delimited, not text-mode.
 *
 * Mutex-protected so worker threads cannot interleave bytes of two
 * concurrent responses. The mutex is created in MCPRun(); calls that
 * happen before MCPRun (e.g. from tests) fall back to a plain OutStd.
 */
STATIC PROCEDURE mcp_writeLine( cJson )
   LOCAL cOut := cJson + Chr( 10 )
   IF s_hStdoutMutex != NIL
      hb_mutexLock( s_hStdoutMutex )
      OutStd( cOut )
      hb_mutexUnlock( s_hStdoutMutex )
   ELSE
      OutStd( cOut )
   ENDIF
   RETURN
