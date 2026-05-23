/*
 * dbf_config.prg - INI configuration for dbf_mcp.
 *
 * INI schema:
 *   [general]
 *   active_root     = C:\path\to\dbf
 *   encoding        = cp850
 *   deleted_default = true
 *
 *   [roots]
 *   default = C:\path\to\dbf
 *   alt     = D:\another\folder
 *
 * Env overrides applied at load time:
 *   DBF_MCP_CONFIG - alternate INI path
 *   DBF_ROOT       - override active_root
 *
 * The Harbour codepage name (used by hb_Translate when projecting char
 * fields to UTF-8 for JSON output) is derived from the encoding key. Only
 * the most common DBF encodings are mapped; anything else is passed through
 * unchanged (caller responsibility).
 */

#include "hbmcp.ch"


STATIC s_cConfigPath
STATIC s_cActiveRoot
STATIC s_hRoots
STATIC s_cEncoding         := "cp850"
STATIC s_cDataCdp          := "PT850"
STATIC s_lDeletedDefault   := .T.


FUNCTION dbf_LoadConfig()
   LOCAL hIni, hGen, hRoots, cEnvCfg, cEnvRoot, cBase, cKeyNorm, cKey

   cEnvCfg := GetEnv( "DBF_MCP_CONFIG" )
   IF ! Empty( cEnvCfg )
      s_cConfigPath := cEnvCfg
   ELSE
      s_cConfigPath := dbf_DefaultConfigPath()
   ENDIF

   cBase := dbf_DirOf( s_cConfigPath )

   IF hb_FileExists( s_cConfigPath )
      hIni := hb_iniRead( s_cConfigPath, .F. )
   ELSE
      hIni := { => }
   ENDIF
   IF HB_ISHASH( hIni )
      hb_HCaseMatch( hIni, .F. )
   ENDIF

   hGen := dbf_FindSection( hIni, "general" )
   IF HB_ISHASH( hGen )
      hb_HCaseMatch( hGen, .F. )
   ENDIF
   IF ! HB_ISHASH( hGen )
      hGen := { => }
   ENDIF

   s_cEncoding         := AllTrim( hb_HGetDef( hGen, "encoding", "cp850" ) )
   s_cDataCdp          := dbf_MapCodepage( s_cEncoding )
   s_lDeletedDefault   := dbf_ParseBool( hb_HGetDef( hGen, "deleted_default", "true" ), .T. )

   s_cActiveRoot := AllTrim( hb_HGetDef( hGen, "active_root", "" ) )
   IF Empty( s_cActiveRoot )
      s_cActiveRoot := hb_cwd()
   ENDIF
   s_cActiveRoot := dbf_NormalizePath( s_cActiveRoot, cBase )

   hRoots := dbf_FindSection( hIni, "roots" )
   IF ! HB_ISHASH( hRoots ) .OR. Empty( hRoots )
      s_hRoots := { "default" => s_cActiveRoot }
   ELSE
      s_hRoots := { => }
      FOR EACH cKey IN hb_HKeys( hRoots )
         cKeyNorm := Lower( AllTrim( hb_CStr( cKey ) ) )
         IF ! Empty( cKeyNorm )
            s_hRoots[ cKeyNorm ] := dbf_NormalizePath( AllTrim( hb_CStr( hRoots[ cKey ] ) ), cBase )
         ENDIF
      NEXT
   ENDIF

   cEnvRoot := GetEnv( "DBF_ROOT" )
   IF ! Empty( cEnvRoot )
      s_cActiveRoot := dbf_NormalizePath( cEnvRoot, cBase )
      s_hRoots[ "default" ] := s_cActiveRoot
   ENDIF

   RETURN NIL


FUNCTION dbf_SaveConfig()
   LOCAL hIni := { => }
   LOCAL hGen := { => }

   hGen[ "active_root" ]     := s_cActiveRoot
   hGen[ "encoding" ]        := s_cEncoding
   hGen[ "deleted_default" ] := iif( s_lDeletedDefault, "true", "false" )

   hIni[ "general" ] := hGen
   hIni[ "roots" ]   := s_hRoots

   hb_iniWrite( s_cConfigPath, hIni )
   RETURN s_cConfigPath


