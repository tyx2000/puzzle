@echo off
rem PUZZLE_PZ_LAUNCHER=1
rem pz - open a folder (or file) in Puzzle from the terminal.
rem
rem   pz                 open the current directory
rem   pz C:\code\app     open that folder
rem   pz main.c          open that file
rem   pz . --panel git
setlocal
set "APP=%PUZZLE_APP%"
if "%APP%"=="" set "APP=%~dp0..\Puzzle.exe"
if not exist "%APP%" (
  echo pz: Puzzle.exe not found next to %~dp0 1>&2
  echo.  set PUZZLE_APP=C:\path\to\Puzzle.exe to point at another copy 1>&2
  exit /b 1
)
rem No arguments means "here". A running Puzzle takes the paths over and opens
rem them in the same process rather than starting a second copy.
if "%~1"=="" (
  start "" "%APP%" "%CD%"
) else (
  start "" "%APP%" %*
)
endlocal
