@echo off
rem Install or update the Reforged mod in the game folder. It does not start a server.
rem   start.bat                 finds the game in the Steam libraries, then installs or updates the mod.
rem   start.bat "<game folder>" uses that folder. You can also drag the game folder onto start.bat.
rem The game folder contains OMD\. OMD3_GAME_DIR also sets it. Set OMD3_NO_PAUSE=1 to skip the pause.
rem Layout: Binaries\Win64\dwmapi.dll, Binaries\Win64\ue4ss\ (UE4SS, log ue4ss\UE4SS.log, mod ue4ss\Mods\Reforged\).
setlocal enableextensions
set "ARG=%~f1"
set "RC=0"
set "DBLCLICK="
echo(%cmdcmdline%| find /i "%~nx0" >nul && set "DBLCLICK=1"
if defined OMD3_NO_PAUSE set "DBLCLICK="
cd /d "%~dp0"
set "SRC=Mods\Reforged\ue4ss\Reforged"
set "U=vendor\UE4SS"

call :findgame
if not defined WIN goto nogame
echo Game folder: %WIN%
if exist "%WIN%\.orcaitest-manifest" goto migrate
if exist "%WIN%\.reforged-manifest" goto checkold
if exist "%WIN%\dwmapi.dll" goto haveproxy

goto install

:migrate
echo Old OrcAITest install found. Removing it by its manifest.
for /f "usebackq delims=" %%L in ("%WIN%\.orcaitest-manifest") do del /q "%WIN%\%%L" 2>nul
del /q "%WIN%\.orcaitest-manifest"
rmdir /s /q "%WIN%\Mods\OrcAITest" 2>nul
goto install

:checkold
findstr /x /c:"UE4SS.dll" "%WIN%\.reforged-manifest" >nul 2>nul
if not errorlevel 1 goto upgrade
goto update

:upgrade
echo Old UE4SS layout found. Removing it by its manifest.
for /f "usebackq delims=" %%L in ("%WIN%\.reforged-manifest") do del /q "%WIN%\%%L" 2>nul
del /q "%WIN%\.reforged-manifest"
rmdir "%WIN%\Mods\Reforged\waves" 2>nul
rmdir "%WIN%\Mods\Reforged\Scripts" 2>nul
rmdir "%WIN%\Mods\Reforged" 2>nul
rmdir "%WIN%\Mods" 2>nul
goto install

:install
echo Installing or updating the Reforged mod.
rem A UE4SS.log symlink is a test leftover. A regular UE4SS.log is never removed.
dir /al "%WIN%\UE4SS.log" >nul 2>nul && del /q "%WIN%\UE4SS.log"
rem The manifest is written before the copy, so a failed copy can be resumed by running this again.
(echo dwmapi.dll)> "%WIN%\.reforged-manifest" || goto nowrite
call :writeue4ssmanifest
>> "%WIN%\.reforged-manifest" echo ue4ss/Mods/Reforged/enabled.txt
for %%f in (%SRC%\Scripts\*.lua) do >> "%WIN%\.reforged-manifest" echo ue4ss/Mods/Reforged/Scripts/%%~nxf
>> "%WIN%\.reforged-manifest" echo ue4ss/Mods/Reforged/Scripts/reforged_gate.dll
>> "%WIN%\.reforged-manifest" echo ue4ss/Mods/Reforged/Scripts/reforged_gate.log
if exist "%SRC%\waves\*.json" for %%f in (%SRC%\waves\*.json) do >> "%WIN%\.reforged-manifest" echo Mods/Reforged/waves/%%~nxf
copy /y "%U%\dwmapi.dll" "%WIN%\dwmapi.dll" >nul
xcopy /e /i /y "%U%\ue4ss" "%WIN%\ue4ss" >nul
mkdir "%WIN%\ue4ss\Mods\Reforged\Scripts" 2>nul
copy /y "%SRC%\enabled.txt" "%WIN%\ue4ss\Mods\Reforged\enabled.txt" >nul
copy /y "%SRC%\Scripts\*.lua" "%WIN%\ue4ss\Mods\Reforged\Scripts\" >nul
copy /y "%SRC%\Scripts\reforged_gate.dll" "%WIN%\ue4ss\Mods\Reforged\Scripts\" >nul
mkdir "%WIN%\Mods\Reforged\waves" 2>nul
if exist "%SRC%\waves\*.json" copy /y "%SRC%\waves\*.json" "%WIN%\Mods\Reforged\waves\" >nul
echo Installed. Manifest: %WIN%\.reforged-manifest
echo Start the game. The mod loads at the next game start.
tasklist /FI "IMAGENAME eq OMD-Win64-Shipping.exe" 2>nul | find /i "OMD-Win64-Shipping.exe" >nul
if not errorlevel 1 echo The game is running. Restart it to load the new files.
goto done

:update
rem An update does the same steps as an install.
goto install

rem Appends one "ue4ss/<path>" line per file under vendor\UE4SS\ue4ss to the manifest, with forward slashes.
:writeue4ssmanifest
pushd "%U%\ue4ss"
set "UEROOT=%CD%\"
for /r %%F in (*) do call :manline "%%F"
popd
goto :eof

:manline
call set "rel=%~1"
call set "rel=%%rel:%UEROOT%=%%"
call set "rel=%%rel:\=/%%"
>> "%WIN%\.reforged-manifest" echo ue4ss/%rel%
goto :eof

:nogame
echo Orcs Must Die 3 was not found.
if defined ARG echo This is not the game folder: %ARG%
if not defined ARG if defined OMD3_GAME_DIR echo This is not the game folder: OMD3_GAME_DIR=%OMD3_GAME_DIR%
echo The game folder contains OMD\. To find it: in Steam, right-click the game, then select Manage, Browse local files.
echo Then drag the game folder onto %~nx0, or run: %~nx0 "D:\SteamLibrary\steamapps\common\Orcs Must Die 3"
set "RC=1"
goto done

:nowrite
echo Cannot write to %WIN%. Close the game, then run %~nx0 again. If that fails, right-click %~nx0 and select Run as administrator.
set "RC=1"
goto done

:haveproxy
echo %WIN%\dwmapi.dll already exists and the mod is not installed. Refusing to overwrite it.
echo Another mod can use dwmapi.dll. Remove that mod first.
set "RC=1"
goto done

:done
if defined DBLCLICK pause
exit /b %RC%

rem begin findgame (start.bat and uninstall.bat have the same copy; scripts/test_windows_install.py checks this)
rem Sets WIN to the game's OMD\Binaries\Win64 folder, or leaves WIN empty.
rem Order: the ARG folder, OMD3_GAME_DIR, the Steam libraries, then the folder that the user types.
:findgame
set "WIN="
if defined ARG goto findgame_arg
if defined OMD3_GAME_DIR goto findgame_env
for /f "tokens=2,*" %%A in ('reg query "HKCU\Software\Valve\Steam" /v SteamPath 2^>nul ^| find /i "SteamPath"') do call :trysteam "%%B"
if defined WIN goto :eof
for /f "tokens=2,*" %%A in ('reg query "HKLM\SOFTWARE\WOW6432Node\Valve\Steam" /v InstallPath 2^>nul ^| find /i "InstallPath"') do call :trysteam "%%B"
if defined WIN goto :eof
call :trysteam "%ProgramFiles(x86)%\Steam"
if defined WIN goto :eof
call :askgame
goto :eof

:askgame
echo Orcs Must Die 3 was not found in the Steam libraries.
echo To find the game folder: in Steam, right-click the game, then select Manage, Browse local files.
set "ANSWER="
set /p "ANSWER=Paste the game folder path, then press Enter (press Enter only to stop): "
if not defined ANSWER goto :eof
set "ANSWER=%ANSWER:"=%"
call :trygame "%ANSWER%"
goto :eof

:findgame_arg
call :trygame "%ARG%"
goto :eof

:findgame_env
call :trygame "%OMD3_GAME_DIR%"
goto :eof

rem Tries one Steam folder: its own library, then each library in steamapps\libraryfolders.vdf.
:trysteam
if defined WIN goto :eof
set "SROOT=%~1"
set "SROOT=%SROOT:/=\%"
call :trygame "%SROOT%\steamapps\common\Orcs Must Die 3"
if defined WIN goto :eof
if not exist "%SROOT%\steamapps\libraryfolders.vdf" goto :eof
rem A vdf line is:  "path"  "D:\\SteamLibrary". Token 4 between the quotes is the folder.
for /f tokens^=4^ delims^=^" %%P in ('findstr /i /c:"path" "%SROOT%\steamapps\libraryfolders.vdf"') do call :trylib "%%P"
goto :eof

:trylib
if defined WIN goto :eof
set "LIB=%~1"
set "LIB=%LIB:\\=\%"
call :trygame "%LIB%\steamapps\common\Orcs Must Die 3"
goto :eof

rem Accepts the game folder (it contains OMD\) or the OMD\Binaries\Win64 folder itself.
:trygame
if exist "%~1\OMD\Binaries\Win64\OMD-Win64-Shipping.exe" (set "WIN=%~1\OMD\Binaries\Win64" & goto :eof)
if exist "%~1\OMD-Win64-Shipping.exe" set "WIN=%~1"
goto :eof
rem end findgame
