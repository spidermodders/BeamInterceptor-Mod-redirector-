@echo off
setlocal EnableDelayedExpansion
cd /d "%~dp0"
set /p VERSION=<VERSION
set ROOT=%CD%
set LOADER_DLL=%ROOT%\AsiLoader\bin\x64\Release\dinput8.dll
set TAR=%SystemRoot%\System32\tar.exe

set TARGET=%~1
if "%TARGET%"=="" (
    echo BeamInterceptor %VERSION%
    echo.
    echo   1  ASI loader      ^(AsiLoader -^> version.dll^)
    echo   2  Ready package   ^(plugin + loader + config + ModifiedMods^)
    echo.
    set /p PICK="Build: "
    if "!PICK!"=="1" set TARGET=loader
    if "!PICK!"=="2" set TARGET=package
)

if /i "%TARGET%"=="loader" call :loader || goto failed
if /i "%TARGET%"=="package" call :package || goto failed
if /i "%TARGET%"=="all" call :package || goto failed

echo.
echo Build finished.
if "%~1"=="" pause
exit /b 0

:failed
echo.
echo Build failed.
if "%~1"=="" pause
exit /b 1


:msbuild
set MSBUILD=
set VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe
if exist "%VSWHERE%" (
    for /f "usebackq delims=" %%I in (`"%VSWHERE%" -latest -products * -requires Microsoft.Component.MSBuild -find MSBuild\**\Bin\MSBuild.exe`) do set MSBUILD=%%I
)
if not defined MSBUILD (
    echo MSBuild not found. Install Visual Studio 2022 with the "Desktop development with C++" workload.
    exit /b 1
)
exit /b 0


:: Ultimate ASI Loader (our fork). It is built as dinput8.dll and works unchanged when named version.dll.
:loader
echo.
echo == ASI loader
call :msbuild || exit /b 1
pushd AsiLoader
"%CD%\premake5.exe" vs2022 >nul || ( popd & exit /b 1 )
"%MSBUILD%" build\Ultimate-ASI-Loader.vcxproj -p:Configuration=Release -p:Platform=x64 -m -nologo -v:m
popd
if not exist "%LOADER_DLL%" ( echo Loader build produced no dinput8.dll. & exit /b 1 )
exit /b 0


:plugin
echo.
echo == Plugin
call :msbuild || exit /b 1
if not defined VCPKG_ROOT if not exist A:\vcpkg\vcpkg\scripts (
    echo Set VCPKG_ROOT to your vcpkg folder. It needs minhook and libzip for x64-windows-static:
    echo   vcpkg install minhook:x64-windows-static libzip:x64-windows-static
    exit /b 1
)
"%MSBUILD%" InterceptorSource\BeamInterceptor.vcxproj -p:Configuration=Release -p:Platform=x64 "-p:SolutionDir=%ROOT%\InterceptorSource\\" -m -nologo -v:m || exit /b 1
exit /b 0


:package
call :plugin || exit /b 1
if not exist "%LOADER_DLL%" call :loader || exit /b 1

echo.
echo == Ready package
set PKG=%ROOT%\ReadyPackage
set MODS=%PKG%\ModifiedMods\BeamMP
if exist "%PKG%" rmdir /s /q "%PKG%"
mkdir "%MODS%" || exit /b 1

copy /y "InterceptorSource\x64\Release\BeamInterceptor.asi" "%PKG%\" >nul || exit /b 1
copy /y "%LOADER_DLL%" "%PKG%\version.dll" >nul || exit /b 1
copy /y "InterceptorSource\Interceptor.config" "%PKG%\" >nul || exit /b 1

:: Mods are folders (or zips) in BeamMods. A BeamMP.zip, if present, is the base and everything else is laid over it.
if exist "BeamMods\BeamMP.zip" ( call :unpack "BeamMods\BeamMP.zip" || exit /b 1 )
for /d %%D in (BeamMods\*) do ( call :overlay "%%D" || exit /b 1 )
for %%Z in (BeamMods\*.zip) do ( if /i not "%%~nxZ"=="BeamMP.zip" ( call :unpack "%%Z" || exit /b 1 ) )

del /q "%MODS%\*.md" "%MODS%\Test.txt" 2>nul

if not exist "%ROOT%\out" mkdir "%ROOT%\out"
set ZIP=%ROOT%\out\BeamInterceptor-%VERSION%.zip
if exist "%ZIP%" del "%ZIP%"
:: Named items, not ".": "./" entry names make Windows Explorer call the zip invalid.
"%TAR%" -a -cf "%ZIP%" -C "%PKG%" BeamInterceptor.asi version.dll Interceptor.config ModifiedMods || exit /b 1
echo Package: %PKG%
echo Zip:     %ZIP%
exit /b 0


:: Copies one mod folder into the BeamMP folder.
:overlay
echo   %~nx1
xcopy "%~1\*" "%MODS%\" /e /y /q >nul
exit /b %ERRORLEVEL%


:: Extracts one mod zip into the BeamMP folder. A zip that wraps everything in a "BeamMP" folder is unwrapped first.
:unpack
echo   %~nx1
set TMP_DIR=%TEMP%\beam_unpack_%RANDOM%
mkdir "%TMP_DIR%" || exit /b 1
"%TAR%" -xf "%~1" -C "%TMP_DIR%" || ( rmdir /s /q "%TMP_DIR%" & exit /b 1 )
set SRC=%TMP_DIR%
if exist "%TMP_DIR%\BeamMP\" (
    set COUNT=0
    for /d %%D in ("%TMP_DIR%\*") do set /a COUNT+=1
    for %%F in ("%TMP_DIR%\*") do set /a COUNT+=1
    if !COUNT! equ 1 set SRC=%TMP_DIR%\BeamMP
)
xcopy "%SRC%\*" "%MODS%\" /e /y /q >nul
set RESULT=%ERRORLEVEL%
rmdir /s /q "%TMP_DIR%"
exit /b %RESULT%
