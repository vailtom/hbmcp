/*
 * mini_erp.prg - End-to-end ERP-flavored MCP sample
 *
 * Role in the samples set
 * -----------------------
 * Final stop. Steps up from dbf_query: two related DBFs joined by a
 * foreign key, derived/aggregated results, date math, and a top-N
 * pattern. The tools were chosen so an LLM-driven workflow can chain
 * them naturally: list invoices -> compute balance -> rank debtors.
 *
 * MCP / JSON-RPC concepts touched
 * -------------------------------
 * - Composable tools sharing a single backing data set
 * - Server identity via MCPSetServerInfo("mini-erp-mcp", ...) so clients
 *   present a domain-meaningful name
 * - Returning NIL inside a result hash to express "no data" without
 *   conflating it with zero (see days_since_last_invoice)
 * - Aggregation in pure Harbour: hash-keyed running totals, manual
 *   selection sort for small N
 *
 * Sample DBFs
 * -----------
 *   samples/data/customers.dbf  (id N8, name C40, city C30, balance N12.2, last_buy D)
 *   samples/data/invoices.dbf   (id N8, cust_id N8, issue_date D, amount N12.2, paid L)
 *
 * Both files are created on first run if missing. If a file exists but
 * lacks expected fields, startup fails loud with an MCPLog error.
 *
 * Reading order
 * -------------
 * Best read after: dbf_query.prg
 *
 * Build
 * -----
 *   hbmk2 mini_erp.hbp
 */

#include "hbmcp.ch"

#define DBF_CUSTOMERS    "data/customers.dbf"
#define DBF_INVOICES     "data/invoices.dbf"


PROCEDURE Main()

   MCPSetServerInfo( "mini-erp-mcp", "1.0.0" )

   IF ! customers_prepare() .OR. ! invoices_prepare()
      MCPLog( MCP_LOG_ERROR, "DBF preparation failed - aborting" )
      RETURN
   ENDIF

   /* -----------------------------------------------------------------
    * Tool: invoice_list
    *
    * Foreign-key scan: walk invoices, keep rows matching cust_id. The
    * result is an array of hashes - the library JSON-encodes it as one
    * text content item.
    * ----------------------------------------------------------------- */
   MCPRegisterTool( ;
      "invoice_list", ;
      "Lists invoices for a customer.", ;
      { ;
         "type"       => "object", ;
         "properties" => { "cust_id" => { "type" => "integer" } }, ;
         "required"   => { "cust_id" } }, ;
      {| hArgs | tool_invoice_list( hArgs ) } )

   /* -----------------------------------------------------------------
    * Tool: customer_balance
    *
    * Derived value: sum of UNPAID invoice amounts for one customer.
    * Shows how a tool computes data the DBF does not store directly.
    * ----------------------------------------------------------------- */
   MCPRegisterTool( ;
      "customer_balance", ;
      "Sums the amount of all UNPAID invoices for a customer.", ;
      { ;
         "type"       => "object", ;
         "properties" => { "cust_id" => { "type" => "integer" } }, ;
         "required"   => { "cust_id" } }, ;
      {| hArgs | tool_balance( hArgs ) } )

   /* -----------------------------------------------------------------
    * Tool: days_since_last_invoice
    *
    * Date math typical of ERP work. Returns NIL inside the hash when the
    * customer has no invoices, so the client can tell "no data" from a
    * legitimate zero.
    * ----------------------------------------------------------------- */
   MCPRegisterTool( ;
      "days_since_last_invoice", ;
      "Days elapsed since the most recent invoice for a customer.", ;
      { ;
         "type"       => "object", ;
         "properties" => { "cust_id" => { "type" => "integer" } }, ;
         "required"   => { "cust_id" } }, ;
      {| hArgs | tool_days_since( hArgs ) } )

   /* -----------------------------------------------------------------
    * Tool: top_debtors
    *
    * Aggregate + sort + limit. Demonstrates the optional-argument
    * pattern (limit defaults to 5 inside the callback) and a small
    * hand-rolled top-N selection - good enough for sample-sized data.
    * ----------------------------------------------------------------- */
   MCPRegisterTool( ;
      "top_debtors", ;
      "Top-N customers by unpaid balance (default 5).", ;
      { ;
         "type"       => "object", ;
         "properties" => { "limit" => { "type" => "integer" } }, ;
         "required"   => {} }, ;
      {| hArgs | tool_top_debtors( hArgs ) } )

   MCPRun()
   RETURN


/* ============================================================
 * DBF preparation
 * ============================================================ */

STATIC FUNCTION customers_prepare()
   LOCAL aExpected := { "ID", "NAME", "CITY", "BALANCE", "LAST_BUY" }

   IF ! hb_DirExists( "data" )
      hb_DirCreate( "data" )
   ENDIF

   IF hb_FileExists( DBF_CUSTOMERS )
      RETURN dbf_validate( DBF_CUSTOMERS, "CUST", aExpected )
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
   RETURN


