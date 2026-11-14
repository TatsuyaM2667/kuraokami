@echo off
rem Windows build (untested on real Windows). Needs: odin, zig, and freetype.lib
rem (e.g. vcpkg install freetype --triplet x64-windows-static; set FREETYPE_LIB to its lib dir).
rem SDL3.dll ships with Odin's vendor/sdl3 and is copied next to kuraokami.exe.
setlocal
for /f "delims=" %%i in ('odin root') do set ODIN_ROOT=%%i
if not exist "%ODIN_ROOT%\vendor\kb_text_shape\lib\kb_text_shape.lib" (
  zig cc -O2 -c "%ODIN_ROOT%\vendor\kb_text_shape\src\kb_text_shape.c" -o kb.obj || exit /b 1
  zig ar rcs "%ODIN_ROOT%\vendor\kb_text_shape\lib\kb_text_shape.lib" kb.obj || exit /b 1
  del kb.obj
)
odin build src -out:kuraokami.exe -o:speed -no-bounds-check -subsystem:windows -extra-linker-flags:"/LIBPATH:%FREETYPE_LIB%" || exit /b 1
copy /y "%ODIN_ROOT%\vendor\sdl3\SDL3.dll" . >nul
echo built kuraokami.exe
