; Shenzhen Friends in the Windows installer (docs/FRIENDS.md § Tauri, ADR 0015 § 14, § 15). The app runs the helper
; from a per-user copy, never from here, so this install replaces szfriends-helper.exe even while a helper runs. Once
; the new one is in place, it asks a running older helper to step aside through the protocol's handover: that helper
; finishes what it is doing and leaves, and the next app to open Friends starts the new one. Nothing is stopped by
; name or process id, and a helper that is the same build or newer is left alone.
;
; Friends' firewall rule: people on the same private network can find this PC only when Windows Firewall lets them
; connect to Friends. This per-user install cannot add a rule itself, so it asks Windows once (User Account Control
; shows netsh, from Microsoft); declined, Friends still reaches every friend over the internet, and Nearby offers
; the same step again (Allow on Private Networks). The rule's ports and name are szfriends-core's
; (nearby/firewall.rs: FRIENDS_PORTS, RULE_NAME, rule_arguments); windows-installer-check.mjs checks they match.
!define SZF_RULE_NAME "Shenzhen Friends (people nearby)"
!define SZF_RULE_ADD 'advfirewall firewall add rule name="${SZF_RULE_NAME}" dir=in action=allow protocol=TCP localport=48250-48257 remoteip=localsubnet profile=private,domain'
!define SZF_ASKED_KEY "Software\shenzhen3d\Shenzhen Friends"

!macro NSIS_HOOK_POSTINSTALL
  nsExec::Exec '"$INSTDIR\szfriends-helper.exe" --handover'
  Pop $0
  ; Asked once per person: an update, or a run after a "No", does not ask again (Nearby can).
  nsExec::Exec '"$SYSDIR\netsh.exe" advfirewall firewall show rule name="${SZF_RULE_NAME}"'
  Pop $0
  ReadRegStr $1 HKCU "${SZF_ASKED_KEY}" "FirewallAsked"
  IfSilent szf_rule_done
  StrCmp $0 "0" szf_rule_done
  StrCmp $1 "1" szf_rule_done
  WriteRegStr HKCU "${SZF_ASKED_KEY}" "FirewallAsked" "1"
  ExecShellWait "runas" "$SYSDIR\netsh.exe" '${SZF_RULE_ADD}' SW_HIDE
  szf_rule_done:
!macroend

!macro NSIS_HOOK_POSTUNINSTALL
  ; The rule goes with the app, when someone removes it by hand (an update's silent run keeps it).
  IfSilent szf_unrule_done
  nsExec::Exec '"$SYSDIR\netsh.exe" advfirewall firewall show rule name="${SZF_RULE_NAME}"'
  Pop $0
  StrCmp $0 "0" 0 szf_unrule_done
  ExecShellWait "runas" "$SYSDIR\netsh.exe" 'advfirewall firewall delete rule name="${SZF_RULE_NAME}"' SW_HIDE
  DeleteRegValue HKCU "${SZF_ASKED_KEY}" "FirewallAsked"
  szf_unrule_done:
!macroend