STATIC FUNCTION invoices_prepare()
   LOCAL aExpected := { "ID", "CUST_ID", "ISSUE_DATE", "AMOUNT", "PAID" }

   IF hb_FileExists( DBF_INVOICES )
      RETURN dbf_validate( DBF_INVOICES, "INV", aExpected )
   ENDIF

   MCPLog( MCP_LOG_INFO, "creating " + DBF_INVOICES )
   DbCreate( DBF_INVOICES, { ;
      { "ID",         "N",  8, 0 }, ;
      { "CUST_ID",    "N",  8, 0 }, ;
      { "ISSUE_DATE", "D",  8, 0 }, ;
      { "AMOUNT",     "N", 12, 2 }, ;
      { "PAID",       "L",  1, 0 } } )

   DbUseArea( .T., , DBF_INVOICES, "INV", .T. )
   invoices_seed()
   INV->( DbCloseArea() )
   RETURN .T.


STATIC PROCEDURE invoices_seed()
   LOCAL aSeed := { ;
      {  1, 1, hb_SToD( "20260301" ),  5000.00, .T. }, ;
      {  2, 1, hb_SToD( "20260401" ),  3000.00, .F. }, ;
      {  3, 2, hb_SToD( "20260215" ), 12500.00, .F. }, ;
      {  4, 2, hb_SToD( "20260410" ),  8000.00, .F. }, ;
      {  5, 3, hb_SToD( "20260105" ),  2100.00, .T. }, ;
      {  6, 5, hb_SToD( "20260225" ),  4500.00, .F. }, ;
      {  7, 5, hb_SToD( "20260315" ),  4250.00, .F. }, ;
      {  8, 6, hb_SToD( "20260420" ), 22500.00, .F. }, ;
      {  9, 6, hb_SToD( "20260205" ), 18000.00, .F. } }
   LOCAL aRow
   FOR EACH aRow IN aSeed
      DbAppend()
      INV->ID         := aRow[ 1 ]
      INV->CUST_ID    := aRow[ 2 ]
      INV->ISSUE_DATE := aRow[ 3 ]
      INV->AMOUNT     := aRow[ 4 ]
      INV->PAID       := aRow[ 5 ]
   NEXT
   RETURN


/*
 * dbf_validate - Generic schema sanity check used by both prepare()
 * functions. Opens cFile under cAlias, asserts every field in aExpected
 * is present, closes and returns .T./.F. Missing fields are logged to
 * stderr via MCPLog so the operator can see why startup aborted.
 */
STATIC FUNCTION dbf_validate( cFile, cAlias, aExpected )
   LOCAL i, lOk := .T.
   DbUseArea( .T., , cFile, cAlias, .T. )
   FOR i := 1 TO Len( aExpected )
      IF ( cAlias )->( FieldPos( aExpected[ i ] ) ) == 0
         MCPLog( MCP_LOG_ERROR, cFile + " missing field: " + aExpected[ i ] )
         lOk := .F.
      ENDIF
   NEXT
   ( cAlias )->( DbCloseArea() )
   RETURN lOk


/* ============================================================
 * Tools
 * ============================================================ */

/*
 * tool_invoice_list - invoice_list callback. Linear scan of INV filtered
 * by cust_id. Returns array of invoice hashes (possibly empty).
 */
STATIC FUNCTION tool_invoice_list( hArgs )
   LOCAL nCustId := hb_HGetDef( hArgs, "cust_id", 0 )
   LOCAL aOut := {}

   DbUseArea( .T., , DBF_INVOICES, "INV", .T. )
   INV->( DbGoTop() )
   DO WHILE ! INV->( Eof() )
      IF INV->CUST_ID == nCustId
         AAdd( aOut, { ;
            "id"         => INV->ID, ;
            "issue_date" => DToC( INV->ISSUE_DATE ), ;
            "amount"     => INV->AMOUNT, ;
            "paid"       => INV->PAID } )
      ENDIF
      INV->( DbSkip() )
   ENDDO
   INV->( DbCloseArea() )
   RETURN aOut


/*
 * tool_balance - customer_balance callback. Sums INV.AMOUNT for rows
 * where CUST_ID matches and PAID is false. Returns
 * { "cust_id" => N, "unpaid_balance" => total }.
 */
