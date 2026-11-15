; DigUp's additions to Tauri's NSIS installer (bundle.windows.nsis.installerHooks).

; The helper folder is replaced whole: an update would otherwise leave behind what an older version had there and
; this one doesn't (another ffmpeg's DLLs).
!macro NSIS_HOOK_PREINSTALL
  ${If} $INSTDIR != ""
    IfFileExists "$INSTDIR\helper\*.*" 0 digup_runtime_cleaned
    ClearErrors
    RMDir /r "$INSTDIR\helper"
    IfErrors 0 digup_runtime_cleaned
    MessageBox MB_OK|MB_ICONSTOP "DigUp's runtime is still in use. Quit DigUp from the tray and run the installer again." /SD IDOK
    Abort
    digup_runtime_cleaned:
  ${EndIf}
!macroend

; "Delete the application data" also takes DigUp's model (865 MB) and its index: the app keeps them in
; %LOCALAPPDATA%\DigUp, not in the data folders named after its identifier, which Tauri deletes. Never on an update.
!macro NSIS_HOOK_POSTUNINSTALL
  ${If} $DeleteAppDataCheckboxState = 1
  ${AndIf} $UpdateMode <> 1
    RMDir /r "$LOCALAPPDATA\DigUp\Models"
    RMDir /r "$LOCALAPPDATA\DigUp\index"
    RMDir "$LOCALAPPDATA\DigUp"
  ${EndIf}
!macroend

!macro NSIS_HOOK_POSTINSTALL
  IfFileExists "$INSTDIR\copilot\register.ps1" 0 digup_identity_done
    Push $0
    Push $1
    StrCpy $1 "$SYSDIR\WindowsPowerShell\v1.0\powershell.exe"
    ; NSIS is normally a 32-bit process; Sysnative avoids WOW64 redirection to 32-bit PowerShell.
    IfFileExists "$WINDIR\Sysnative\WindowsPowerShell\v1.0\powershell.exe" 0 +2
      StrCpy $1 "$WINDIR\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
    nsExec::ExecToLog '"$1" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$INSTDIR\copilot\register.ps1" -InstallRoot "$INSTDIR"'
    Pop $0
    Pop $1
    Pop $0
  digup_identity_done:
!macroend

!macro NSIS_HOOK_PREUNINSTALL
  ${If} $UpdateMode <> 1
    IfFileExists "$INSTDIR\copilot\register.ps1" 0 digup_identity_uninstalled
      Push $0
      Push $1
      StrCpy $1 "$SYSDIR\WindowsPowerShell\v1.0\powershell.exe"
      IfFileExists "$WINDIR\Sysnative\WindowsPowerShell\v1.0\powershell.exe" 0 +2
        StrCpy $1 "$WINDIR\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
      nsExec::ExecToLog '"$1" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$INSTDIR\copilot\register.ps1" -InstallRoot "$INSTDIR" -Uninstall'
      Pop $0
      Pop $1
      Pop $0
    digup_identity_uninstalled:
  ${EndIf}
!macroend
