@echo off
rem GIFT_LAUNCHER=1
rem gift - open a repository in Gift from the terminal.
rem
rem   gift              open the current directory
rem   gift C:\code\app  open that folder
setlocal
set "APP=%~dp0..\Gift.exe"
if not exist "%APP%" (
  echo gift: Gift.exe not found next to %~dp0 1>&2
  exit /b 1
)
rem No arguments means "here". A running Gift takes the folders over and
rem opens them in the same process.
if "%~1"=="" (
  start "" "%APP%" "%CD%"
) else (
  start "" "%APP%" %*
)
endlocal
