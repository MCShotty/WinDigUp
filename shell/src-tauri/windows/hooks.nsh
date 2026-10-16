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
