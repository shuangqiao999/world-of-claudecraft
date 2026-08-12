@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
cd /d E:\gongxiang\World of ClaudeCraft

echo === Compiling sproto.core.dll (Lua 5.5 + AVX2) ===
cl /nologo /O2 /arch:AVX2 /MD /LD ^
  /I "dist-host-moon\moon-server\third\lua" ^
  /Fe:sproto.core.dll ^
  "E:\gongxiang\sproto\sproto.c" ^
  "E:\gongxiang\sproto\lsproto.c" ^
  /link /DLL /OUT:sproto.core.dll /FORCE:UNRESOLVED /NODEFAULTLIB:libcmt.lib

if exist sproto.core.dll (
  echo === Copying to clib ===
  copy /Y sproto.core.dll "dist-host-moon\moon-server\clib\sproto.core.dll"
  copy /Y sproto.core.dll "moon-server\clib\sproto.core.dll"
  del sproto.core.dll sproto.lib sproto.exp 2>nul
  echo === SUCCESS ===
) else (
  echo === FAILED ===
)
