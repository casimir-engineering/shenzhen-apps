; Shenzhen Friends in the Windows installer (docs/FRIENDS.md § Tauri, ADR 0015 § 14). The app runs the helper from a
; per-user copy, never from here, so this install replaces szfriends-helper.exe even while a helper runs. Once the new
; one is in place, it asks a running older helper to step aside through the protocol's handover: that helper finishes
; what it is doing and leaves, and the next app to open Friends starts the new one. Nothing is stopped by name or
; process id, and a helper that is the same build or newer is left alone.
!macro NSIS_HOOK_POSTINSTALL
  nsExec::Exec '"$INSTDIR\szfriends-helper.exe" --handover'
  Pop $0
!macroend
