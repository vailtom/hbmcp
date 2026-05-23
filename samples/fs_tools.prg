/*
 * fs_tools.prg - Filesystem MCP server sample
 *
 * Role in the samples set
 * -----------------------
 * Second stop after echo_server. Drops the trivial in-memory tools and
 * exposes real I/O against the host file system. The point is to show how
 * a tool callback looks when it has to deal with optional arguments, missing
 * files, and richer return shapes (arrays, hashes).
 *
 * MCP / JSON-RPC concepts touched
 * -------------------------------
 * - Tools with NO arguments         (list_cwd: empty properties hash)
 * - Optional arguments with default (read_head: "lines" not required)
 * - Constrained schema via "enum"   (file_info: mode in {size,date,all})
 * - Defensive argument validation done by the tool, not the schema
 * - Returning arrays/hashes - the library JSON-encodes non-string returns
 *   into a single text content item (MCP 2024-11-05 - Tools, content[])
 * - Stderr diagnostics via MCPLog(); stdout stays clean for JSON-RPC
 *
 * Reading order
 * -------------
 * Best read after: echo_server.prg
 * Followed by:     dbf_query.prg
 *
 * Build (from samples/ directory)
 * -------------------------------
 *   hbmk2 fs_tools.hbp
 *
 * Try it
 * ------
 *   inspect.bat fs_tools
 *   or pipe JSON-RPC manually (see echo_server.prg for example commands)
 */

#include "hbmcp.ch"


PROCEDURE Main()

   MCPSetServerInfo( "fs-tools-mcp", "1.0.0" )

   /* -----------------------------------------------------------------
    * Tool: list_cwd
    *
    * Demonstrates a no-argument tool. The schema still has type=object
    * with an empty properties hash and an empty required array - clients
    * expect a valid (even if trivial) JSON Schema.
    *
    * Returns a string array. The library wraps non-string returns by
    * JSON-encoding them into a single text content item.
    * ----------------------------------------------------------------- */
   MCPRegisterTool( ;
      "list_cwd", ;
      "Lists files in the current working directory.", ;
      { ;
         "type"       => "object", ;
         "properties" => { => }, ;
         "required"   => {} }, ;
      {| hArgs | fs_list_cwd( hArgs ) } )

   /* -----------------------------------------------------------------
    * Tool: read_head
    *
    * Reads the first N lines of a text file. Note the optional argument
    * pattern: schema marks "lines" as not required, callback supplies a
    * default via hb_HGetDef(). Defensive against missing or bad input.
    * ----------------------------------------------------------------- */
   MCPRegisterTool( ;
      "read_head", ;
      "Returns the first N lines of a text file (default N=10).", ;
      { ;
         "type"       => "object", ;
         "properties" => { ;
            "path"  => { "type" => "string",  "description" => "Path to the file" }, ;
            "lines" => { "type" => "integer", "description" => "Number of lines (default 10)" } }, ;
         "required"   => { "path" } }, ;
      {| hArgs | fs_read_head( hArgs ) } )

   /* -----------------------------------------------------------------
    * Tool: file_info
    *
    * Shows a schema using "enum" to restrict argument values. The client
    * will reject anything outside {size, date, all} before sending.
    * ----------------------------------------------------------------- */
   MCPRegisterTool( ;
      "file_info", ;
      "Returns metadata for a file (size, modification date, or both).", ;
      { ;
         "type"       => "object", ;
         "properties" => { ;
            "path" => { "type" => "string" }, ;
            "mode" => { "type" => "string", "enum" => { "size", "date", "all" }, "description" => "What to return" } }, ;
         "required"   => { "path", "mode" } }, ;
      {| hArgs | fs_file_info( hArgs ) } )

   MCPRun()
   RETURN


/*
 * fs_list_cwd - List files in the process current directory.
 *
 * Parameters:
 *   hArgs - ignored. HB_SYMBOL_UNUSED silences the "unused parameter"
 *           warning that Harbour emits for argument-less tools.
 *
 * Returns:
 *   array of strings (file names). The library JSON-encodes it into a
 *   single text content item before sending it on the wire.
 */
