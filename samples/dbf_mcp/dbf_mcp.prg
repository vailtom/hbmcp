/*
 * dbf_mcp.prg - DBF/NTX navigation MCP server (Harbour port of dbf-mcp-server).
 *
 * Exposes 25 read-only tools for browsing legacy DBF/NTX datasets (NetPlus
 * ERP and similar). All RDD operations are funneled through a single worker
 * thread (see dbf_workspace.prg) so cursor state survives across calls in
 * the same MCP session.
 *
 * Build (from this directory)
 *   hbmk2 dbf_mcp.hbp
 *
 * Configuration
 *   dbf_mcp.ini next to the .exe (or path in env DBF_MCP_CONFIG).
 *   DBF_ROOT overrides active_root.
 *   See config.example.ini for the schema.
 *
 * Smoke test
 *   echo {"jsonrpc":"2.0","id":1,"method":"initialize","params":{}} | dbf_mcp.exe
 */

#include "hbmcp.ch"


PROCEDURE Main()

   dbf_LoadConfig()
   dbf_StartWorker()

   MCPSetServerInfo( "dbf-mcp", "1.0.0" )

   dbf_RegisterTools()

   MCPLog( MCP_LOG_INFO, "dbf-mcp ready. root=" + dbf_ActiveRoot() + " cfg=" + dbf_ConfigPath() )

   /* Custom run loop instead of MCPRun(): dispatch synchronously so we can
      cleanly shut down our dedicated DBF worker thread on stdin EOF (the
      library's MCPRun blocks forever in hb_threadWaitForAll otherwise). */
   dbf_RunLoop()
   dbf_StopWorker()
   RETURN


STATIC PROCEDURE dbf_RunLoop()
   LOCAL cLine, hReq, cResp

   REQUEST HB_CODEPAGE_UTF8
   hb_cdpSelect( "UTF8" )

   DO WHILE ( cLine := dbf_StdinReadLine() ) != NIL
      IF Empty( cLine )
         LOOP
      ENDIF
      hReq := MCPParse( cLine )
      IF hReq == NIL
         dbf_StdoutWriteLine( MCPError( NIL, JSONRPC_ERR_PARSE, "Parse error" ) )
         LOOP
      ENDIF
      cResp := MCPDispatch( hReq )
      IF cResp != NIL
         dbf_StdoutWriteLine( cResp )
      ENDIF
   ENDDO
   MCPLog( MCP_LOG_INFO, "stdin closed, shutting down" )
   RETURN


STATIC FUNCTION dbf_StdinReadLine()
   LOCAL cBuf := ""
   LOCAL cByte := Space( 1 )
   LOCAL nRead

   DO WHILE .T.
      nRead := FRead( 0, @cByte, 1 )
      IF nRead <= 0
         IF Empty( cBuf )
            RETURN NIL
         ENDIF
         RETURN cBuf
      ENDIF
      IF cByte == Chr( 10 )
         EXIT
      ENDIF
      IF cByte == Chr( 13 )
         LOOP
      ENDIF
      cBuf += cByte
   ENDDO
   RETURN cBuf


STATIC PROCEDURE dbf_StdoutWriteLine( cJson )
   OutStd( cJson + Chr( 10 ) )
   RETURN


