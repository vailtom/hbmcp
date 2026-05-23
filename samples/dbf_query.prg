/*
 * dbf_query.prg - DBF-backed MCP server sample
 *
 * Role in the samples set
 * -----------------------
 * Third stop. Shows how to bridge legacy Clipper/Harbour DBF data into
 * MCP tools. The DBF is generated and seeded on first run so the sample
 * is self-contained. Tools open the file, scan, and close on every call -
 * the simplest correct pattern for a stdio server that may be invoked
 * concurrently by clients sharing the same data directory.
 *
 * MCP / JSON-RPC concepts touched
 * -------------------------------
 * - Returning structured data: arrays of hashes are JSON-encoded into a
 *   single text content item (MCP 2024-11-05 - Tools, content[])
 * - Multiple tools on a shared data source, each with its own schema
 * - Server identity via MCPSetServerInfo() so the client shows
 *   "dbf-query-mcp" instead of the default "hbmcp"
 *
 * Sample DBF
 * ----------
 *   samples/data/customers.dbf
 *     id        N  8        primary key
 *     name      C 40
 *     city      C 30
 *     balance   N 12 2
 *     last_buy  D
 *
 * The DBF is created at startup if missing. If the file exists but is
 * missing expected fields, the server refuses to start and logs an error.
 *
 * Reading order
 * -------------
 * Best read after: fs_tools.prg
 * Followed by:     mini_erp.prg
 *
 * Build
 * -----
 *   hbmk2 dbf_query.hbp
 */

#include "hbmcp.ch"

#define DBF_CUSTOMERS    "data/customers.dbf"


PROCEDURE Main()

   MCPSetServerInfo( "dbf-query-mcp", "1.0.0" )

   IF ! customers_prepare()
      MCPLog( MCP_LOG_ERROR, "customers.dbf preparation failed - aborting" )
      RETURN
   ENDIF

   /* -----------------------------------------------------------------
    * Tool: customers_count
    *
    * Simplest aggregate tool: no arguments, single-number result wrapped
    * in a hash so the client gets a labeled field instead of a bare int.
    * ----------------------------------------------------------------- */
   MCPRegisterTool( ;
      "customers_count", ;
      "Returns the number of customer records.", ;
      { "type" => "object", "properties" => { => }, "required" => {} }, ;
      {| hArgs | tool_count( hArgs ) } )

   /* -----------------------------------------------------------------
    * Tool: customer_find
    *
    * Lookup by primary key. Returns NIL when not found - the library
    * encodes NIL as JSON null so the client can distinguish "not found"
    * from a real record. Shows the canonical full-scan loop:
    * DbGoTop -> WHILE !Eof -> DbSkip.
    * ----------------------------------------------------------------- */
   MCPRegisterTool( ;
      "customer_find", ;
      "Finds one customer by id. Returns NIL if not found.", ;
      { ;
         "type"       => "object", ;
         "properties" => { "id" => { "type" => "integer" } }, ;
         "required"   => { "id" } }, ;
      {| hArgs | tool_find( hArgs ) } )

   /* -----------------------------------------------------------------
    * Tool: customers_by_city
    *
    * Filtered scan returning an array of hashes (one per row). The
    * comparison is done case-insensitively in the tool because the DBF
    * is not indexed - simpler and good enough for sample-sized data.
    * ----------------------------------------------------------------- */
   MCPRegisterTool( ;
      "customers_by_city", ;
      "Returns the list of customers in a given city (case-insensitive).", ;
      { ;
         "type"       => "object", ;
         "properties" => { "city" => { "type" => "string" } }, ;
         "required"   => { "city" } }, ;
      {| hArgs | tool_by_city( hArgs ) } )

   MCPRun()
   RETURN


/*
 * customers_prepare - Create the sample DBF if missing, validate if present.
 * Returns .T. on success.
 */
STATIC FUNCTION customers_prepare()

   IF ! hb_DirExists( "data" )
      hb_DirCreate( "data" )
   ENDIF

   IF hb_FileExists( DBF_CUSTOMERS )
      RETURN customers_validate()
   ENDIF

   MCPLog( MCP_LOG_INFO, "creating " + DBF_CUSTOMERS )
   DbCreate( DBF_CUSTOMERS, { ;
      { "ID",       "N",  8, 0 }, ;
      { "NAME",     "C", 40, 0 }, ;
      { "CITY",     "C", 30, 0 }, ;
      { "BALANCE", "N", 12, 2 }, ;
      { "LAST_BUY", "D",  8, 0 } } )

   DbUseArea( .T., , DBF_CUSTOMERS, "CUST", .T. )
   customers_seed()
   CUST->( DbCloseArea() )
   RETURN .T.


