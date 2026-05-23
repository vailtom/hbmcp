/*
 * echo_server.prg - Canonical minimal MCP server
 *
 * This sample is meant to be read top-to-bottom. It does the smallest
 * useful thing: registers two tools and hands control to the library.
 *
 * What an MCP server actually IS, in one paragraph
 * ------------------------------------------------
 * A console program that reads one JSON-RPC message per line from stdin
 * and writes one JSON-RPC response per line to stdout. The client (Claude
 * Desktop, MCP Inspector, etc.) spawns this .exe, pipes JSON in, and
 * reads JSON out. The library hides the parsing and lifecycle plumbing;
 * the application only declares what tools it offers.
 *
 * Build (from this directory)
 * ---------------------------
 *   hbmk2 echo_server.hbp
 *
 * The .hbp links the hbmcp library and (importantly) passes -gtcgi so the
 * executable is a true console app - without it, Harbour would attach a
 * windowed GT and break the stdio transport.
 *
 * Try it manually
 * ---------------
 *   echo {"jsonrpc":"2.0","id":1,"method":"initialize","params":{}} | echo_server.exe
 *
 * Or with the MCP Inspector (browser UI):
 *   npx @modelcontextprotocol/inspector ./echo_server.exe
 */

#include "hbmcp.ch"


PROCEDURE Main()

   /* -----------------------------------------------------------------
    * Identify this server in the initialize handshake.
    *
    * Optional. If omitted, the library reports itself as "hbmcp" with
    * the library version. Override these so clients (Claude Desktop,
    * MCP Inspector) display YOUR product name and version instead.
    * ----------------------------------------------------------------- */
   MCPSetServerInfo( "echo-server", "1.0.0" )

   /* -----------------------------------------------------------------
    * Tool #1: "echo"
    *
    * Anatomy of a tool registration:
    *   - Name     : the string the client uses in tools/call.
    *   - Desc     : free-form human description shown in tool pickers.
    *   - Schema   : JSON Schema (as a Harbour hash) describing the input.
    *                The client uses it to validate args before sending,
    *                and to render forms in UIs like the MCP Inspector.
    *   - Callback : a code block. Receives the parsed `arguments` hash;
    *                returns any value. Strings come back as a single
    *                text content item; everything else gets JSON-encoded.
    * ----------------------------------------------------------------- */
   MCPRegisterTool( ;
      "echo", ;
      "Returns the text it received as argument.", ;
      { ;
         "type"       => "object", ;
         "properties" => { ;
            "text" => { "type" => "string", "description" => "Text to echo back" } }, ;
         "required"   => { "text" } }, ;
      {| hArgs | "echo: " + hb_HGetDef( hArgs, "text", "" ) } )

   /* -----------------------------------------------------------------
    * Tool #2: "sum"
    *
    * Same shape as above, but with two integer parameters. Note how the
    * callback uses hb_HGetDef() to read optional arguments - even though
    * the schema marks them as required, defensive reads guard against a
    * misbehaving client. The result is converted to string via hb_NToS()
    * because tool outputs travel as text by default.
    * ----------------------------------------------------------------- */
   MCPRegisterTool( ;
      "sum", ;
      "Adds two integers.", ;
      { ;
         "type"       => "object", ;
         "properties" => { ;
            "a" => { "type" => "integer" }, ;
            "b" => { "type" => "integer" } }, ;
         "required"   => { "a", "b" } }, ;
      {| hArgs | hb_NToS( hb_HGetDef( hArgs, "a", 0 ) + hb_HGetDef( hArgs, "b", 0 ) ) } )

   /* -----------------------------------------------------------------
    * Run the server.
    *
    * MCPRun() blocks: it reads stdin line by line, dispatches each
    * message to the right handler, and writes responses to stdout. It
    * returns only when stdin closes (the client disconnected) or on a
    * fatal error.
    *
    * Nothing else should be printed to stdout from here on - anything
    * not produced by the library will corrupt the JSON-RPC stream. Use
    * MCPLog() if you need diagnostics; it goes to stderr.
    * ----------------------------------------------------------------- */
   MCPRun()

   RETURN
