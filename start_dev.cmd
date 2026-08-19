@echo off
setlocal enabledelayedexpansion
title World of ClaudeCraft — Dev Launcher
color 0B

set "SELFHOST_DIR=D:\Program Files\World of ClaudeCraft Server"
set "PG_HOST=127.0.0.1"
set "PG_PORT=5433"
set "PG_DATA=%SELFHOST_DIR%\data\pgdata"
set "PG_LOG=%SELFHOST_DIR%\data\postgres.log"

REM ── Derive DATABASE_URL from self-host's .env ────────────────────
if exist "%SELFHOST_DIR%\.env" (
    for /f "tokens=2 delims==" %%a in ('findstr /b "DATABASE_URL=" "%SELFHOST_DIR%\.env" 2^>nul') do (
        set "DATABASE_URL=%%a"
    )
)
REM Fallback: derive from the PG data dir's credentials + .env.example
if "%DATABASE_URL%"=="" (
    for /f "tokens=2 delims==" %%a in ('findstr /b "DATABASE_URL=" ".env.example" 2^>nul') do (
        set "DATABASE_URL=%%a"
    )
)
REM --- Start PostgreSQL (portable binary) ---
echo ========================================
echo   World of ClaudeCraft — Dev Launcher
echo ========================================
echo.
echo [1/3] PostgreSQL

REM Check if PG is already listening
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
    REM Wait for it to be ready
    echo [*] Waiting for PostgreSQL ...
    :wait_pg
    timeout /t 2 /nobreak >nul
    "%SELFHOST_DIR%\postgres\bin\pg_isready.exe" -h %PG_HOST% -p %PG_PORT% -U eastbrook -d postgres >nul 2>&1
    if !ERRORLEVEL! neq 0 goto wait_pg
    echo [OK] PostgreSQL is ready.
)

REM --- Start Moon Server in a new window ---
echo.
echo [2/3] Moon Server (port 8787)
start "WoC Moon Server" cmd /c "cd /d moon-server && set DATABASE_URL=!DATABASE_URL! && start_dev.cmd"

REM --- Start Vite frontend ---
echo [3/3] Frontend (Vite) on http://localhost:5173
echo.
echo ========================================
echo   Open http://localhost:5173 in browser
echo   Press Ctrl+C to stop frontend
echo   Close the Moon Server window to stop it
echo   PostgreSQL will keep running
echo ========================================
echo.
npx vite
