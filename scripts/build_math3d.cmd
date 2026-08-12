@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
cd /d E:\gongxiang\World of ClaudeCraft

echo === Compiling math3d.dll (Lua 5.5 + AVX2) ===
cl /nologo /O2 /arch:AVX2 /fp:fast /MD /LD ^
  /D_USE_MATH_DEFINES ^
  /I "dist-host-moon\moon-server\third\lua" ^
  /I "E:\gongxiang\math3d" ^
  /Fe:math3d.dll ^
  "E:\gongxiang\math3d\math3d.c" ^
  "E:\gongxiang\math3d\mathadapter.c" ^
  "E:\gongxiang\math3d\mathid.c" ^
  /link /DLL /OUT:math3d.dll /FORCE:UNRESOLVED /NODEFAULTLIB:libcmt.lib

if exist math3d.dll (
  echo === Copying to clib ===
  copy /Y math3d.dll "dist-host-moon\moon-server\clib\math3d.dll"
  copy /Y math3d.dll "moon-server\clib\math3d.dll"
  del math3d.dll math3d.lib math3d.exp 2>nul
  echo === SUCCESS ===
) else (
  echo === FAILED ===
)
