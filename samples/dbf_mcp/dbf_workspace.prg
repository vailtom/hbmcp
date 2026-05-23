/*
 * dbf_workspace.prg - Workareas state + serialization worker thread.
 *
 * Why a worker thread
 * -------------------
 * hbmcp dispatches each `tools/call` on its own thread (see mcp_server.prg).
 * Harbour RDD workareas are thread-local: an alias opened in thread A is
 * invisible to thread B. The Python dbf-mcp-server, however, exposes
 * stateful semantics (open_table -> set_order -> seek_record -> skip across
 * separate calls). To preserve that contract, every RDD operation in this
 * sample is funneled into a single dedicated worker thread that owns the
 * workareas across the lifetime of the process.
 *
 * Inter-thread protocol
 * ---------------------
 *   1. Tool callback builds a request hash { op, args, resp } where `resp`
 *      is a fresh mutex created for this one call.
 *   2. dbf_Dispatch() publishes the request on s_hReqMutex (hb_mutexNotify)
 *      and blocks on hb_mutexSubscribe of the per-call response mutex.
 *   3. Worker thread loops on hb_mutexSubscribe(s_hReqMutex), executes the
 *      op, publishes { ok, value | error } on req["resp"].
 *
 * Encoding
 * --------
 * The worker thread runs under the configured DBF codepage so Upper/Lower
 * on character fields behave correctly. Character field values are
 * translated to UTF-8 via dbf_ToUtf8() before they cross back to the
 * caller thread, so the JSON encoder emits valid UTF-8 bytes regardless of
 * the underlying DBF encoding.
 *
 * State (worker-thread only)
 *   s_hSessions   hash: dbf_path -> session hash
 *                       { "alias"      => cAlias,
 *                         "dbf_path"   => cFullPath,
 *                         "ntx_paths"  => { cPath, ... },
 *                         "index_meta" => { { "order"=>n, "name"=>cStem,
 *                                             "key_expr"=>cExpr }, ... },
 *                         "deleted_visible" => lFlag }
 *   s_cActiveRef  string: dbf_path of the active session, or NIL.
 */

#include "hbmcp.ch"
#include "set.ch"


REQUEST DBFNTX
REQUEST HB_CODEPAGE_PT850
REQUEST HB_CODEPAGE_PTISO
REQUEST HB_CODEPAGE_ESWIN
REQUEST HB_CODEPAGE_UTF8


/* Inter-thread plumbing (process-wide) */
STATIC s_hReqMutex
STATIC s_hWorkerThread
STATIC s_lStarted := .F.

/* Worker-owned state. Only the worker thread reads/writes these. */
STATIC s_hSessions   := { => }
STATIC s_cActiveRef  := NIL


/*
 * dbf_StartWorker - Spawn the singleton worker thread. Idempotent.
 */
FUNCTION dbf_StartWorker()
   IF s_lStarted
      RETURN .T.
   ENDIF
   s_hReqMutex := hb_mutexCreate()
   s_hWorkerThread := hb_threadStart( {|| dbf_WorkerLoop() } )
   s_lStarted := .T.
   RETURN .T.


/*
 * dbf_StopWorker - Tell the worker to drain and exit, then join it.
 * Called from the main loop after stdin EOF so the process can terminate.
 */
FUNCTION dbf_StopWorker()
   IF ! s_lStarted .OR. s_hWorkerThread == NIL
      RETURN .T.
   ENDIF
   hb_mutexNotify( s_hReqMutex, { "op" => "__shutdown__", "args" => { => }, "resp" => NIL } )
   hb_threadJoin( s_hWorkerThread )
   s_lStarted := .F.
   RETURN .T.


/*
 * dbf_Dispatch - Called from any thread. Synchronous round-trip to worker.
 * Returns the raw value the op produced, or raises via dbf_RaiseError when
 * the worker reported an application-level failure.
 */
FUNCTION dbf_Dispatch( cOp, hArgs )
   LOCAL hReq, hResp, lOk

   IF ! s_lStarted
      dbf_StartWorker()
   ENDIF

   hReq := { ;
      "op"   => cOp, ;
      "args" => iif( hArgs == NIL, { => }, hArgs ), ;
      "resp" => hb_mutexCreate() }

   hb_mutexNotify( s_hReqMutex, hReq )

   hResp := NIL
   lOk := hb_mutexSubscribe( hReq[ "resp" ], , @hResp )
   IF ! lOk .OR. hResp == NIL
      RETURN { "error" => "worker subscribe failed for op " + cOp }
   ENDIF
   IF hb_HGetDef( hResp, "ok", .F. )
      RETURN hResp[ "value" ]
   ENDIF
   RETURN { "error" => hb_HGetDef( hResp, "error", "unknown worker error" ) }


/*
 * dbf_WorkerLoop - Body of the worker thread. Sets the DBF codepage for
 * this thread (so Upper/Lower etc. behave correctly on data strings),
 * then drains the request queue forever.
 */
PROCEDURE dbf_WorkerLoop()
   LOCAL hReq, xValue, oErr

   hb_cdpSelect( dbf_DataCdp() )
   Set( _SET_DELETED, dbf_DeletedDefault() )
   SET DATE TO BRIT
   SET CENTURY ON
   SET EPOCH TO 1979

   MCPLog( MCP_LOG_INFO, "dbu worker started, cdp=" + dbf_DataCdp() )

   DO WHILE .T.
      hReq := NIL
      IF ! hb_mutexSubscribe( s_hReqMutex, , @hReq ) .OR. hReq == NIL
         LOOP
      ENDIF

      IF hReq[ "op" ] == "__shutdown__"
         close_all_sessions()
         MCPLog( MCP_LOG_INFO, "dbu worker stopping" )
         RETURN
      ENDIF

      BEGIN SEQUENCE WITH {| o | Break( o ) }
         xValue := dbf_HandleOp( hReq[ "op" ], hReq[ "args" ] )
         hb_mutexNotify( hReq[ "resp" ], { "ok" => .T., "value" => xValue } )
      RECOVER USING oErr
         hb_mutexNotify( hReq[ "resp" ], { "ok" => .F., "error" => dbf_ErrorMsg( oErr ) } )
      END SEQUENCE
   ENDDO

   RETURN


