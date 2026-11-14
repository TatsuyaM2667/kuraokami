@echo off
rem Windows build (untested on real Windows). Needs: odin, MSVC (cl/lib in a Developer Prompt),
rem and vcpkg packages: vcpkg install freetype harfbuzz zlib --triplet x64-windows-static
rem Set VCPKG_ROOT. SDL3.dll ships with Odin's vendor/sdl3; copy it next to kuraokami.exe.
setlocal
set INC=%VCPKG_ROOT%\installed\x64-windows-static\include
set LIBDIR=%VCPKG_ROOT%\installed\x64-windows-static\lib
if not exist lib mkdir lib
cl /nologo /O2 /c csrc\shim.c /Fo:lib\shim.obj /I csrc /I "%INC%" /I "%INC%\freetype2" /I "%INC%\harfbuzz" || exit /b 1
lib /nologo /OUT:lib\kshim.lib lib\shim.obj || exit /b 1
odin build src -out:kuraokami.exe -o:speed -no-bounds-check -subsystem:windows -extra-linker-flags:"/LIBPATH:%LIBDIR%" || exit /b 1
for /f "delims=" %%i in ('odin root') do copy /y "%%i\vendor\sdl3\SDL3.dll" . >nul
echo built kuraokami.exe
