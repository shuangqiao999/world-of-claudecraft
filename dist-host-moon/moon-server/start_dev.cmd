@echo off
REM World of ClaudeCraft — Moon Server (Development Mode)

set WOC_REALM=%~1
if "%WOC_REALM%"=="" set WOC_REALM=Claudemoon
if "%DATABASE_URL%"=="" set DATABASE_URL=postgres://eastbrook:e20182a19889fa1a33e8593b66f0c042bf8d3c1de3554a01@127.0.0.1:5433/postgres
set ALLOW_DEV_COMMANDS=1

echo ========================================
echo   World of ClaudeCraft — Moon Server
echo   !! DEVELOPMENT MODE !!
echo ========================================
echo   Realm: %WOC_REALM%
echo   Port:  8787 (HTTP + WS)
echo   Dev:   ENABLED
echo ========================================
echo.

bin\moon.exe woc\main.lua
