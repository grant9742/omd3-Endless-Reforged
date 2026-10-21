@echo off
rem Remove the Reforged mod from the game folder. It does the same as install.sh rollback.
rem   uninstall.bat                 finds the game in the Steam libraries, then deletes the files listed in the manifest and the empty folders.
rem   uninstall.bat "<game folder>" uses that folder. You can also drag the game folder onto uninstall.bat.
rem The game folder contains OMD\. OMD3_GAME_DIR also sets it. Set OMD3_NO_PAUSE=1 to skip the pause.
setlocal enableextensions
set "ARG=%~f1"
set "RC=0"
set "DBLCLICK="
echo(%cmdcmdline%| find /i "%~nx0" >nul && set "DBLCLICK=1"
if defined OMD3_NO_PAUSE set "DBLCLICK="
cd /d "%~dp0"

call :findgame
if not defined WIN goto nogame
echo Game folder: %WIN%
set "MAN=%WIN%\.reforged-manifest"

if not exist "%MAN%" goto nomanifest

rem Delete each file that the manifest lists. The manifest uses forward slashes.
for /f "usebackq delims=" %%L in ("%MAN%") do call :delline "%%L"
del /q "%MAN%" 2>nul

rem Remove empty folders under ue4ss, deepest first. A folder that still has files is kept.
for /f "delims=" %%D in ('dir /ad /s /b "%WIN%\ue4ss" 2^>nul ^| sort /r') do rmdir "%%D" 2>nul
rmdir "%WIN%\ue4ss" 2>nul

rem Remove the runtime folders only when they are empty.
rmdir "%WIN%\Mods\Reforged\waves" 2>nul
rmdir "%WIN%\Mods\Reforged" 2>nul
rmdir "%WIN%\Mods" 2>nul

rem Remove the pak folder only when it is empty. The pak lines use ..\..\Content\Paks\Mods\ (relative to WIN).
rmdir "%WIN%\..\..\Content\Paks\Mods" 2>nul

echo Removed. The mod settings in Mods\Reforged stay if the folder is not empty.
goto done

:delline
set "rel=%~1"
set "rel=%rel:/=\%"
del /q "%WIN%\%rel%" 2>nul
goto :eof

:nomanifest
echo No manifest, nothing to remove: %MAN%
set "RC=1"
goto done

:nogame
echo Orcs Must Die 3 was not found.
if defined ARG echo This is not the game folder: %ARG%
if not defined ARG if defined OMD3_GAME_DIR echo This is not the game folder: OMD3_GAME_DIR=%OMD3_GAME_DIR%
echo The game folder contains OMD\. To find it: in Steam, right-click the game, then select Manage, Browse local files.
echo Then drag the game folder onto %~nx0, or run: %~nx0 "D:\SteamLibrary\steamapps\common\Orcs Must Die 3"
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
