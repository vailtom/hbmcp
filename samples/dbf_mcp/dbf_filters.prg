/*
 * dbf_filters.prg - Filter operators, date parsing, record projection.
 *
 * Pure helpers. No state, no threading. Mirrors _match, _parse_date,
 * _project_record and _iso from the Python dbf-mcp-server.
 */

#include "hbmcp.ch"


/*
 * dbf_ParseDate - Try to read a YYYY-MM-DD or YYYYMMDD string as a Date.
 * Returns the parsed Date or the original value unchanged when the input
 * is not a string matching either format.
 */
FUNCTION dbf_ParseDate( xValue )
   LOCAL cText, dRet

   IF ! HB_ISSTRING( xValue )
      RETURN xValue
   ENDIF
   cText := AllTrim( xValue )
   IF Len( cText ) == 10 .AND. SubStr( cText, 5, 1 ) == "-" .AND. SubStr( cText, 8, 1 ) == "-"
      dRet := hb_SToD( SubStr( cText, 1, 4 ) + SubStr( cText, 6, 2 ) + SubStr( cText, 9, 2 ) )
      IF ! Empty( dRet )
         RETURN dRet
      ENDIF
   ENDIF
   IF Len( cText ) == 8 .AND. IsDigit( SubStr( cText, 1, 1 ) )
      dRet := hb_SToD( cText )
      IF ! Empty( dRet )
         RETURN dRet
      ENDIF
   ENDIF
   RETURN xValue


/*
 * dbf_IsoValue - Convert dates/datetimes/containers to JSON-friendly form.
 * Dates -> "YYYY-MM-DD" string. Hashes and arrays are walked recursively.
 */
FUNCTION dbf_IsoValue( xValue )
   LOCAL hOut, xKey, aOut, x

   IF HB_ISTIMESTAMP( xValue )
      RETURN hb_TSToStr( xValue, .T. )
   ENDIF
   IF HB_ISDATE( xValue )
      IF Empty( xValue )
         RETURN ""
      ENDIF
      RETURN SubStr( DToS( xValue ), 1, 4 ) + "-" + ;
             SubStr( DToS( xValue ), 5, 2 ) + "-" + ;
             SubStr( DToS( xValue ), 7, 2 )
   ENDIF
   IF HB_ISHASH( xValue )
      hOut := { => }
      FOR EACH xKey IN hb_HKeys( xValue )
         hOut[ xKey ] := dbf_IsoValue( xValue[ xKey ] )
      NEXT
      RETURN hOut
   ENDIF
   IF HB_ISARRAY( xValue )
      aOut := {}
      FOR EACH x IN xValue
         AAdd( aOut, dbf_IsoValue( x ) )
      NEXT
      RETURN aOut
   ENDIF
   IF HB_ISSTRING( xValue )
      RETURN RTrim( xValue )
   ENDIF
   RETURN xValue


/*
 * dbf_ProjectRecord - Take a record hash and optional field whitelist.
 * Without a whitelist: ISO-encode every field. With a whitelist: keep the
 * internal pseudo-fields (_recno, _deleted) plus the listed names.
 */
FUNCTION dbf_ProjectRecord( hRecord, aFields )
   LOCAL hOut, cKey, cField

   IF aFields == NIL .OR. Empty( aFields )
      RETURN dbf_IsoValue( hRecord )
   ENDIF

   hOut := { => }
   FOR EACH cKey IN hb_HKeys( hRecord )
      IF cKey == "_recno" .OR. cKey == "_deleted"
         hOut[ cKey ] := dbf_IsoValue( hRecord[ cKey ] )
      ENDIF
   NEXT
   FOR EACH cField IN aFields
      IF hb_HHasKey( hRecord, cField )
         hOut[ cField ] := dbf_IsoValue( hRecord[ cField ] )
      ENDIF
   NEXT
   RETURN hOut


