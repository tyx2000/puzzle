; Puzzle for Windows - the installer.
;
; Built by windows/build.sh:
;   makensis -DVERSION=1.0.0 -DAPPDIR=<built app folder> -DOUTFILE=<setup.exe> -DICON=<ico> puzzle.nsi
;
; A per-user install: no administrator rights, into %LOCALAPPDATA%\Programs\Puzzle,
; with a Start menu entry, an optional desktop shortcut, "Open with Puzzle" on
; files and folders in Explorer, and the `pz` command on the user's PATH.

Unicode true
SetCompressor /SOLID lzma
RequestExecutionLevel user

!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "WinMessages.nsh"
!include "FileFunc.nsh"
!include "Sections.nsh"

!ifndef VERSION
  !define VERSION "1.0.0"
!endif
!define APPNAME "Puzzle"
!define PUBLISHER "Puzzle"
!define UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\Puzzle"
!define MUTEX "Local\Puzzle.SingleInstance.4e81b9"

Name "${APPNAME}"
OutFile "${OUTFILE}"
InstallDir "$LOCALAPPDATA\Programs\${APPNAME}"
InstallDirRegKey HKCU "Software\${APPNAME}" "InstallDir"
BrandingText "${APPNAME} ${VERSION}"

VIProductVersion "${VERSION}.0"
VIAddVersionKey "ProductName" "${APPNAME}"
VIAddVersionKey "FileDescription" "${APPNAME} installer"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "ProductVersion" "${VERSION}"
VIAddVersionKey "LegalCopyright" "${PUBLISHER}"

!define MUI_ICON "${ICON}"
!define MUI_UNICON "${ICON}"
!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\Puzzle.exe"
!define MUI_FINISHPAGE_RUN_TEXT "Open ${APPNAME}"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"
!insertmacro MUI_LANGUAGE "SimpChinese"

; -- Waiting for a running copy ---------------------------------------------

!macro WaitForAppToClose
  ${Do}
    System::Call 'kernel32::OpenMutexW(i 0x00100000, i 0, w "${MUTEX}") p .r0'
    ${If} $0 P= 0
      ${Break}
    ${EndIf}
    System::Call 'kernel32::CloseHandle(p r0)'
    MessageBox MB_RETRYCANCEL|MB_ICONEXCLAMATION "${APPNAME} is running. Close it, then choose Retry." /SD IDCANCEL IDRETRY +2
    Abort
  ${Loop}
!macroend

; -- PATH -------------------------------------------------------------------
; $R0 = the folder; the user's PATH is rebuilt entry by entry, so the folder
; is matched whole and in any letter case.

Var PathResult
Var PathEntry
Var PathFound

!macro PathEntries un
Function ${un}CollectEntry
  ${If} $PathEntry != ""
    ${If} $PathEntry == $R0
      StrCpy $PathFound 1
      ${If} $R1 == "remove"
        StrCpy $PathEntry ""
      ${EndIf}
    ${EndIf}
  ${EndIf}
  ${If} $PathEntry != ""
    ${If} $PathResult == ""
      StrCpy $PathResult $PathEntry
    ${Else}
      StrCpy $PathResult "$PathResult;$PathEntry"
    ${EndIf}
  ${EndIf}
  StrCpy $PathEntry ""
FunctionEnd

; $R0 = folder, $R1 = "add" or "remove"
Function ${un}EditUserPath
  ReadRegStr $1 HKCU "Environment" "Path"
  StrCpy $PathResult ""
  StrCpy $PathEntry ""
  StrCpy $PathFound 0
  StrCpy $2 0
  loop:
    StrCpy $3 $1 1 $2
    ${If} $3 == ""
      Call ${un}CollectEntry
      Goto done
    ${EndIf}
    ${If} $3 == ";"
      Call ${un}CollectEntry
    ${Else}
      StrCpy $PathEntry "$PathEntry$3"
    ${EndIf}
    IntOp $2 $2 + 1
    Goto loop
  done:
  ${If} $R1 == "add"
    ${If} $PathFound == 0
      ${If} $PathResult == ""
        StrCpy $PathResult $R0
      ${Else}
        StrCpy $PathResult "$PathResult;$R0"
      ${EndIf}
      WriteRegExpandStr HKCU "Environment" "Path" $PathResult
      SendMessage ${HWND_BROADCAST} ${WM_SETTINGCHANGE} 0 "STR:Environment" /TIMEOUT=5000
    ${EndIf}
  ${ElseIf} $PathFound == 1
    WriteRegExpandStr HKCU "Environment" "Path" $PathResult
    SendMessage ${HWND_BROADCAST} ${WM_SETTINGCHANGE} 0 "STR:Environment" /TIMEOUT=5000
  ${EndIf}
FunctionEnd
!macroend
!insertmacro PathEntries ""
!insertmacro PathEntries "un."

; -- Sections ---------------------------------------------------------------