/*
 * dbf_ErrorMsg - Convert a caught error object/value to displayable text.
 */
STATIC FUNCTION dbf_ErrorMsg( oErr )
   IF HB_ISOBJECT( oErr )
      RETURN hb_CStr( oErr:description )
   ENDIF
   RETURN hb_CStr( oErr )


/*
 * dbf_HandleOp - DO CASE dispatch executed inside the worker thread.
 * Each op is a small static function that returns a hash/array/scalar.
 */
STATIC FUNCTION dbf_HandleOp( cOp, hArgs )

   SWITCH cOp
   CASE "list_roots"          ; RETURN op_list_roots( hArgs )
   CASE "get_active_root"     ; RETURN op_get_active_root( hArgs )
   CASE "set_active_root"     ; RETURN op_set_active_root( hArgs )
   CASE "save_config"         ; RETURN op_save_config( hArgs )
   CASE "list_tables"         ; RETURN op_list_tables( hArgs )
   CASE "list_all_indexes"    ; RETURN op_list_all_indexes( hArgs )
   CASE "get_table_info"      ; RETURN op_get_table_info( hArgs )
   CASE "list_fields"         ; RETURN op_list_fields( hArgs )
   CASE "list_indexes"        ; RETURN op_list_indexes( hArgs )
   CASE "open_table"          ; RETURN op_open_table( hArgs )
   CASE "get_active_table"    ; RETURN op_get_active_table( hArgs )
   CASE "close_active_table"  ; RETURN op_close_active_table( hArgs )
   CASE "close_table"         ; RETURN op_close_table( hArgs )
   CASE "close_all_tables"    ; RETURN op_close_all_tables( hArgs )
   CASE "set_order"           ; RETURN op_set_order( hArgs )
   CASE "set_deleted"         ; RETURN op_set_deleted( hArgs )
   CASE "get_deleted"         ; RETURN op_get_deleted( hArgs )
   CASE "query_records"       ; RETURN op_query_records( hArgs )
   CASE "get_record"          ; RETURN op_get_record( hArgs )
   CASE "current_record"      ; RETURN op_current_record( hArgs )
   CASE "seek_record"         ; RETURN op_seek_record( hArgs )
   CASE "records_since"       ; RETURN op_records_since( hArgs )
   CASE "go_top"              ; RETURN op_go_top( hArgs )
   CASE "go_bottom"           ; RETURN op_go_bottom( hArgs )
   CASE "skip"                ; RETURN op_skip( hArgs )
   ENDSWITCH
   RETURN { "error" => "unknown op: " + cOp }


/* ============================================================
 *  Path / discovery helpers (worker-thread only)
 * ============================================================ */

STATIC FUNCTION resolve_dbf( cReference )
   LOCAL cRoot := dbf_ActiveRoot()
   LOCAL cRef  := AllTrim( cReference )
   LOCAL cTry, aMatches, cRel, aFound, cLow

   IF Empty( cRef )
      dbf_Raise( "table reference is empty" )
   ENDIF

   /* Absolute */
   IF dbf_IsAbsPath( cRef ) .AND. hb_FileExists( cRef )
      RETURN hb_PathNormalize( cRef )
   ENDIF

   /* Relative direct */
   cTry := hb_PathNormalize( cRoot + cRef )
   IF hb_FileExists( cTry )
      RETURN cTry
   ENDIF
   IF hb_FileExists( cTry + ".dbf" )
      RETURN cTry + ".dbf"
   ENDIF

   /* rglob match by name or stem (case-insensitive) */
   cLow := Lower( cRef )
   aFound := hb_DirScan( cRoot, "*.dbf", "D" )
   aMatches := {}
   FOR EACH cRel IN aFound
      IF Lower( cRel[ 1 ] ) == cLow .OR. Lower( hb_FNameName( cRel[ 1 ] ) ) == cLow .OR. ;
         Lower( hb_FNameNameExt( cRel[ 1 ] ) ) == cLow
         AAdd( aMatches, hb_PathNormalize( cRoot + cRel[ 1 ] ) )
      ENDIF
   NEXT
   IF Len( aMatches ) == 0
      dbf_Raise( "DBF not found: " + cReference )
   ENDIF
   IF Len( aMatches ) > 1
      dbf_Raise( "Multiple DBFs match " + cReference + ": " + hb_JsonEncode( aMatches ) )
   ENDIF
   RETURN aMatches[ 1 ]


/*
 * rel_to_root - Convert absolute path to root-relative path when possible.
 */
STATIC FUNCTION rel_to_root( cAbsPath )
   LOCAL cRoot := dbf_ActiveRoot()
   IF Left( Lower( cAbsPath ), Len( cRoot ) ) == Lower( cRoot )
      RETURN SubStr( cAbsPath, Len( cRoot ) + 1 )
   ENDIF
   RETURN cAbsPath


/*
 * discover_indexes - List same-stem NTX files near a DBF path.
 */
STATIC FUNCTION discover_indexes( cDbfPath )
   /* Conservative: only return NTX files whose stem matches the DBF stem.
      Same trade-off the Python build settled on after timeouts on shared
      ERP folders with hundreds of indexes. */
   LOCAL cFolder := dbf_DirOf( cDbfPath )
   LOCAL cStem := Upper( hb_FNameName( cDbfPath ) )
   LOCAL aFiles, aOut, aEntry

   aFiles := hb_DirScan( cFolder, "*.ntx", "" )
   aOut := {}
   FOR EACH aEntry IN aFiles
      IF Upper( hb_FNameName( aEntry[ 1 ] ) ) == cStem
         AAdd( aOut, hb_PathNormalize( cFolder + aEntry[ 1 ] ) )
      ENDIF
   NEXT
   RETURN aOut


/*
 * dbf_DirOf - Return directory component from a full filesystem path.
 */
STATIC FUNCTION dbf_DirOf( cPath )
   LOCAL cDir := ""
   hb_FNameSplit( cPath, @cDir )
   RETURN cDir


/*
 * Cross-platform absolute path test. Windows accepts X:\, X:/, \\server\share,
 * leading \ or /. POSIX accepts a leading /.
 */