FUNCTION dbf_ConfigPath()
   RETURN s_cConfigPath


FUNCTION dbf_ActiveRoot()
   RETURN s_cActiveRoot


FUNCTION dbf_SetActiveRoot( cValue )
   LOCAL cResolved, cKey := Lower( AllTrim( hb_CStr( cValue ) ) )

   IF hb_HHasKey( s_hRoots, cKey )
      cResolved := s_hRoots[ cKey ]
   ELSE
      cResolved := dbf_NormalizePath( cValue, dbf_DirOf( s_cConfigPath ) )
   ENDIF
   s_cActiveRoot := cResolved
   s_hRoots[ "default" ] := cResolved
   RETURN s_cActiveRoot


FUNCTION dbf_Roots()
   RETURN s_hRoots


FUNCTION dbf_Encoding()
   RETURN s_cEncoding


FUNCTION dbf_DataCdp()
   RETURN s_cDataCdp


FUNCTION dbf_DeletedDefault()
   RETURN s_lDeletedDefault


/*
 * Convert a character field read from a DBF (in s_cDataCdp encoding) into
 * UTF-8 for JSON output. Empty strings are passed through.
 */
FUNCTION dbf_ToUtf8( cText )
   IF ! HB_ISSTRING( cText ) .OR. Empty( cText )
      RETURN cText
   ENDIF
   RETURN hb_Translate( cText, s_cDataCdp, "UTF8" )


STATIC FUNCTION dbf_FindSection( hIni, cName )
   LOCAL cKey, cLow := Lower( cName )
   IF ! HB_ISHASH( hIni )
      RETURN { => }
   ENDIF
   FOR EACH cKey IN hb_HKeys( hIni )
      IF Lower( AllTrim( cKey ) ) == cLow
         RETURN hIni[ cKey ]
      ENDIF
   NEXT
   RETURN { => }


STATIC FUNCTION dbf_DefaultConfigPath()
   LOCAL cExe := hb_DirBase()
   IF Empty( cExe )
      cExe := hb_cwd()
   ENDIF
   RETURN cExe + "dbf_mcp.ini"


STATIC FUNCTION dbf_DirOf( cPath )
   LOCAL cDir := ""
   hb_FNameSplit( cPath, @cDir )
   RETURN cDir


STATIC FUNCTION dbf_NormalizePath( cValue, cBase )
   LOCAL cPath := AllTrim( cValue )
   IF Empty( cPath )
      RETURN cBase
   ENDIF
   IF ! dbf_IsAbs( cPath )
      cPath := hb_PathNormalize( cBase + cPath )
   ENDIF
   IF Right( cPath, 1 ) != hb_ps()
      cPath += hb_ps()
   ENDIF
   RETURN cPath


STATIC FUNCTION dbf_IsAbs( cPath )
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


STATIC FUNCTION dbf_MapCodepage( cName )
   LOCAL cKey := Lower( AllTrim( cName ) )
   SWITCH cKey
   CASE "cp850"      ; RETURN "PT850"
   CASE "cp852"      ; RETURN "CS852"
   CASE "cp437"      ; RETURN "EN"
   CASE "cp1252"     ; RETURN "ESWIN"
   CASE "windows-1252" ; RETURN "ESWIN"
   CASE "iso-8859-1" ; RETURN "PTISO"
   CASE "latin1"     ; RETURN "PTISO"
   CASE "utf-8"      ; RETURN "UTF8"
   CASE "utf8"       ; RETURN "UTF8"
   ENDSWITCH
   RETURN Upper( cName )


STATIC FUNCTION dbf_ParseBool( xValue, lDefault )
   LOCAL cLow
   IF HB_ISLOGICAL( xValue )
      RETURN xValue
   ENDIF
   IF HB_ISNUMERIC( xValue )
      RETURN xValue != 0
   ENDIF
   IF HB_ISSTRING( xValue )
      cLow := Lower( AllTrim( xValue ) )
      IF cLow == "true" .OR. cLow == "yes" .OR. cLow == "1" .OR. cLow == "on"
         RETURN .T.
      ENDIF
      IF cLow == "false" .OR. cLow == "no" .OR. cLow == "0" .OR. cLow == "off"
         RETURN .F.
      ENDIF
   ENDIF
   RETURN lDefault

