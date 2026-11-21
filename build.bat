@echo off
rem Builds MeshTerm (FireMonkey: Windows and Android).
rem Usage: build            - Win64 Debug  (Win64\Debug\MeshTerm.exe)
rem        build android    - Android64 Debug APK
rem        build android install [device]  - and install it with adb (-s device when several)
setlocal
call "C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\rsvars.bat" || exit /b 1
cd /d "%~dp0"
if /i "%~1"=="android" goto android
msbuild MeshTerm.dproj /t:Build /p:Config=Debug /p:Platform=Win64 /nologo /v:minimal || exit /b 1
echo Built %~dp0Win64\Debug\MeshTerm.exe
exit /b 0
:android
if "%MT_ANDROID_SDK%"=="" set MT_ANDROID_SDK=AndroidAPI36.1_64bit.sdk
msbuild MeshTerm.dproj /t:Build;Deploy /p:Config=Debug /p:Platform=Android64 /p:PlatformSDK=%MT_ANDROID_SDK% /nologo /v:minimal || exit /b 1
echo APK: %~dp0Android64\Debug\MeshTerm\bin\MeshTerm.apk
if /i not "%~2"=="install" exit /b 0
set ADB=C:\Users\Public\Documents\Embarcadero\Studio\37.0\CatalogRepository\AndroidSDK-37.0.60952.8797\platform-tools\adb.exe
if "%~3"=="" ("%ADB%" install -r Android64\Debug\MeshTerm\bin\MeshTerm.apk) else ("%ADB%" -s %3 install -r Android64\Debug\MeshTerm\bin\MeshTerm.apk)
exit /b %ERRORLEVEL%
