; World of ClaudeCraft - self-host server installer (NSIS 3.x)
; Installs the LAN host bundle: launcher exe, Node runtime, game server,
; built client, and portable PostgreSQL. Start menu shortcut to the launcher.

Unicode true

!include "MUI2.nsh"
!include "FileFunc.nsh"

Name "World of ClaudeCraft Server"
OutFile "E:\gongxiang\World of ClaudeCraft\dist-host\WorldOfClaudeCraft-Server-Setup.exe"
InstallDir "$PROGRAMFILES64\World of ClaudeCraft Server"
RequestExecutionLevel admin
SetCompressor /SOLID lzma

!define PRODUCT_NAME "World of ClaudeCraft Server"
!define UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\WorldOfClaudeCraftServer"

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
Section "World of ClaudeCraft Server" SEC_MAIN
  SetOutPath "$INSTDIR"
  SetOverwrite on

  ; Launcher + runtime
  File "..\..\dist-host\WorldOfClaudeCraft.exe"
  File "..\..\dist-host\node.exe"

  ; Server bundle (keep the dist-server/ directory)
  SetOutPath "$INSTDIR\dist-server"
  File /r "..\..\dist-host\dist-server\*"

  ; Built client (keep the dist/ directory, which is the server's STATIC_DIR)
  SetOutPath "$INSTDIR\dist"
  File /r "..\..\dist-host\dist\*"

  ; Portable PostgreSQL (keep the postgres/ directory)
  SetOutPath "$INSTDIR\postgres"
  File /r "..\..\dist-host\postgres\*"

  ; Registry uninstall entry
  WriteUninstaller "$INSTDIR\uninstall.exe"
  WriteRegStr HKLM "${UNINST_KEY}" "DisplayName" "${PRODUCT_NAME}"
  WriteRegStr HKLM "${UNINST_KEY}" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegStr HKLM "${UNINST_KEY}" "DisplayIcon" "$INSTDIR\WorldOfClaudeCraft.exe"
  WriteRegStr HKLM "${UNINST_KEY}" "Publisher" "World of ClaudeCraft"
  WriteRegStr HKLM "${UNINST_KEY}" "InstallLocation" "$INSTDIR"
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  IntFmt $0 "0x%08X" $0
  WriteRegDWORD HKLM "${UNINST_KEY}" "EstimatedSize" "$0"

  ; Start menu shortcut
  CreateDirectory "$SMPROGRAMS\World of ClaudeCraft"
  CreateShortcut "$SMPROGRAMS\World of ClaudeCraft\World of ClaudeCraft Server.lnk" "$INSTDIR\WorldOfClaudeCraft.exe"
  CreateShortcut "$SMPROGRAMS\World of ClaudeCraft\Uninstall World of ClaudeCraft Server.lnk" "$INSTDIR\uninstall.exe"
SectionEnd

; Optional desktop shortcut
Section "Desktop shortcut" SEC_DESKTOP
  CreateShortcut "$DESKTOP\World of ClaudeCraft Server.lnk" "$INSTDIR\WorldOfClaudeCraft.exe"
SectionEnd

; ---------- Uninstaller ----------
Section "Uninstall"
  Delete "$INSTDIR\uninstall.exe"
  Delete "$INSTDIR\WorldOfClaudeCraft.exe"
  Delete "$INSTDIR\node.exe"
  RMDir /r "$INSTDIR\dist-server"
  RMDir /r "$INSTDIR\dist"
  RMDir /r "$INSTDIR\postgres"
  Delete "$SMPROGRAMS\World of ClaudeCraft\World of ClaudeCraft Server.lnk"
  Delete "$SMPROGRAMS\World of ClaudeCraft\Uninstall World of ClaudeCraft Server.lnk"
  RMDir "$SMPROGRAMS\World of ClaudeCraft"
  Delete "$DESKTOP\World of ClaudeCraft Server.lnk"
  RMDir "$INSTDIR"
  DeleteRegKey HKLM "${UNINST_KEY}"
SectionEnd
