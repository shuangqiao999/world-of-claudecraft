@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
E:
cd "E:\gongxiang\World of ClaudeCraft"

echo === Compiling sproto.core.dll (Lua 5.5 + AVX2) ===
cl /nologo /O2 /arch:AVX2 /MD /LD ^
  /I "dist-host-moon\moon-server\third\lua" ^
  /Fe:sproto.core.dll ^
  "E:\gongxiang\sproto\sproto.c" ^
  "E:\gongxiang\sproto\lsproto.c" ^
  /link /DLL /OUT:sproto.core.dll /DEF:tmp\sproto_core.def tmp\lua.lib

if exist sproto.core.dll (
  copy /Y sproto.core.dll "dist-host-moon\moon-server\clib\sproto.core.dll"
  copy /Y sproto.core.dll "moon-server\clib\sproto.core.dll"
  echo sproto.core.dll: OK
) else (
  echo sproto.core.dll: FAILED
)
