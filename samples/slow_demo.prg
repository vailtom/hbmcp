/*
 * slow_demo.prg - MT-behavior demonstration MCP server
 *
 * Role in the samples set
 * -----------------------
 * Optional, special-purpose. Use it to *see* the multi-threaded behavior
 * the library claims: tools/call runs on a worker thread, so a slow tool
 * does not block the reader. The other samples are too fast to observe
 * this; here we deliberately introduce latency.
 *
 * MCP / JSON-RPC concepts touched
 * -------------------------------
 * - tools/call dispatch into a worker thread (mcp_server.prg)
 * - ping handled synchronously on the reader thread
 * - Response interleaving: ids arrive in completion order, not request order
 * - Wire format: one LF-delimited JSON per response (MCP 2024-11-05 - Tools)
 *
 * Reading order
 * -------------
 * Standalone. Read after the lib is understood. No relation to dbf_query
 * or mini_erp.
 *
 * How to read the output
 * ----------------------
 * Each tool callback logs a "start" and "done" line to STDERR via MCPLog.
 * stdout is the protocol stream (JSON responses) and stderr is narration.
 * When you run a demo in a terminal you see both intermixed:
 *
 *   [INFO] [sleep_ms] start ms=2000     <- stderr (worker A entered)
 *   [INFO] [sleep_ms] start ms=500      <- stderr (worker B entered while A waits)
 *   [INFO] [sleep_ms] done ms=500       <- stderr (B finished first)
 *   {"jsonrpc":"2.0","id":3,...}        <- stdout (response for B)
 *   [INFO] [sleep_ms] done ms=2000      <- stderr (A finished)
 *   {"jsonrpc":"2.0","id":2,...}        <- stdout (response for A)
 *
 * Seeing "start ms=500" BEFORE "done ms=2000" is the visual proof that
 * tools/call runs on a worker thread - if the server were single-threaded,
 * the 500ms sleep could not start until the 2000ms one finished.
 *
 * To hide narration:        `... | ./slow_demo.exe 2>/dev/null`
 * To see narration only:    `... | ./slow_demo.exe 2>&1 >/dev/null`
 *
 * Demonstrations
 * --------------
 *
 * Demo 1 - tools/call responses arrive out of order
 *
 *   printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
 *   {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"sleep_ms","arguments":{"ms":2000}}}
 *   {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"sleep_ms","arguments":{"ms":500}}}
 *   ' | ./slow_demo.exe
 *
 *   Expected: id=1, then id=3 (~500ms later), then id=2 (~2000ms after start).
 *
 * Demo 2 - ping bypasses a slow worker
 *
 *   printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
 *   {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"sleep_ms","arguments":{"ms":3000}}}
 *   {"jsonrpc":"2.0","id":3,"method":"ping"}
 *   ' | ./slow_demo.exe
 *
 *   Expected: id=1, id=3 (immediate, reader thread), id=2 (~3s later).
 *
 * Demo 3 - CPU-bound worker preempted, reader still responsive
 *
 *   printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
 *   {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"busy_count","arguments":{"n":50000000}}}
 *   {"jsonrpc":"2.0","id":3,"method":"ping"}
 *   ' | ./slow_demo.exe
 *
 *   Expected: id=3 arrives while id=2 is still crunching (OS preemption).
 *
 * Build
 * -----
 *   hbmk2 slow_demo.hbp
 */

#include "hbmcp.ch"


PROCEDURE Main()

   MCPSetServerInfo( "slow-demo-mcp", "1.0.0" )

   /* -----------------------------------------------------------------
    * Tool: sleep_ms
    *
    * Voluntary yield via hb_idleSleep. Reader thread is unaffected
    * because the wait happens in the worker.
    * ----------------------------------------------------------------- */
   MCPRegisterTool( ;
      "sleep_ms", ;
      "Sleeps for the given number of milliseconds, then returns.", ;
      { ;
         "type"       => "object", ;
         "properties" => { "ms" => { "type" => "integer", "description" => "0..30000" } }, ;
         "required"   => { "ms" } }, ;
      {| hArgs | tool_sleep_ms( hArgs ) } )

   /* -----------------------------------------------------------------
    * Tool: busy_count
    *
    * CPU-bound tight loop summing 1..N. No yield, no I/O. Proves the
    * worker is on a real OS thread - the reader stays responsive only
    * because the OS preempts.
    * ----------------------------------------------------------------- */
   MCPRegisterTool( ;
      "busy_count", ;
      "Sums 1..N in a tight loop. CPU-bound demo (try N around 50_000_000).", ;
      { ;
         "type"       => "object", ;
         "properties" => { "n" => { "type" => "integer", "description" => "Upper bound" } }, ;
         "required"   => { "n" } }, ;
      {| hArgs | tool_busy_count( hArgs ) } )

   /* -----------------------------------------------------------------
    * Tool: tick
    *
    * Server-side timestamp in seconds-since-midnight. Two ticks around
    * a sleep_ms reveal how much real time elapsed for the client.
    * ----------------------------------------------------------------- */
   MCPRegisterTool( ;
      "tick", ;
      "Returns the server's Seconds() value (s since midnight, 2 decimals).", ;
      { "type" => "object", "properties" => { => }, "required" => {} }, ;
      {| hArgs | tool_tick( hArgs ) } )

   MCPRun()
   RETURN


/*
 * tool_sleep_ms - sleep_ms callback. Clamps ms into [0, 30000] so a
 * stray very large value cannot stall the worker. Returns the actual
 * wait reported back so the client can sanity-check timing.
 */
STATIC FUNCTION tool_sleep_ms( hArgs )
   LOCAL nMs := hb_HGetDef( hArgs, "ms", 0 )
   IF ! HB_ISNUMERIC( nMs ) ; nMs := 0 ; ENDIF
   nMs := Max( 0, Min( 30000, nMs ) )
   MCPLog( MCP_LOG_INFO, "[sleep_ms] start ms=" + hb_NToS( nMs ) )
   hb_idleSleep( nMs / 1000.0 )
   MCPLog( MCP_LOG_INFO, "[sleep_ms] done ms=" + hb_NToS( nMs ) )
   RETURN { "ms" => nMs, "done" => .T. }


/*
 * tool_busy_count - busy_count callback. Plain FOR loop accumulating a
 * sum. Clamps N so a typo does not freeze the worker for minutes.
 */
STATIC FUNCTION tool_busy_count( hArgs )
   LOCAL nN := hb_HGetDef( hArgs, "n", 0 )
   LOCAL i, nSum := 0
   IF ! HB_ISNUMERIC( nN ) ; nN := 0 ; ENDIF
   nN := Max( 0, Min( 200000000, nN ) )
   MCPLog( MCP_LOG_INFO, "[busy_count] start n=" + hb_NToS( nN ) )
   FOR i := 1 TO nN
      nSum += i
   NEXT
   MCPLog( MCP_LOG_INFO, "[busy_count] done n=" + hb_NToS( nN ) + " sum=" + hb_NToS( nSum ) )
   RETURN { "n" => nN, "sum" => nSum }


/*
 * tool_tick - tick callback. No args. Just a clock probe.
 */
STATIC FUNCTION tool_tick( hArgs )
   HB_SYMBOL_UNUSED( hArgs )
   MCPLog( MCP_LOG_INFO, "[tick]" )
   RETURN { "seconds" => Seconds() }
