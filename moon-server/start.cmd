@echo off
REM World of ClaudeCraft — Moon Server
REM Usage: start.cmd [realm_name]

set WOC_REALM=%~1
if "%WOC_REALM%"=="" set WOC_REALM=Claudemoon

set DATABASE_URL=postgres://eastbrook:e20182a19889fa1a33e8593b66f0c042bf8d3c1de3554a01@127.0.0.1:5433/postgres
set PORT=8787
set ALLOW_DEV_COMMANDS=0

echo ========================================
echo   World of ClaudeCraft — Moon Server
echo ========================================
echo   Realm: %WOC_REALM%
echo   Port:  %PORT% (HTTP + WS)
echo ========================================
echo.

bin\moon.exe woc\main.lua