/*
 * customers_validate - Check that an existing DBF still has the fields
 * this sample needs. Fails loud via MCPLog instead of silently
 * overwriting a file the user may have customized.
 */
STATIC FUNCTION customers_validate()
   LOCAL aExpected := { "ID", "NAME", "CITY", "BALANCE", "LAST_BUY" }
   LOCAL i, lOk := .T.

   DbUseArea( .T., , DBF_CUSTOMERS, "CUST", .T. )
   FOR i := 1 TO Len( aExpected )
      IF CUST->( FieldPos( aExpected[ i ] ) ) == 0
         MCPLog( MCP_LOG_ERROR, "missing field: " + aExpected[ i ] )
         lOk := .F.
      ENDIF
   NEXT
   CUST->( DbCloseArea() )
   RETURN lOk


/*
 * customers_seed - Populate the freshly-created DBF with deterministic
 * data so every reader gets identical results from the sample tools.
 * The CUST workarea must already be open.
 */
STATIC PROCEDURE customers_seed()
   LOCAL aSeed := { ;
      {  1, "Acme Industries",     "Sao Paulo",      15000.00, hb_SToD( "20250410" ) }, ;
      {  2, "Beta Solutions",      "Rio de Janeiro", 32500.50, hb_SToD( "20251015" ) }, ;
      {  3, "Gamma Trading",       "Sao Paulo",       2100.00, hb_SToD( "20260101" ) }, ;
      {  4, "Delta Logistics",     "Belo Horizonte",     0.00, hb_SToD( "20240820" ) }, ;
      {  5, "Epsilon Consulting",  "Curitiba",        8750.00, hb_SToD( "20260305" ) }, ;
      {  6, "Zeta Manufacturing",  "Sao Paulo",      45000.00, hb_SToD( "20260420" ) } }
   LOCAL aRow
   FOR EACH aRow IN aSeed
      DbAppend()
      CUST->ID       := aRow[ 1 ]
      CUST->NAME     := aRow[ 2 ]
      CUST->CITY     := aRow[ 3 ]
      CUST->BALANCE  := aRow[ 4 ]
      CUST->LAST_BUY := aRow[ 5 ]
   NEXT
   MCPLog( MCP_LOG_INFO, "seeded " + hb_NToS( Len( aSeed ) ) + " customers" )
   RETURN


/*
 * record_to_hash - Snapshot the current record into a Harbour hash.
 * Used by tools that return one or many records. Keeps tool callbacks small.
 */
STATIC FUNCTION record_to_hash()
   RETURN { ;
      "id"       => CUST->ID, ;
      "name"     => AllTrim( CUST->NAME ), ;
      "city"     => AllTrim( CUST->CITY ), ;
      "balance"  => CUST->BALANCE, ;
      "last_buy" => DToC( CUST->LAST_BUY ) }


/*
 * tool_count - customers_count callback. Open shared, read RecCount,
 * close. Returns { "count" => N }.
 */
STATIC FUNCTION tool_count( hArgs )
   LOCAL nCount
   HB_SYMBOL_UNUSED( hArgs )
   DbUseArea( .T., , DBF_CUSTOMERS, "CUST", .T. )
   nCount := CUST->( RecCount() )
   CUST->( DbCloseArea() )
   RETURN { "count" => nCount }


/*
 * tool_find - customer_find callback. Linear scan because the DBF is not
 * indexed in this sample. Returns the record as a hash or NIL when
 * absent (-> JSON null on the wire).
 */
STATIC FUNCTION tool_find( hArgs )
   LOCAL nId := hb_HGetDef( hArgs, "id", 0 )
   LOCAL hRet := NIL

   DbUseArea( .T., , DBF_CUSTOMERS, "CUST", .T. )
   CUST->( DbGoTop() )
   DO WHILE ! CUST->( Eof() )
      IF CUST->ID == nId
         hRet := record_to_hash()
         EXIT
      ENDIF
      CUST->( DbSkip() )
   ENDDO
   CUST->( DbCloseArea() )
   RETURN hRet


/*
 * tool_by_city - customers_by_city callback. Case-insensitive filter.
 * Returns an array of record hashes (possibly empty).
 */
STATIC FUNCTION tool_by_city( hArgs )
   LOCAL cCity := Upper( AllTrim( hb_HGetDef( hArgs, "city", "" ) ) )
   LOCAL aOut := {}

   DbUseArea( .T., , DBF_CUSTOMERS, "CUST", .T. )
   CUST->( DbGoTop() )
   DO WHILE ! CUST->( Eof() )
      IF Upper( AllTrim( CUST->CITY ) ) == cCity
         AAdd( aOut, record_to_hash() )
      ENDIF
      CUST->( DbSkip() )
   ENDDO
   CUST->( DbCloseArea() )
   RETURN aOut
