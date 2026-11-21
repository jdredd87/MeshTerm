@echo off
rem Builds MeshTerm.exe (64-bit) from the command line. Or open MeshTerm.dpr in Delphi.
setlocal
call "C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\rsvars.bat"
cd /d "%~dp0"
brcc32 -fo MeshTerm.res MeshTerm.rc || goto :err
dcc64 -B -Q -$D- -$O+ -E. -NUdcu MeshTerm.dpr || goto :err
echo Built %~dp0MeshTerm.exe
exit /b 0
:err
echo BUILD FAILED
exit /b 1