STATIC PROCEDURE dbf_RegisterTools()

   /* ---- root / config ---- */

   MCPRegisterTool( ;
      "list_roots", ;
      "List configured roots, active root, workdir and config path.", ;
      { "type" => "object", "properties" => { => }, "required" => {} }, ;
      {| hArgs | dbf_Dispatch( "list_roots", hArgs ) } )

   MCPRegisterTool( ;
      "get_active_root", ;
      "Return the current active root path and config path.", ;
      { "type" => "object", "properties" => { => }, "required" => {} }, ;
      {| hArgs | dbf_Dispatch( "get_active_root", hArgs ) } )

   MCPRegisterTool( ;
      "set_active_root", ;
      "Switch the active root. Accepts a configured name or a path. Closes all open tables.", ;
      { ;
         "type"       => "object", ;
         "properties" => { ;
            "root" => { "type" => "string", "description" => "Named root from [roots] or a filesystem path" } }, ;
         "required"   => { "root" } }, ;
      {| hArgs | dbf_Dispatch( "set_active_root", hArgs ) } )

   MCPRegisterTool( ;
      "save_config", ;
      "Persist the current configuration to the INI file on disk.", ;
      { "type" => "object", "properties" => { => }, "required" => {} }, ;
      {| hArgs | dbf_Dispatch( "save_config", hArgs ) } )

   /* ---- discovery ---- */

   MCPRegisterTool( ;
      "list_tables", ;
      "List DBF files under the active root. recursive=true descends into subfolders.", ;
      { ;
         "type"       => "object", ;
         "properties" => { ;
            "recursive" => { "type" => "boolean", "default" => .F. } }, ;
         "required"   => {} }, ;
      {| hArgs | dbf_Dispatch( "list_tables", hArgs ) } )

   MCPRegisterTool( ;
      "list_all_indexes", ;
      "List all NTX index files under the active root.", ;
      { ;
         "type"       => "object", ;
         "properties" => { ;
            "recursive" => { "type" => "boolean", "default" => .F. } }, ;
         "required"   => {} }, ;
      {| hArgs | dbf_Dispatch( "list_all_indexes", hArgs ) } )

   MCPRegisterTool( ;
      "get_table_info", ;
      "Full metadata for a table: fields (name, type, length) and matching NTX indexes.", ;
      { ;
         "type"       => "object", ;
         "properties" => { ;
            "table" => { "type" => "string", "description" => "Table name, relative path or absolute path" } }, ;
         "required"   => { "table" } }, ;
      {| hArgs | dbf_Dispatch( "get_table_info", hArgs ) } )

   MCPRegisterTool( ;
      "list_fields", ;
      "Field definitions (name, type, length, decimals, offset) for a table.", ;
      { ;
         "type"       => "object", ;
         "properties" => { ;
            "table" => { "type" => "string" } }, ;
         "required"   => { "table" } }, ;
      {| hArgs | dbf_Dispatch( "list_fields", hArgs ) } )

   MCPRegisterTool( ;
      "list_indexes", ;
      "Matching NTX indexes for a table (same-stem only) with order number and key_expr.", ;
      { ;
         "type"       => "object", ;
         "properties" => { ;
            "table" => { "type" => "string" } }, ;
         "required"   => { "table" } }, ;
      {| hArgs | dbf_Dispatch( "list_indexes", hArgs ) } )

   /* ---- session management ---- */

   MCPRegisterTool( ;
      "open_table", ;
      "Open a DBF and make it the active table. Optionally attach NTX index paths.", ;
      { ;
         "type"       => "object", ;
         "properties" => { ;
            "table"   => { "type" => "string" }, ;
            "indexes" => { "type" => "array", "items" => { "type" => "string" } } }, ;
         "required"   => { "table" } }, ;
      {| hArgs | dbf_Dispatch( "open_table", hArgs ) } )

   MCPRegisterTool( ;
      "get_active_table", ;
      "Summary of the currently active table.", ;
      { "type" => "object", "properties" => { => }, "required" => {} }, ;
      {| hArgs | dbf_Dispatch( "get_active_table", hArgs ) } )

   MCPRegisterTool( ;
      "close_active_table", ;
      "Close the active table and release its workarea.", ;
      { "type" => "object", "properties" => { => }, "required" => {} }, ;
      {| hArgs | dbf_Dispatch( "close_active_table", hArgs ) } )

   MCPRegisterTool( ;
      "close_table", ;
      "Close a specific table by name or path.", ;
      { ;
         "type"       => "object", ;
         "properties" => { ;
            "table" => { "type" => "string" } }, ;
         "required"   => { "table" } }, ;
      {| hArgs | dbf_Dispatch( "close_table", hArgs ) } )

   MCPRegisterTool( ;
      "close_all_tables", ;
      "Close every open table. Use before reindexing or any exclusive operation on the DBF/NTX files.", ;
      { "type" => "object", "properties" => { => }, "required" => {} }, ;
      {| hArgs | dbf_Dispatch( "close_all_tables", hArgs ) } )

   /* ---- cursor controls ---- */

   MCPRegisterTool( ;
      "set_order", ;
      "Select the active index by 1-based order number or by name.", ;
      { ;
         "type"       => "object", ;
         "properties" => { ;
            "order" => { "description" => "Integer order or string index name" }, ;
            "table" => { "type" => "string" } }, ;
         "required"   => { "order" } }, ;
      {| hArgs | dbf_Dispatch( "set_order", hArgs ) } )

   MCPRegisterTool( ;
      "get_deleted", ;
      "Return the current deleted-records visibility flag for the session.", ;
      { ;
         "type"       => "object", ;
         "properties" => { ;
            "table" => { "type" => "string" } }, ;
         "required"   => {} }, ;
      {| hArgs | dbf_Dispatch( "get_deleted", hArgs ) } )

   MCPRegisterTool( ;
      "set_deleted", ;
      "Show or hide deleted records for the session (flag=true shows deleted).", ;
      { ;
         "type"       => "object", ;
         "properties" => { ;
            "flag"  => { "type" => "boolean" }, ;
            "table" => { "type" => "string" } }, ;
         "required"   => { "flag" } }, ;
      {| hArgs | dbf_Dispatch( "set_deleted", hArgs ) } )

   /* ---- queries / navigation ---- */

   MCPRegisterTool( ;
      "query_records", ;
      "Query records with optional filters and field projection. filters supports object format ({field,op,value}) and string format (FIELD OP VALUE). String operators: =, !=, <, <=, >, >=. Object operators: eq, ne, lt, lte, gt, gte, contains, startswith, endswith, in, between. Single eq filter on indexed field auto-uses seek.", ;
      { ;
         "type"       => "object", ;
         "properties" => { ;
            "table"           => { "type" => "string" }, ;
            "limit"           => { "type" => "integer", "default" => 50 }, ;
            "offset"          => { "type" => "integer", "default" => 0 }, ;
            "order"           => { "description" => "Integer or string index name" }, ;
            "include_deleted" => { "type" => "boolean" }, ;
            "filters"         => { "description" => "String, object, or array (mixed) of filters. Examples: EST_COD = 11; [{field:EST_COD,op:eq,value:11}]; [EST_GRUPO = 13,{field:EST_SUB,op:eq,value:03}]" }, ;
            "fields"          => { "type" => "array", "items" => { "type" => "string" } } }, ;
         "required"   => {} }, ;
      {| hArgs | dbf_Dispatch( "query_records", hArgs ) } )

   MCPRegisterTool( ;
      "current_record", ;
      "Return the record at the current cursor position without moving. Also exposes recno, BOF/EOF, deleted flag via state.", ;
      { ;
         "type"       => "object", ;
         "properties" => { ;
            "table" => { "type" => "string" } }, ;
         "required"   => {} }, ;
      {| hArgs | dbf_Dispatch( "current_record", hArgs ) } )

   MCPRegisterTool( ;
      "get_record", ;
      "Fetch a single record by physical record number (1-based).", ;
      { ;
         "type"       => "object", ;
         "properties" => { ;
            "recno" => { "type" => "integer" }, ;
            "table" => { "type" => "string" } }, ;
         "required"   => { "recno" } }, ;
      {| hArgs | dbf_Dispatch( "get_record", hArgs ) } )

   MCPRegisterTool( ;
      "seek_record", ;
      "DBSEEK on the active index. softseek=true positions at first key >= value.", ;
      { ;
         "type"       => "object", ;
         "properties" => { ;
            "value"    => { "description" => "Key value to seek" }, ;
            "softseek" => { "type" => "boolean", "default" => .F. }, ;
            "table"    => { "type" => "string" } }, ;
         "required"   => { "value" } }, ;
      {| hArgs | dbf_Dispatch( "seek_record", hArgs ) } )

   MCPRegisterTool( ;
      "records_since", ;
      "Soft-seek to value then return all records forward to EOF.", ;
      { ;
         "type"       => "object", ;
         "properties" => { ;
            "value" => { "description" => "Starting key value" }, ;
            "table" => { "type" => "string" } }, ;
         "required"   => { "value" } }, ;
      {| hArgs | dbf_Dispatch( "records_since", hArgs ) } )

   MCPRegisterTool( ;
      "go_top", ;
      "Move to the first record (active index or physical order).", ;
      { ;
         "type"       => "object", ;
         "properties" => { ;
            "table" => { "type" => "string" } }, ;
         "required"   => {} }, ;
      {| hArgs | dbf_Dispatch( "go_top", hArgs ) } )

   MCPRegisterTool( ;
      "go_bottom", ;
      "Move to the last record (active index or physical order).", ;
      { ;
         "type"       => "object", ;
         "properties" => { ;
            "table" => { "type" => "string" } }, ;
         "required"   => {} }, ;
      {| hArgs | dbf_Dispatch( "go_bottom", hArgs ) } )

   MCPRegisterTool( ;
      "skip", ;
      "Advance n records forward (positive) or backward (negative).", ;
      { ;
         "type"       => "object", ;
         "properties" => { ;
            "n"     => { "type" => "integer", "default" => 1 }, ;
            "table" => { "type" => "string" } }, ;
         "required"   => {} }, ;
      {| hArgs | dbf_Dispatch( "skip", hArgs ) } )

   RETURN