STATIC FUNCTION tool_balance( hArgs )
   LOCAL nCustId := hb_HGetDef( hArgs, "cust_id", 0 )
   LOCAL nTotal := 0

   DbUseArea( .T., , DBF_INVOICES, "INV", .T. )
   INV->( DbGoTop() )
   DO WHILE ! INV->( Eof() )
      IF INV->CUST_ID == nCustId .AND. ! INV->PAID
         nTotal += INV->AMOUNT
      ENDIF
      INV->( DbSkip() )
   ENDDO
   INV->( DbCloseArea() )
   RETURN { "cust_id" => nCustId, "unpaid_balance" => nTotal }


/*
 * tool_days_since - days_since_last_invoice callback. Finds the most
 * recent ISSUE_DATE for the given customer, then returns Date() - that.
 * If no invoice exists, returns "days" => NIL plus a "note" field so the
 * client distinguishes "no data" from a zero-day gap.
 */
STATIC FUNCTION tool_days_since( hArgs )
   LOCAL nCustId := hb_HGetDef( hArgs, "cust_id", 0 )
   LOCAL dLatest := NIL

   DbUseArea( .T., , DBF_INVOICES, "INV", .T. )
   INV->( DbGoTop() )
   DO WHILE ! INV->( Eof() )
      IF INV->CUST_ID == nCustId
         IF dLatest == NIL .OR. INV->ISSUE_DATE > dLatest
            dLatest := INV->ISSUE_DATE
         ENDIF
      ENDIF
      INV->( DbSkip() )
   ENDDO
   INV->( DbCloseArea() )

   IF dLatest == NIL
      RETURN { "cust_id" => nCustId, "days" => NIL, "note" => "no invoices" }
   ENDIF
   RETURN { "cust_id" => nCustId, "latest" => DToC( dLatest ), "days" => Date() - dLatest }


/*
 * tool_top_debtors - top_debtors callback. Three phases:
 *   1) aggregate unpaid AMOUNT per CUST_ID into a hash
 *   2) flatten into an array of { cust_id, name, unpaid } hashes
 *   3) selection-sort by unpaid desc, truncate to nLimit
 * Selection sort is fine because nLimit is small; switch to ASort if
 * you adapt this to large datasets.
 */
STATIC FUNCTION tool_top_debtors( hArgs )
   LOCAL nLimit := hb_HGetDef( hArgs, "limit", 5 )
   LOCAL hByCust := { => }
   LOCAL nCustId, aOut, i, hPick, nBest, nIdx

   IF ! HB_ISNUMERIC( nLimit ) .OR. nLimit <= 0
      nLimit := 5
   ENDIF

   /* Aggregate unpaid amount per customer. */
   DbUseArea( .T., , DBF_INVOICES, "INV", .T. )
   INV->( DbGoTop() )
   DO WHILE ! INV->( Eof() )
      IF ! INV->PAID
         nCustId := INV->CUST_ID
         hByCust[ nCustId ] := hb_HGetDef( hByCust, nCustId, 0 ) + INV->AMOUNT
      ENDIF
      INV->( DbSkip() )
   ENDDO
   INV->( DbCloseArea() )

   /* Build sortable array of {cust_id, unpaid}. */
   aOut := {}
   FOR EACH nCustId IN hb_HKeys( hByCust )
      AAdd( aOut, { ;
         "cust_id" => nCustId, ;
         "name"    => cust_name( nCustId ), ;
         "unpaid"  => hByCust[ nCustId ] } )
   NEXT

   /* Top-N selection sort by "unpaid" desc. Cheap because N is small. */
   FOR i := 1 TO Min( nLimit, Len( aOut ) )
      nBest := aOut[ i ][ "unpaid" ]
      nIdx := i
      FOR EACH hPick IN aOut DESCEND
         IF hPick:__enumIndex() >= i .AND. hPick[ "unpaid" ] > nBest
            nBest := hPick[ "unpaid" ]
            nIdx := hPick:__enumIndex()
         ENDIF
      NEXT
      IF nIdx != i
         hPick := aOut[ i ] ; aOut[ i ] := aOut[ nIdx ] ; aOut[ nIdx ] := hPick
      ENDIF
   NEXT

   /* Truncate to nLimit. */
   DO WHILE Len( aOut ) > nLimit
      ASize( aOut, Len( aOut ) - 1 )
   ENDDO
   RETURN aOut


/*
 * cust_name - Resolve a customer id to its NAME, trimmed. Returns
 * "<unknown>" when the id is not in CUSTOMERS so top_debtors never
 * leaks a bare numeric id in its output.
 */
STATIC FUNCTION cust_name( nId )
   LOCAL cName := "<unknown>"
   DbUseArea( .T., , DBF_CUSTOMERS, "CUST", .T. )
   CUST->( DbGoTop() )
   DO WHILE ! CUST->( Eof() )
      IF CUST->ID == nId
         cName := AllTrim( CUST->NAME )
         EXIT
      ENDIF
      CUST->( DbSkip() )
   ENDDO
   CUST->( DbCloseArea() )
   RETURN cName