Section "${APPNAME}" SecApp
  SectionIn RO
  !insertmacro WaitForAppToClose
  SetOutPath "$INSTDIR"
  File "${APPDIR}\Puzzle.exe"
  SetOutPath "$INSTDIR\bin"
  File "${APPDIR}\bin\pz.cmd"
  SetOutPath "$INSTDIR\resources"
  File /r "${APPDIR}\resources\*.*"
  SetOutPath "$INSTDIR"

  WriteUninstaller "$INSTDIR\Uninstall.exe"
  WriteRegStr HKCU "Software\${APPNAME}" "InstallDir" "$INSTDIR"

  CreateShortCut "$SMPROGRAMS\${APPNAME}.lnk" "$INSTDIR\Puzzle.exe" "" "$INSTDIR\Puzzle.exe" 0

  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayName" "${APPNAME}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "Publisher" "${PUBLISHER}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayIcon" "$INSTDIR\Puzzle.exe"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKCU "${UNINSTALL_KEY}" "QuietUninstallString" '"$INSTDIR\Uninstall.exe" /S'
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoRepair" 1
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  IntFmt $0 "0x%08X" $0
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "EstimatedSize" "$0"
SectionEnd

Section "Open with ${APPNAME} in Explorer" SecExplorer
  ; A project is a folder, and any file can be opened as text: offered on
  ; folders, a folder's background and files, never as the default action.
  WriteRegStr HKCU "Software\Classes\Directory\shell\${APPNAME}" "" "Open with ${APPNAME}"
  WriteRegStr HKCU "Software\Classes\Directory\shell\${APPNAME}" "Icon" '"$INSTDIR\Puzzle.exe",0'
  WriteRegStr HKCU "Software\Classes\Directory\shell\${APPNAME}\command" "" '"$INSTDIR\Puzzle.exe" "%V"'
  WriteRegStr HKCU "Software\Classes\Directory\Background\shell\${APPNAME}" "" "Open with ${APPNAME}"
  WriteRegStr HKCU "Software\Classes\Directory\Background\shell\${APPNAME}" "Icon" '"$INSTDIR\Puzzle.exe",0'
  WriteRegStr HKCU "Software\Classes\Directory\Background\shell\${APPNAME}\command" "" '"$INSTDIR\Puzzle.exe" "%V"'
  WriteRegStr HKCU "Software\Classes\*\shell\${APPNAME}" "" "Open with ${APPNAME}"
  WriteRegStr HKCU "Software\Classes\*\shell\${APPNAME}" "Icon" '"$INSTDIR\Puzzle.exe",0'
  WriteRegStr HKCU "Software\Classes\*\shell\${APPNAME}\command" "" '"$INSTDIR\Puzzle.exe" "%1"'
  ; Listed under "Open with" for every file type.
  WriteRegStr HKCU "Software\Classes\Applications\Puzzle.exe\shell\open\command" "" '"$INSTDIR\Puzzle.exe" "%1"'
  WriteRegStr HKCU "Software\Classes\Applications\Puzzle.exe" "FriendlyAppName" "${APPNAME}"
SectionEnd

Section "The pz command (adds it to PATH)" SecPath
  StrCpy $R0 "$INSTDIR\bin"
  StrCpy $R1 "add"
  Call EditUserPath
SectionEnd

Section /o "Desktop shortcut" SecDesktop
  CreateShortCut "$DESKTOP\${APPNAME}.lnk" "$INSTDIR\Puzzle.exe" "" "$INSTDIR\Puzzle.exe" 0
SectionEnd

; The app adds its command to PATH on launch unless the installer was told
; not to.
Section "-Remember the PATH choice"
  ${If} ${SectionIsSelected} ${SecPath}
    WriteRegDWORD HKCU "Software\${APPNAME}" "LauncherOnPath" 1
  ${Else}
    WriteRegDWORD HKCU "Software\${APPNAME}" "LauncherOnPath" 0
  ${EndIf}
SectionEnd

!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
  !insertmacro MUI_DESCRIPTION_TEXT ${SecApp} "The app."
  !insertmacro MUI_DESCRIPTION_TEXT ${SecExplorer} "Right-click a file or folder in Explorer to open it in ${APPNAME}."
  !insertmacro MUI_DESCRIPTION_TEXT ${SecPath} "Type pz in a terminal to open the current folder."
  !insertmacro MUI_DESCRIPTION_TEXT ${SecDesktop} "A shortcut on the desktop."
!insertmacro MUI_FUNCTION_DESCRIPTION_END

; -- Uninstall --------------------------------------------------------------

Section "Uninstall"
  !insertmacro WaitForAppToClose
  StrCpy $R0 "$INSTDIR\bin"
  StrCpy $R1 "remove"
  Call un.EditUserPath

  Delete "$SMPROGRAMS\${APPNAME}.lnk"
  Delete "$DESKTOP\${APPNAME}.lnk"
  DeleteRegKey HKCU "Software\Classes\Directory\shell\${APPNAME}"
  DeleteRegKey HKCU "Software\Classes\Directory\Background\shell\${APPNAME}"
  DeleteRegKey HKCU "Software\Classes\*\shell\${APPNAME}"
  DeleteRegKey HKCU "Software\Classes\Applications\Puzzle.exe"
  DeleteRegKey HKCU "${UNINSTALL_KEY}"
  DeleteRegValue HKCU "Software\${APPNAME}" "InstallDir"

  Delete "$INSTDIR\Puzzle.exe"
  Delete "$INSTDIR\bin\pz.cmd"
  RMDir "$INSTDIR\bin"
  RMDir /r "$INSTDIR\resources"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"
SectionEnd