STATIC FUNCTION fs_list_cwd( hArgs )
   LOCAL aDir, aRow, aOut := {}
   HB_SYMBOL_UNUSED( hArgs )
   aDir := Directory( "*.*" )
   FOR EACH aRow IN aDir
      AAdd( aOut, aRow[ 1 ] )    /* file name */
   NEXT
   MCPLog( MCP_LOG_DEBUG, "list_cwd: " + hb_NToS( Len( aOut ) ) + " entries" )
   RETURN aOut


/*
 * fs_read_head - Return the first N lines of a text file.
 *
 * Parameters:
 *   hArgs[ "path"  ] - string, required by schema. Path to the file.
 *   hArgs[ "lines" ] - integer, optional. Defaults to 10 via hb_HGetDef.
 *
 * Returns:
 *   array of strings (one entry per line) on success;
 *   hash { "error" => ..., "path" => ... } if the file is missing.
 *
 * Why this exists / design note:
 *   MemoLine / MLCount wrap-pad lines to a fixed width - useless for
 *   source code. hb_ATokens on Chr(10) gives one entry per real LF line,
 *   then we strip a trailing CR to neutralize CRLF files.
 */
STATIC FUNCTION fs_read_head( hArgs )
   LOCAL cPath  := hb_HGetDef( hArgs, "path", "" )
   LOCAL nLines := hb_HGetDef( hArgs, "lines", 10 )
   LOCAL cText, aLines, aOut, i, nMax

   IF Empty( cPath ) .OR. ! hb_FileExists( cPath )
      RETURN { "error" => "File not found", "path" => cPath }
   ENDIF
   IF ! HB_ISNUMERIC( nLines ) .OR. nLines <= 0
      nLines := 10
   ENDIF

   /* Split on real LF. MemoLine/MLCount wrap to a fixed width and pad with
      spaces, which is wrong for "first N lines" of a source file. */
   cText  := hb_MemoRead( cPath )
   aLines := hb_ATokens( cText, Chr( 10 ) )
   nMax   := Min( Len( aLines ), nLines )
   aOut   := {}
   FOR i := 1 TO nMax
      AAdd( aOut, iif( Right( aLines[ i ], 1 ) == Chr( 13 ), ;
         Left( aLines[ i ], Len( aLines[ i ] ) - 1 ), ;
         aLines[ i ] ) )
   NEXT
   RETURN aOut


/*
 * fs_file_info - Return file metadata, filtered by "mode".
 *
 * Parameters:
 *   hArgs[ "path" ] - string, required.
 *   hArgs[ "mode" ] - string, required, one of {"size","date","all"}.
 *                     The schema enum lets the client reject bad values
 *                     before sending; the tool still does no extra check.
 *
 * Returns:
 *   hash with at least { "path" => ... } and the requested fields:
 *     "size"     - bytes (numeric, from Directory()[1][2])
 *     "modified" - "YYYY-MM-DD HH:MM:SS" assembled from Directory() row
 *   On a missing file, hash { "error" => ..., "path" => ... } instead.
 */
STATIC FUNCTION fs_file_info( hArgs )
   LOCAL cPath := hb_HGetDef( hArgs, "path", "" )
   LOCAL cMode := hb_HGetDef( hArgs, "mode", "all" )
   LOCAL aDir, aEntry, hOut

   IF Empty( cPath ) .OR. ! hb_FileExists( cPath )
      RETURN { "error" => "File not found", "path" => cPath }
   ENDIF

   /* Directory() returns one row per match: { name, size, date, time, attr }.
      We reuse it instead of looking up hb_FileSize/hb_FileLastModified,
      which are not portable across all Harbour builds. */
   aDir := Directory( cPath )
   IF Empty( aDir )
      RETURN { "error" => "Directory() returned no entry", "path" => cPath }
   ENDIF
   aEntry := aDir[ 1 ]

   hOut := { "path" => cPath }
   IF cMode == "size" .OR. cMode == "all"
      hOut[ "size" ] := aEntry[ 2 ]
   ENDIF
   IF cMode == "date" .OR. cMode == "all"
      hOut[ "modified" ] := DToC( aEntry[ 3 ] ) + " " + aEntry[ 4 ]
   ENDIF
   RETURN hOut
