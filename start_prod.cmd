@echo off
setlocal enabledelayedexpansion
title World of ClaudeCraft (Moon) — Self-Host
color 0B

set "SELFHOST_DIR=D:\Program Files\World of ClaudeCraft Server"
set "PG_HOST=127.0.0.1"
set "PG_PORT=5433"
set "PG_DATA=%SELFHOST_DIR%\data\pgdata"
set "PG_LOG=%SELFHOST_DIR%\data\postgres.log"

REM ── Check dist/ exists ──────────────────────────────────────────
if not exist "dist\index.html" (
    echo [!] dist/ not found. Run: npm run build
    pause
    exit /b 1
)

REM ── Derive DATABASE_URL from self-host's .env ────────────────────
if exist "%SELFHOST_DIR%\.env" (
    for /f "tokens=2 delims==" %%a in ('findstr /b "DATABASE_URL=" "%SELFHOST_DIR%\.env" 2^>nul') do (
        set "DATABASE_URL=%%a"
    )
)
if "%DATABASE_URL%"=="" (
    echo [!] Could not find DATABASE_URL in %SELFHOST_DIR%\.env
    echo     Using default from .env.example
    set "DATABASE_URL=postgres://eastbrook:e20182a19889fa1a33e8593b66f0c042bf8d3c1de3554a01@127.0.0.1:5433/postgres"
)

REM ── Get absolute path to project dist/ ───────────────────────────
set "STATIC_DIR=%CD%\dist"

echo ========================================
echo   World of ClaudeCraft (Moon) Self-Host
echo ========================================
echo   Static:  %STATIC_DIR%
echo.

REM ── PostgreSQL ────────────────────────────────────────────────────
echo [1/2] PostgreSQL
netstat -ano 2^>nul | findstr /r "127.0.0.1:%PG_PORT% *LISTENING" >nul
if !ERRORLEVEL! equ 0 (
    echo [OK] PostgreSQL already running on %PG_HOST%:%PG_PORT%
) else (
    echo [*] Starting portable PostgreSQL ...
    "%SELFHOST_DIR%\postgres\bin\pg_ctl.exe" -D "%PG_DATA%" -l "%PG_LOG%" -o "-p %PG_PORT% -h %PG_HOST%" start
    if !ERRORLEVEL! neq 0 (
        echo [FAIL] PostgreSQL failed to start. Check %PG_LOG%
        pause
        exit /b 1
    )
    echo [*] Waiting for PostgreSQL ...
    :wait_pg
    timeout /t 2 /nobreak >nul
    "%SELFHOST_DIR%\postgres\bin\pg_isready.exe" -h %PG_HOST% -p %PG_PORT% -U eastbrook -d postgres >nul 2>&1
    if !ERRORLEVEL! neq 0 goto wait_pg
    echo [OK] PostgreSQL is ready.
)

REM ── Moon Server (single port 8787: API + WS + static files) ─────
echo.
echo [2/2] Moon Server (port 8787)
echo.
echo ========================================
echo   Single port 8787: HTTP + WS + Static
echo   Open http://localhost:8787
echo   Press Ctrl+C to stop
echo ========================================
echo.

cd /d moon-server
set "STATIC_DIR=%STATIC_DIR%"
set "DATABASE_URL=%DATABASE_URL%"
set "PORT=8787"
set "WOC_REALM=Claudemoon"
set "ALLOW_DEV_COMMANDS=1"
bin\moon.exe woc\main.lua