STATIC FUNCTION dbf_IsAbsPath( cPath )
   LOCAL cFirst, cSecond
   IF Empty( cPath )
      RETURN .F.
   ENDIF
   cFirst := SubStr( cPath, 1, 1 )
   IF cFirst == "\" .OR. cFirst == "/"
      RETURN .T.
   ENDIF
   IF Len( cPath ) >= 3
      cSecond := SubStr( cPath, 2, 2 )
      IF Upper( cFirst ) >= "A" .AND. Upper( cFirst ) <= "Z" .AND. ;
         ( cSecond == ":\" .OR. cSecond == ":/" )
         RETURN .T.
      ENDIF
   ENDIF
   RETURN .F.


/*
 * dbf_Raise - Raise a Harbour Error object with a custom description.
 */
STATIC PROCEDURE dbf_Raise( cMsg )
   LOCAL oErr := ErrorNew()
   oErr:description := cMsg
   Break( oErr )
   RETURN


/* ============================================================
 *  Session helpers
 * ============================================================ */

STATIC FUNCTION make_alias( cDbfPath )
   LOCAL cStem := Upper( hb_FNameName( cDbfPath ) )
   LOCAL cBase := ""
   LOCAL cAlias, i, c, n

   FOR i := 1 TO Len( cStem )
      c := SubStr( cStem, i, 1 )
      IF ( c >= "A" .AND. c <= "Z" ) .OR. ( c >= "0" .AND. c <= "9" ) .OR. c == "_"
         cBase += c
      ENDIF
   NEXT
   IF Empty( cBase ) .OR. ( cBase >= "0" .AND. cBase <= "9" )
      cBase := "T_" + cBase
   ENDIF
   cBase := Left( cBase, 10 )
   cAlias := cBase
   n := 1
   DO WHILE Select( cAlias ) != 0
      n++
      cAlias := Left( cBase, 8 ) + "_" + hb_NToS( n )
   ENDDO
   RETURN cAlias


/*
 * open_session - Open DBF/NTX into a dedicated alias and return session state.
 */
STATIC FUNCTION open_session( cDbfPath, aNtxPaths )
   LOCAL cAlias := make_alias( cDbfPath )
   LOCAL cNtx, aMeta, n, hSession

   dbUseArea( .T., "DBFNTX", cDbfPath, cAlias, .T., .T. )
   aMeta := {}
   IF aNtxPaths != NIL .AND. ! Empty( aNtxPaths )
      n := 0
      FOR EACH cNtx IN aNtxPaths
         n++
         ( cAlias )->( OrdListAdd( cNtx ) )
         AAdd( aMeta, { ;
            "order"    => n, ;
            "name"     => hb_FNameName( cNtx ), ;
            "key_expr" => AllTrim( ( cAlias )->( OrdKey( n ) ) ) } )
      NEXT
   ENDIF

   hSession := { ;
      "alias"           => cAlias, ;
      "dbf_path"        => cDbfPath, ;
      "ntx_paths"       => iif( aNtxPaths == NIL, {}, aNtxPaths ), ;
      "index_meta"      => aMeta, ;
      "deleted_visible" => ! dbf_DeletedDefault() }

   /* Position at first record (index order if any index attached). */
   ( cAlias )->( dbGoTop() )
   RETURN hSession


/*
 * close_session - Close one open alias referenced by a session hash.
 */
STATIC PROCEDURE close_session( hSession )
   LOCAL cAlias := hSession[ "alias" ]
   IF Select( cAlias ) != 0
      ( cAlias )->( dbCloseArea() )
   ENDIF
   RETURN


/*
 * close_all_sessions - Close every opened alias and reset worker session state.
 */
STATIC PROCEDURE close_all_sessions()
   LOCAL cKey
   FOR EACH cKey IN hb_HKeys( s_hSessions )
      close_session( s_hSessions[ cKey ] )
   NEXT
   s_hSessions := { => }
   s_cActiveRef := NIL
   RETURN


/*
 * active_session - Return current active session or raise if none is active.
 */
STATIC FUNCTION active_session()
   IF s_cActiveRef == NIL .OR. ! hb_HHasKey( s_hSessions, s_cActiveRef )
      dbf_Raise( "No active table. Call open_table first." )
   ENDIF
   RETURN s_hSessions[ s_cActiveRef ]


/*
 * session_for - Resolve table arg to a session, opening it lazily when needed.
 */
STATIC FUNCTION session_for( cTableArg )
   LOCAL cPath, hSession

   IF cTableArg == NIL .OR. Empty( cTableArg )
      RETURN active_session()
   ENDIF
   cPath := resolve_dbf( cTableArg )
   IF hb_HHasKey( s_hSessions, cPath )
      RETURN s_hSessions[ cPath ]
   ENDIF
   hSession := open_session( cPath, {} )
   s_hSessions[ cPath ] := hSession
   RETURN hSession


/*
 * session_summary - Build a compact runtime snapshot of session/cursor state.
 */
STATIC FUNCTION session_summary( hSession )
   LOCAL cAlias := hSession[ "alias" ]
   RETURN { ;
      "dbf_path"         => hSession[ "dbf_path" ], ;
      "indexes"          => hSession[ "ntx_paths" ], ;
      "index_count"      => Len( hSession[ "ntx_paths" ] ), ;
      "field_count"      => ( cAlias )->( FCount() ), ;
      "record_count"     => ( cAlias )->( RecCount() ), ;
      "current_recno"    => ( cAlias )->( RecNo() ), ;
      "bof"              => ( cAlias )->( Bof() ), ;
      "eof"              => ( cAlias )->( Eof() ), ;
      "deleted"          => ( cAlias )->( Deleted() ), ;
      "active_order"     => ( cAlias )->( OrdNumber( ( cAlias )->( OrdSetFocus() ) ) ), ;
      "active_index_key" => AllTrim( ( cAlias )->( OrdKey( ( cAlias )->( OrdNumber( ( cAlias )->( OrdSetFocus() ) ) ) ) ) ), ;
      "deleted_visible"  => hSession[ "deleted_visible" ] }


/*
 * Read the current record from an alias into a Harbour hash, translating
 * character fields to UTF-8.
 */
STATIC FUNCTION current_record( cAlias )
   LOCAL hRec := { => }
   LOCAL nFields := ( cAlias )->( FCount() )
   LOCAL i, cName, xVal

   FOR i := 1 TO nFields
      cName := ( cAlias )->( FieldName( i ) )
      xVal  := ( cAlias )->( FieldGet( i ) )
      IF HB_ISSTRING( xVal )
         xVal := dbf_ToUtf8( RTrim( xVal ) )
      ENDIF
      hRec[ cName ] := xVal
   NEXT
   hRec[ "_recno" ]   := ( cAlias )->( RecNo() )
   hRec[ "_deleted" ] := ( cAlias )->( Deleted() )
   RETURN hRec


/* ============================================================
 *  Operations (one per registered MCP tool)
 * ============================================================ */

STATIC FUNCTION op_list_roots( hArgs )
   HB_SYMBOL_UNUSED( hArgs )
   RETURN { ;
      "active_root" => dbf_ActiveRoot(), ;
      "workdir"     => hb_cwd(), ;
      "config_path" => dbf_ConfigPath(), ;
      "roots"       => dbf_Roots() }


/*
 * op_get_active_root - Worker op: return current root and config path.
 */
STATIC FUNCTION op_get_active_root( hArgs )
   HB_SYMBOL_UNUSED( hArgs )
   RETURN { ;
      "active_root" => dbf_ActiveRoot(), ;
      "config_path" => dbf_ConfigPath() }


/*
 * op_set_active_root - Worker op: switch root and reset all open sessions.
 */
STATIC FUNCTION op_set_active_root( hArgs )
   LOCAL cValue := hb_HGetDef( hArgs, "root", "" )
   close_all_sessions()
   dbf_SetActiveRoot( cValue )
   RETURN { ;
      "active_root" => dbf_ActiveRoot(), ;
      "config_path" => dbf_ConfigPath() }


/*
 * op_save_config - Worker op: persist in-memory config back to INI file.
 */
STATIC FUNCTION op_save_config( hArgs )
   LOCAL cPath
   HB_SYMBOL_UNUSED( hArgs )
   cPath := dbf_SaveConfig()
   RETURN { "saved" => .T., "config_path" => cPath }


/*
 * op_list_tables - Worker op: list DBF files under active root.
 */
STATIC FUNCTION op_list_tables( hArgs )
   LOCAL lRec := hb_HGetDef( hArgs, "recursive", .F. )
   LOCAL cRoot := dbf_ActiveRoot()
   LOCAL aFiles := hb_DirScan( cRoot, "*.dbf", iif( lRec, "D", "" ) )
   LOCAL aOut := {}
   LOCAL aEntry, cRel, cFull
   FOR EACH aEntry IN aFiles
      cRel := aEntry[ 1 ]
      cFull := hb_PathNormalize( cRoot + cRel )
      AAdd( aOut, { ;
         "name"          => hb_FNameName( cRel ), ;
         "relative_path" => cRel, ;
         "dbf_path"      => cFull } )
   NEXT
   RETURN aOut


/*
 * op_list_all_indexes - Worker op: list NTX files under active root.
 */
STATIC FUNCTION op_list_all_indexes( hArgs )
   LOCAL lRec := hb_HGetDef( hArgs, "recursive", .F. )
   LOCAL cRoot := dbf_ActiveRoot()
   LOCAL aFiles := hb_DirScan( cRoot, "*.ntx", iif( lRec, "D", "" ) )
   LOCAL aOut := {}
   LOCAL aEntry, cRel, cFull
   FOR EACH aEntry IN aFiles
      cRel := aEntry[ 1 ]
      cFull := hb_PathNormalize( cRoot + cRel )
      AAdd( aOut, { ;
         "name"          => hb_FNameName( cRel ), ;
         "relative_path" => cRel, ;
         "ntx_path"      => cFull } )
   NEXT
   RETURN aOut


/*
 * op_get_table_info - Worker op: return DBF structure plus discovered indexes.
 */
STATIC FUNCTION op_get_table_info( hArgs )
   LOCAL cPath := resolve_dbf( hb_HGetDef( hArgs, "table", "" ) )
   LOCAL cAlias := "TMPINFO"
   LOCAL aFields := {}
   LOCAL aStruct, i, aF, nOffset := 1, aIdx, aIxOut, n

   IF Select( cAlias ) != 0
      ( cAlias )->( dbCloseArea() )
   ENDIF
   dbUseArea( .T., "DBFNTX", cPath, cAlias, .T., .T. )
   aStruct := ( cAlias )->( DbStruct() )
   FOR i := 1 TO Len( aStruct )
      aF := aStruct[ i ]
      AAdd( aFields, { ;
         "name"     => aF[ 1 ], ;
         "type"     => aF[ 2 ], ;
         "length"   => aF[ 3 ], ;
         "decimals" => aF[ 4 ], ;
         "offset"   => nOffset } )
      nOffset += aF[ 3 ]
   NEXT

   aIdx := discover_indexes( cPath )
   aIxOut := {}
   n := 0
   FOR EACH i IN aIdx
      n++
      AAdd( aIxOut, { "order" => n, "name" => hb_FNameName( i ), "path" => i } )
   NEXT

   ( cAlias )->( dbCloseArea() )
   RETURN { ;
      "dbf_path"      => cPath, ;
      "relative_path" => rel_to_root( cPath ), ;
      "name"          => hb_FNameName( cPath ), ;
      "field_count"   => Len( aFields ), ;
      "fields"        => aFields, ;
      "indexes"       => aIxOut }


/*
 * op_list_fields - Worker op: convenience wrapper returning only field list.
 */
STATIC FUNCTION op_list_fields( hArgs )
   LOCAL hInfo := op_get_table_info( hArgs )
   RETURN hInfo[ "fields" ]


/*
 * op_list_indexes - Worker op: open table read-only and describe index keys.
 */
STATIC FUNCTION op_list_indexes( hArgs )
   LOCAL cPath := resolve_dbf( hb_HGetDef( hArgs, "table", "" ) )
   LOCAL aIdx := discover_indexes( cPath )
   LOCAL aOut := {}
   LOCAL cNtx, cAlias := "TMPIDX", n, cKey

   IF Empty( aIdx )
      RETURN aOut
   ENDIF

   IF Select( cAlias ) != 0
      ( cAlias )->( dbCloseArea() )
   ENDIF
   dbUseArea( .T., "DBFNTX", cPath, cAlias, .T., .T. )
   n := 0
   FOR EACH cNtx IN aIdx
      n++
      ( cAlias )->( OrdListAdd( cNtx ) )
      cKey := AllTrim( ( cAlias )->( OrdKey( n ) ) )
      AAdd( aOut, { ;
         "name"     => hb_FNameName( cNtx ), ;
         "path"     => cNtx, ;
         "order"    => n, ;
         "key_expr" => cKey } )
   NEXT
   ( cAlias )->( dbCloseArea() )
   RETURN aOut


/*
 * op_open_table - Worker op: open/make-active table and optional index set.
 */
STATIC FUNCTION op_open_table( hArgs )
   LOCAL cTable := hb_HGetDef( hArgs, "table", "" )
   LOCAL aIdx := hb_HGetDef( hArgs, "indexes", NIL )
   LOCAL cPath := resolve_dbf( cTable )
   LOCAL aNtxResolved, cIdx, hSession

   aNtxResolved := {}
   IF HB_ISARRAY( aIdx )
      FOR EACH cIdx IN aIdx
         IF dbf_IsAbsPath( cIdx )
            AAdd( aNtxResolved, hb_PathNormalize( cIdx ) )
         ELSE
            AAdd( aNtxResolved, hb_PathNormalize( dbf_ActiveRoot() + cIdx ) )
         ENDIF
      NEXT
   ENDIF

   IF hb_HHasKey( s_hSessions, cPath ) .AND. Empty( aNtxResolved )
      s_cActiveRef := cPath
      RETURN session_summary( s_hSessions[ cPath ] )
   ENDIF
   IF hb_HHasKey( s_hSessions, cPath )
      close_session( s_hSessions[ cPath ] )
      hb_HDel( s_hSessions, cPath )
   ENDIF

   hSession := open_session( cPath, aNtxResolved )
   s_hSessions[ cPath ] := hSession
   s_cActiveRef := cPath
   RETURN session_summary( hSession )


/*
 * op_get_active_table - Worker op: return active session summary.
 */
STATIC FUNCTION op_get_active_table( hArgs )
   HB_SYMBOL_UNUSED( hArgs )
   RETURN session_summary( active_session() )


/*
 * op_close_active_table - Worker op: close currently active session alias.
 */
STATIC FUNCTION op_close_active_table( hArgs )
   LOCAL hSession
   HB_SYMBOL_UNUSED( hArgs )
   hSession := active_session()
   close_session( hSession )
   hb_HDel( s_hSessions, s_cActiveRef )
   s_cActiveRef := NIL
   RETURN { "closed" => .T. }


/*
 * op_close_table - Worker op: close one specific open table session.
 */
STATIC FUNCTION op_close_table( hArgs )
   LOCAL cTable := hb_HGetDef( hArgs, "table", "" )
   LOCAL cPath := resolve_dbf( cTable )
   LOCAL hSession

   IF ! hb_HHasKey( s_hSessions, cPath )
      RETURN { "closed" => .F., "table" => cPath, "reason" => "not_open" }
   ENDIF
   hSession := s_hSessions[ cPath ]
   close_session( hSession )
   hb_HDel( s_hSessions, cPath )
   IF s_cActiveRef == cPath
      s_cActiveRef := NIL
   ENDIF
   RETURN { "closed" => .T., "table" => cPath }


/*
 * op_close_all_tables - Worker op: close every open table in current process.
 */
STATIC FUNCTION op_close_all_tables( hArgs )
   LOCAL nCount := Len( s_hSessions )
   HB_SYMBOL_UNUSED( hArgs )
   close_all_sessions()
   RETURN { "closed" => .T., "count" => nCount }


/*
 * op_set_order - Worker op: set active order by numeric slot or index name.
 */
STATIC FUNCTION op_set_order( hArgs )
   LOCAL hSession := session_for( hb_HGetDef( hArgs, "table", NIL ) )
   LOCAL xOrder := hb_HGetDef( hArgs, "order", 0 )
   LOCAL cAlias := hSession[ "alias" ]

   ( cAlias )->( OrdSetFocus( xOrder ) )
   IF hb_HGetDef( hArgs, "table", NIL ) != NIL
      s_cActiveRef := hSession[ "dbf_path" ]
   ENDIF
   RETURN { ;
      "dbf_path"         => hSession[ "dbf_path" ], ;
      "active_order"     => ( cAlias )->( OrdNumber( ( cAlias )->( OrdSetFocus() ) ) ), ;
      "active_index_key" => AllTrim( ( cAlias )->( OrdKey( ( cAlias )->( OrdNumber( ( cAlias )->( OrdSetFocus() ) ) ) ) ) ) }


/*
 * op_set_deleted - Worker op: toggle visibility of deleted records per session.
 */
STATIC FUNCTION op_set_deleted( hArgs )
   LOCAL hSession := session_for( hb_HGetDef( hArgs, "table", NIL ) )
   LOCAL lFlag := hb_HGetDef( hArgs, "flag", .F. )

   hSession[ "deleted_visible" ] := lFlag
   Set( _SET_DELETED, ! lFlag )
   IF hb_HGetDef( hArgs, "table", NIL ) != NIL
      s_cActiveRef := hSession[ "dbf_path" ]
   ENDIF
   RETURN { ;
      "dbf_path"        => hSession[ "dbf_path" ], ;
      "deleted_visible" => hSession[ "deleted_visible" ] }


/*
 * op_get_deleted - Worker op: report deleted-record visibility flag.
 */
STATIC FUNCTION op_get_deleted( hArgs )
   LOCAL hSession := session_for( hb_HGetDef( hArgs, "table", NIL ) )
   RETURN { ;
      "dbf_path"        => hSession[ "dbf_path" ], ;
      "deleted_visible" => hSession[ "deleted_visible" ] }


/*
 * op_current_record - Worker op: return current row without cursor movement.
 */
STATIC FUNCTION op_current_record( hArgs )
   LOCAL hSession := session_for( hb_HGetDef( hArgs, "table", NIL ) )
   LOCAL cAlias := hSession[ "alias" ]
   apply_session_state( hSession )
   RETURN { ;
      "record" => dbf_IsoValue( current_record( cAlias ) ), ;
      "state"  => session_summary( hSession ) }


/*
 * op_get_record - Worker op: position by physical recno and return row/state.
 */
STATIC FUNCTION op_get_record( hArgs )
   LOCAL hSession := session_for( hb_HGetDef( hArgs, "table", NIL ) )
   LOCAL nRecno := hb_HGetDef( hArgs, "recno", 0 )
   LOCAL cAlias := hSession[ "alias" ]
   LOCAL hRec

   apply_session_state( hSession )
   ( cAlias )->( dbGoto( nRecno ) )
   hRec := current_record( cAlias )
   RETURN { "record" => dbf_IsoValue( hRec ), "state" => session_summary( hSession ) }


/*
 * op_go_top - Worker op: move cursor to first row (order-aware) and return it.
 */
STATIC FUNCTION op_go_top( hArgs )
   LOCAL hSession := session_for( hb_HGetDef( hArgs, "table", NIL ) )
   LOCAL cAlias := hSession[ "alias" ]
   apply_session_state( hSession )
   ( cAlias )->( dbGoTop() )
   RETURN { "record" => dbf_IsoValue( current_record( cAlias ) ), "state" => session_summary( hSession ) }


/*
 * op_go_bottom - Worker op: move cursor to last row (order-aware) and return it.
 */
STATIC FUNCTION op_go_bottom( hArgs )
   LOCAL hSession := session_for( hb_HGetDef( hArgs, "table", NIL ) )
   LOCAL cAlias := hSession[ "alias" ]
   apply_session_state( hSession )
   ( cAlias )->( dbGoBottom() )
   RETURN { "record" => dbf_IsoValue( current_record( cAlias ) ), "state" => session_summary( hSession ) }


/*
 * op_skip - Worker op: move cursor by N rows and return resulting row/state.
 */
STATIC FUNCTION op_skip( hArgs )
   LOCAL hSession := session_for( hb_HGetDef( hArgs, "table", NIL ) )
   LOCAL nN := hb_HGetDef( hArgs, "n", 1 )
   LOCAL cAlias := hSession[ "alias" ]
   apply_session_state( hSession )
   ( cAlias )->( dbSkip( nN ) )
   RETURN { "record" => dbf_IsoValue( current_record( cAlias ) ), "state" => session_summary( hSession ) }


/*
 * op_seek_record - Worker op: DBSEEK current order and return found + row.
 */
STATIC FUNCTION op_seek_record( hArgs )
   LOCAL hSession := session_for( hb_HGetDef( hArgs, "table", NIL ) )
   LOCAL xValue := dbf_ParseDate( hb_HGetDef( hArgs, "value", NIL ) )
   LOCAL lSoft := hb_HGetDef( hArgs, "softseek", .F. )
   LOCAL cAlias := hSession[ "alias" ]
   LOCAL lFound

   apply_session_state( hSession )
   ( cAlias )->( dbSeek( xValue, lSoft ) )
   lFound := ( cAlias )->( Found() )
   RETURN { ;
      "record" => dbf_IsoValue( current_record( cAlias ) ), ;
      "found"  => lFound, ;
      "state"  => session_summary( hSession ) }


/*
 * op_records_since - Worker op: soft-seek and stream rows forward to EOF.
 */
STATIC FUNCTION op_records_since( hArgs )
   LOCAL hSession := session_for( hb_HGetDef( hArgs, "table", NIL ) )
   LOCAL xValue := dbf_ParseDate( hb_HGetDef( hArgs, "value", NIL ) )
   LOCAL cAlias := hSession[ "alias" ]
   LOCAL aRecs := {}
   LOCAL hRec

   apply_session_state( hSession )
   ( cAlias )->( dbSeek( xValue, .T. ) )
   DO WHILE ! ( cAlias )->( Eof() )
      hRec := current_record( cAlias )
      AAdd( aRecs, dbf_ProjectRecord( hRec, NIL ) )
      ( cAlias )->( dbSkip( 1 ) )
   ENDDO
   RETURN { "count" => Len( aRecs ), "records" => aRecs, "state" => session_summary( hSession ) }


/*
 * op_query_records - Worker op: scan/query rows with projection, filters, seek.
 */
STATIC FUNCTION op_query_records( hArgs )
   LOCAL hSession := session_for( hb_HGetDef( hArgs, "table", NIL ) )
   LOCAL nLimit := hb_HGetDef( hArgs, "limit", 50 )
   LOCAL nOffset := hb_HGetDef( hArgs, "offset", 0 )
   LOCAL xOrder := hb_HGetDef( hArgs, "order", NIL )
   LOCAL xIncludeDeleted := hb_HGetDef( hArgs, "include_deleted", NIL )
   LOCAL aFilters := hb_HGetDef( hArgs, "filters", NIL )
   LOCAL aFields := hb_HGetDef( hArgs, "fields", NIL )
   LOCAL cAlias := hSession[ "alias" ]
   LOCAL aRecs := {}, nSeen := 0, lSeekUsed := .F.
   LOCAL aEqFilters, aRemaining, hSeekFlt, nSeekOrder, xSeekValue, cSeekField
   LOCAL hRec, xFieldVal
   LOCAL cFilterErr := ""

   aFilters := dbf_NormalizeFilters( aFilters, @cFilterErr )
   IF ! Empty( cFilterErr )
      RETURN { "error" => "Invalid filters: " + cFilterErr + ;
         ". Use object filters {field,op,value} or string filters like EST_COD = 11" }
   ENDIF

   IF xIncludeDeleted != NIL
      hSession[ "deleted_visible" ] := xIncludeDeleted
   ENDIF
   apply_session_state( hSession )

   aEqFilters := {}
   IF HB_ISARRAY( aFilters )
      FOR EACH hSeekFlt IN aFilters
         IF Lower( hb_HGetDef( hSeekFlt, "op", "eq" ) ) == "eq"
            AAdd( aEqFilters, hSeekFlt )
         ENDIF
      NEXT
   ENDIF
   aRemaining := iif( HB_ISARRAY( aFilters ), AClone( aFilters ), {} )

   /* Seek optimisation: single eq filter on indexed field, no explicit order */
   IF xOrder == NIL .AND. Len( aEqFilters ) == 1
      hSeekFlt := aEqFilters[ 1 ]
      cSeekField := Upper( AllTrim( hb_HGetDef( hSeekFlt, "field", "" ) ) )
      nSeekOrder := find_index_order( hSession, cSeekField )
      IF nSeekOrder != NIL
         ( cAlias )->( OrdSetFocus( nSeekOrder ) )
         xSeekValue := dbf_ParseDate( hb_HGetDef( hSeekFlt, "value", NIL ) )
         ( cAlias )->( dbSeek( xSeekValue ) )
         IF ! ( cAlias )->( Found() )
            RETURN { ;
               "count"     => 0, ;
               "offset"    => nOffset, ;
               "limit"     => nLimit, ;
               "records"   => {}, ;
               "state"     => session_summary( hSession ), ;
               "seek_used" => .T. }
         ENDIF
         aRemaining := remove_filter( aRemaining, hSeekFlt )
         lSeekUsed := .T.
      ENDIF
   ENDIF

   IF xOrder != NIL
      ( cAlias )->( OrdSetFocus( xOrder ) )
   ENDIF

   IF lSeekUsed
      DO WHILE ! ( cAlias )->( Eof() )
         hRec := current_record( cAlias )
         xFieldVal := hb_HGetDef( hRec, hb_HGetDef( aEqFilters[ 1 ], "field", "" ), NIL )
         IF ! ( xFieldVal == dbf_ParseDate( hb_HGetDef( aEqFilters[ 1 ], "value", NIL ) ) )
            EXIT
         ENDIF
         IF dbf_MatchesFilters( hRec, aRemaining )
            IF nSeen >= nOffset
               AAdd( aRecs, dbf_ProjectRecord( hRec, aFields ) )
            ENDIF
            nSeen++
         ENDIF
         IF Len( aRecs ) >= nLimit
            EXIT
         ENDIF
         ( cAlias )->( dbSkip( 1 ) )
      ENDDO
   ELSE
      ( cAlias )->( dbGoTop() )
      DO WHILE ! ( cAlias )->( Eof() )
         hRec := current_record( cAlias )
         IF dbf_MatchesFilters( hRec, aFilters )
            IF nSeen >= nOffset
               AAdd( aRecs, dbf_ProjectRecord( hRec, aFields ) )
               IF Len( aRecs ) >= nLimit
                  EXIT
               ENDIF
            ENDIF
            nSeen++
         ENDIF
         ( cAlias )->( dbSkip( 1 ) )
      ENDDO
   ENDIF

   RETURN { ;
      "count"     => Len( aRecs ), ;
      "offset"    => nOffset, ;
      "limit"     => nLimit, ;
      "records"   => aRecs, ;
      "state"     => session_summary( hSession ), ;
      "seek_used" => lSeekUsed }


/*
 * find_index_order - Return index order number whose key_expr matches field.
 */
STATIC FUNCTION find_index_order( hSession, cField )
   LOCAL aMeta := hSession[ "index_meta" ]
   LOCAL hMeta
   FOR EACH hMeta IN aMeta
      IF Upper( hb_HGetDef( hMeta, "key_expr", "" ) ) == cField
         RETURN hMeta[ "order" ]
      ENDIF
   NEXT
   RETURN NIL


/*
 * remove_filter - Return a shallow-cloned array excluding one filter hash.
 */
STATIC FUNCTION remove_filter( aFilters, hSkip )
   LOCAL aOut := {}, h
   FOR EACH h IN aFilters
      IF !( h == hSkip )
         AAdd( aOut, h )
      ENDIF
   NEXT
   RETURN aOut


/*
 * dbf_NormalizeFilters - Canonicalize every accepted filters input shape.
 *
 * Why this exists:
 *   MCP clients and agent frameworks do not always emit the same argument
 *   shape for filters. Some send structured objects (`field/op/value`),
 *   others send SQL-like single-line expressions. This helper converts all
 *   supported forms to one internal representation so op_query_records()
 *   can keep a single matching path and avoid runtime type errors.
 *
 * Accepted inputs:
 *   NIL                -> NIL (no filtering)
 *   string             -> { { field, op, value } }
 *   hash               -> { { field, op, value } }
 *   array (mixed)      -> { { ... }, { ... }, ... }
 *
 * Returns:
 *   Array of normalized filter hashes, or NIL when parsing/validation fails.
 *   cErr receives a human-readable explanation when the return is NIL.
 */
STATIC FUNCTION dbf_NormalizeFilters( xFilters, cErr )
   LOCAL aOut := {}
   LOCAL xItem, hParsed

   cErr := ""
   IF xFilters == NIL
      RETURN NIL
   ENDIF

   IF HB_ISSTRING( xFilters )
      hParsed := dbf_ParseFilterExpr( xFilters, @cErr )
      IF ! Empty( cErr )
         RETURN NIL
      ENDIF
      AAdd( aOut, hParsed )
      RETURN aOut
   ENDIF

   IF HB_ISHASH( xFilters )
      hParsed := dbf_NormalizeFilterHash( xFilters, @cErr )
      IF ! Empty( cErr )
         RETURN NIL
      ENDIF
      AAdd( aOut, hParsed )
      RETURN aOut
   ENDIF

   IF ! HB_ISARRAY( xFilters )
      cErr := "filters must be a string, object, or array"
      RETURN NIL
   ENDIF

   FOR EACH xItem IN xFilters
      IF HB_ISSTRING( xItem )
         hParsed := dbf_ParseFilterExpr( xItem, @cErr )
      ELSEIF HB_ISHASH( xItem )
         hParsed := dbf_NormalizeFilterHash( xItem, @cErr )
      ELSE
         cErr := "array items must be string expressions or filter objects"
      ENDIF
      IF ! Empty( cErr )
         RETURN NIL
      ENDIF
      AAdd( aOut, hParsed )
   NEXT

   RETURN aOut


/*
 * dbf_NormalizeFilterHash - Validate object-form filters from clients.
 *
 * Input contract:
 *   { "field" => <non-empty string>, "op" => <known operator>, "value" => <any> }
 *
 * Design note:
 *   We validate operators here (instead of deep in dbf_Match) so bad client
 *   payloads fail early with a deterministic, user-facing message.
 */
STATIC FUNCTION dbf_NormalizeFilterHash( hFilter, cErr )
   LOCAL cField := AllTrim( hb_CStr( hb_HGetDef( hFilter, "field", "" ) ) )
   LOCAL cOp := Lower( AllTrim( hb_CStr( hb_HGetDef( hFilter, "op", "eq" ) ) ) )
   LOCAL aAllowed

   cErr := ""
   IF Empty( cField )
      cErr := "filter object is missing non-empty field"
      RETURN NIL
   ENDIF

   aAllowed := { "eq", "ne", "lt", "lte", "gt", "gte", "contains", "startswith", "endswith", "in", "between" }
   IF AScan( aAllowed, cOp ) == 0
      cErr := "unsupported object operator '" + cOp + "'"
      RETURN NIL
   ENDIF

   RETURN { ;
      "field" => cField, ;
      "op"    => cOp, ;
      "value" => hb_HGetDef( hFilter, "value", NIL ) }


/*
 * dbf_ParseFilterExpr - Parse a simple textual filter into object form.
 *
 * Supported grammar (v1):
 *   FIELD OP VALUE
 * where OP is one of: =, !=, <, <=, >, >=
 *
 * Not supported in v1:
 *   AND / OR / parentheses / function calls.
 *
 * Why this exists:
 *   Some MCP clients prefer compact text arguments. Converting the text to
 *   canonical `{ field, op, value }` keeps the rest of the pipeline identical
 *   to object-based filters and preserves deterministic behavior.
 */
STATIC FUNCTION dbf_ParseFilterExpr( cExpr, cErr )
   LOCAL cText := AllTrim( cExpr )
   LOCAL aOps := { "<=", ">=", "!=", "=", "<", ">" }
   LOCAL aMap := { "lte", "gte", "ne", "eq", "lt", "gt" }
   LOCAL i, nPos := 0, cOpToken := "", cField, cValueText, xValue

   cErr := ""
   IF Empty( cText )
      cErr := "empty string filter"
      RETURN NIL
   ENDIF

   FOR i := 1 TO Len( aOps )
      nPos := At( aOps[ i ], cText )
      IF nPos > 0
         cOpToken := aOps[ i ]
         EXIT
      ENDIF
   NEXT
   IF Empty( cOpToken )
      cErr := "string filter must use one of: =, !=, <, <=, >, >="
      RETURN NIL
   ENDIF

   cField := AllTrim( Left( cText, nPos - 1 ) )
   cValueText := AllTrim( SubStr( cText, nPos + Len( cOpToken ) ) )
   IF Empty( cField ) .OR. Empty( cValueText )
      cErr := "string filter must follow FIELD OP VALUE"
      RETURN NIL
   ENDIF

   xValue := dbf_ParseFilterValue( cValueText )
   RETURN { ;
      "field" => cField, ;
      "op"    => aMap[ i ], ;
      "value" => xValue }


/*
 * dbf_ParseFilterValue - Coerce textual VALUE tokens into Harbour scalars.
 *
 * Coercion rules:
 *   - quoted text ("..." or '...') -> string without quotes
 *   - true/.T. and false/.F.       -> logical
 *   - numeric literal              -> numeric
 *   - otherwise                    -> raw string
 *
 * Date literals remain strings here; dbf_ParseDate() is applied later by the
 * matching layer so both object-form and string-form filters share the same
 * date semantics.
 */
STATIC FUNCTION dbf_ParseFilterValue( cText )
   LOCAL cVal := AllTrim( cText )
   LOCAL cFirst := "", cLast := ""

   IF Empty( cVal )
      RETURN ""
   ENDIF

   cFirst := Left( cVal, 1 )
   cLast  := Right( cVal, 1 )
   IF ( cFirst == "'" .AND. cLast == "'" ) .OR. ( cFirst == '"' .AND. cLast == '"' )
      RETURN SubStr( cVal, 2, Len( cVal ) - 2 )
   ENDIF

   IF Lower( cVal ) == ".t." .OR. Lower( cVal ) == "true"
      RETURN .T.
   ENDIF
   IF Lower( cVal ) == ".f." .OR. Lower( cVal ) == "false"
      RETURN .F.
   ENDIF

   IF dbf_IsNumericLiteral( cVal )
      RETURN Val( cVal )
   ENDIF

   RETURN cVal


/*
 * dbf_IsNumericLiteral - Lightweight numeric token validator.
 *
 * Accepts optional leading sign and at most one decimal point.
 * Rejects any other character to avoid accidental coercion of IDs or mixed
 * tokens that should stay as strings.
 */
STATIC FUNCTION dbf_IsNumericLiteral( cText )
   LOCAL cVal := AllTrim( cText )
   LOCAL nDots := 0, nStart := 1, i, c

   IF Empty( cVal )
      RETURN .F.
   ENDIF

   c := Left( cVal, 1 )
   IF c == "+" .OR. c == "-"
      IF Len( cVal ) == 1
         RETURN .F.
      ENDIF
      nStart := 2
   ENDIF

   FOR i := nStart TO Len( cVal )
      c := SubStr( cVal, i, 1 )
      IF c == "."
         nDots++
         IF nDots > 1
            RETURN .F.
         ENDIF
      ELSEIF !( c >= "0" .AND. c <= "9" )
         RETURN .F.
      ENDIF
   NEXT

   RETURN .T.


/*
 * apply_session_state - Reapply process-wide SET DELETED from session flag.
 */
STATIC PROCEDURE apply_session_state( hSession )
   /* Re-apply per-session SET DELETED before each op (it is process-wide
      in Harbour, so a previous tool call on another session may have
      flipped it). */
   Set( _SET_DELETED, ! hSession[ "deleted_visible" ] )
   RETURN

