; World of ClaudeCraft - Moon self-host server installer (NSIS 3.x)
; Installs the LAN host bundle: launcher exe, Moon game server,
; built client, and portable PostgreSQL. Start menu shortcut to the launcher.

Unicode true

!include "MUI2.nsh"
!include "FileFunc.nsh"

Name "World of ClaudeCraft Server (Moon)"
OutFile "E:\gongxiang\World of ClaudeCraft\dist-host-moon\WorldOfClaudeCraft-Moon-Server-Setup.exe"
InstallDir "$PROGRAMFILES64\World of ClaudeCraft Server (Moon)"
RequestExecutionLevel admin
SetCompressor /SOLID lzma

!define PRODUCT_NAME "World of ClaudeCraft Server (Moon)"
!define UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\WorldOfClaudeCraftMoonServer"

; ---------- UI ----------
!define MUI_ABORTWARNING
!define MUI_ICON "..\..\build\icon.ico"
!define MUI_UNICON "..\..\build\icon.ico"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "SimpChinese"
!insertmacro MUI_LANGUAGE "English"

; ---------- Sections ----------
Section "World of ClaudeCraft Server (Moon)" SEC_MAIN
  SetOutPath "$INSTDIR"
  SetOverwrite on

  ; Launcher
  File "..\..\dist-host-moon\WorldOfClaudeCraft-Moon.exe"

  ; Moon game server (keep the moon-server/ directory)
  SetOutPath "$INSTDIR\moon-server"
  File /r "..\..\dist-host-moon\moon-server\*"

  ; Built client (keep the dist/ directory, served by Moon Gate)
  SetOutPath "$INSTDIR\dist"
  File /r "..\..\dist-host-moon\dist\*"

  ; Portable PostgreSQL (keep the postgres/ directory)
  SetOutPath "$INSTDIR\postgres"
  File /r "..\..\dist-host-moon\postgres\*"

  ; Registry uninstall entry
  WriteUninstaller "$INSTDIR\uninstall.exe"
  WriteRegStr HKLM "${UNINST_KEY}" "DisplayName" "${PRODUCT_NAME}"
  WriteRegStr HKLM "${UNINST_KEY}" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegStr HKLM "${UNINST_KEY}" "DisplayIcon" "$INSTDIR\WorldOfClaudeCraft-Moon.exe"
  WriteRegStr HKLM "${UNINST_KEY}" "Publisher" "World of ClaudeCraft"
  WriteRegStr HKLM "${UNINST_KEY}" "InstallLocation" "$INSTDIR"
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  IntFmt $0 "0x%08X" $0
  WriteRegDWORD HKLM "${UNINST_KEY}" "EstimatedSize" "$0"

  ; Start menu shortcut
  CreateDirectory "$SMPROGRAMS\World of ClaudeCraft"
  CreateShortcut "$SMPROGRAMS\World of ClaudeCraft\World of ClaudeCraft Server (Moon).lnk" "$INSTDIR\WorldOfClaudeCraft-Moon.exe"
  CreateShortcut "$SMPROGRAMS\World of ClaudeCraft\Uninstall World of ClaudeCraft Moon Server.lnk" "$INSTDIR\uninstall.exe"
SectionEnd

; Optional desktop shortcut
Section "Desktop shortcut" SEC_DESKTOP
  CreateShortcut "$DESKTOP\World of ClaudeCraft Server (Moon).lnk" "$INSTDIR\WorldOfClaudeCraft-Moon.exe"
SectionEnd

; ---------- Uninstaller ----------
Section "Uninstall"
  Delete "$INSTDIR\uninstall.exe"
  Delete "$INSTDIR\WorldOfClaudeCraft-Moon.exe"
  RMDir /r "$INSTDIR\moon-server"
  RMDir /r "$INSTDIR\dist"
  RMDir /r "$INSTDIR\postgres"
  Delete "$SMPROGRAMS\World of ClaudeCraft\World of ClaudeCraft Server (Moon).lnk"
  Delete "$SMPROGRAMS\World of ClaudeCraft\Uninstall World of ClaudeCraft Moon Server.lnk"
  RMDir "$SMPROGRAMS\World of ClaudeCraft"
  Delete "$DESKTOP\World of ClaudeCraft Server (Moon).lnk"
  RMDir "$INSTDIR"
  DeleteRegKey HKLM "${UNINST_KEY}"
SectionEnd
