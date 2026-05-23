@echo off
REM compile_all.bat - Build every .exe in this samples/ directory.
REM Run: compile_all.bat
REM
REM Requires MSVC link.exe ahead of Git's link.exe in PATH.
REM Run from a "Developer Command Prompt for VS" or set the PATH yourself.

setlocal EnableExtensions

pushd "%~dp0"
for %%f in (*.hbp) do (
    echo.
    echo --- %%f ---
    hbmk2 "%%f"
)
popd

endlocal
