@echo off
cls
REM Inspect any MCP server exe with MCP Inspector
REM Usage:  inspect.bat <name>          (with or without .exe)
REM   ex:   inspect.bat echo_server
REM   ex:   inspect.bat echo_server.exe

setlocal EnableExtensions

REM --- 1) argument ---
if "%~1"=="" (
    echo.
    echo Usage: %~nx0 ^<name^>
    echo Ex:    %~nx0 echo_server
    echo        %~nx0 echo_server.exe
    echo.
    exit /b 1
)

REM Strip any extension the user typed; %~n1 gives basename without ext.
set "BASE=%~n1"
set "EXE=%~dp0%BASE%.exe"
if not exist "%EXE%" (
    echo.
    echo [ERROR] Executable not found:
    echo         %EXE%
    echo.
    echo Build it first with:
    echo         hbmk2 %BASE%.hbp
    echo.
    exit /b 2
)

REM --- 2) Node.js installed? ---
where node >nul 2>&1
if errorlevel 1 (
    echo.
    echo [ERROR] Node.js not found in PATH.
    echo.
    echo The MCP Inspector requires Node.js ^(version 18 or above^).
    echo.
    echo How to install:
    echo   1^) Download the LTS installer at: https://nodejs.org/
    echo   2^) Run the installer ^(accept the default options^)
    echo   3^) Close and reopen this terminal
    echo   4^) Run again: %~nx0 %~1
    echo.
    exit /b 3
)

REM --- 3) Node version 18+ ---
for /f "tokens=1 delims=." %%v in ('node -p "process.versions.node"') do set "NODE_MAJOR=%%v"
if not defined NODE_MAJOR (
    echo.
    echo [ERROR] Could not detect Node.js version.
    echo.
    exit /b 4
)
if %NODE_MAJOR% LSS 18 (
    echo.
    echo [ERROR] Node.js too old. Detected: v%NODE_MAJOR%
    echo.
    echo The MCP Inspector needs Node.js 18 or above.
    echo Update at: https://nodejs.org/
    echo.
    exit /b 5
)

REM --- 4) npx available? ---
where npx >nul 2>&1
if errorlevel 1 (
    echo.
    echo [ERROR] npx not found in PATH.
    echo.
    echo It normally ships with Node.js. Reinstall the LTS at:
    echo   https://nodejs.org/
    echo.
    exit /b 6
)

REM --- 5) internet (first run downloads the package) ---
ping -n 1 registry.npmjs.org >nul 2>&1
if errorlevel 1 (
    echo.
    echo [WARN] No connection to registry.npmjs.org.
    echo.
    echo If this is the first run, the inspector needs to download its package.
    echo Check your internet or corporate proxy settings.
    echo.
    echo Trying anyway ^(works if the package is already cached^)...
    echo.
)

REM --- 6) all good, launch inspector ---
echo.
echo ============================================================
echo  MCP Inspector
echo  Server: %EXE%
echo  ^(the browser will open in a few seconds^)
echo  Press Ctrl+C to stop
echo ============================================================
echo.

npx @modelcontextprotocol/inspector "%EXE%"

endlocal