/*
 * dbf_Match - Evaluate a single filter operator against a record value.
 * Mirrors Python _match. Supported ops:
 *   eq, ne, lt, lte, gt, gte, contains, startswith, endswith, in, between.
 *
 * For "between" the value side is a hash { "min" => ..., "max" => ... }
 * where either bound may be NIL (open-ended).
 *
 * Returns .T. when the record value passes the filter, .F. otherwise.
 */
FUNCTION dbf_Match( xRec, cOp, xValue )
   LOCAL xLhs := xRec
   LOCAL xRhs := dbf_ParseDate( xValue )
   LOCAL cLhs, cRhs, x, xMin, xMax

   IF HB_ISDATE( xLhs ) .AND. HB_ISSTRING( xRhs )
      xRhs := dbf_ParseDate( xRhs )
   ENDIF
   IF HB_ISSTRING( xLhs )
      xLhs := RTrim( xLhs )
   ENDIF
   IF HB_ISSTRING( xRhs )
      xRhs := RTrim( xRhs )
   ENDIF

   SWITCH Lower( cOp )
   CASE "eq"
      RETURN xLhs == xRhs
   CASE "ne"
      RETURN ! ( xLhs == xRhs )
   CASE "lt"
      RETURN xLhs < xRhs
   CASE "lte"
      RETURN xLhs <= xRhs
   CASE "gt"
      RETURN xLhs > xRhs
   CASE "gte"
      RETURN xLhs >= xRhs
   CASE "contains"
      cLhs := hb_CStr( xLhs )
      cRhs := hb_CStr( xRhs )
      RETURN At( cRhs, cLhs ) > 0
   CASE "startswith"
      cLhs := hb_CStr( xLhs )
      cRhs := hb_CStr( xRhs )
      RETURN Len( cRhs ) <= Len( cLhs ) .AND. SubStr( cLhs, 1, Len( cRhs ) ) == cRhs
   CASE "endswith"
      cLhs := hb_CStr( xLhs )
      cRhs := hb_CStr( xRhs )
      RETURN Len( cRhs ) <= Len( cLhs ) .AND. SubStr( cLhs, Len( cLhs ) - Len( cRhs ) + 1 ) == cRhs
   CASE "in"
      IF ! HB_ISARRAY( xRhs )
         RETURN .F.
      ENDIF
      FOR EACH x IN xRhs
         IF xLhs == dbf_ParseDate( x )
            RETURN .T.
         ENDIF
      NEXT
      RETURN .F.
   CASE "between"
      IF ! HB_ISHASH( xRhs )
         RETURN .F.
      ENDIF
      xMin := dbf_ParseDate( hb_HGetDef( xRhs, "min", NIL ) )
      xMax := dbf_ParseDate( hb_HGetDef( xRhs, "max", NIL ) )
      RETURN ( xMin == NIL .OR. xLhs >= xMin ) .AND. ( xMax == NIL .OR. xLhs <= xMax )
   ENDSWITCH
   RETURN .F.


/*
 * dbf_MatchesFilters - Evaluate an array of filter hashes against a record.
 * Each filter is a hash { "field" => str, "op" => str, "value" => any }.
 * A missing field on the record fails the whole filter (matches Python).
 */
FUNCTION dbf_MatchesFilters( hRec, aFilters )
   LOCAL hFlt, cField, cOp

   IF aFilters == NIL .OR. Empty( aFilters )
      RETURN .T.
   ENDIF
   FOR EACH hFlt IN aFilters
      cField := hb_HGetDef( hFlt, "field", "" )
      cOp    := hb_HGetDef( hFlt, "op", "eq" )
      IF ! hb_HHasKey( hRec, cField )
         RETURN .F.
      ENDIF
      IF ! dbf_Match( hRec[ cField ], cOp, hb_HGetDef( hFlt, "value", NIL ) )
         RETURN .F.
      ENDIF
   NEXT
   RETURN .T.

