#!/usr/bin/env bash
# Checks built apps for anything that would give one of them a Friends identity of its own on a Mac.
#
#   tools/check-friends-one-home.sh <ShenzhenPDF.app> <Shenzhen Files.app> <Shenzhen 3D.app>   (the apps of one release)
#
# ShenzhenPDF, Shenzhen Files and Shenzhen 3D share one helper, one identity and one history per Mac user: the helper
# keeps them in ~/Library/Application Support/Shenzhen Friends and its key in the login keychain under the service
# "Shenzhen Friends", readable by any helper with the same designated requirement (identifier and team). A build breaks
# that when, for any app given:
#   - it embeds no helper at Contents/Helpers/Shenzhen Friends.app, or its helper differs from the others' (another
#     CDHash: another build of the code, another identifier or team, so another keychain reader);
#   - the app or its helper is sandboxed (its home becomes a container, so its Friends home is another);
#   - its Info.plist sets HOME, CFFIXED_USER_HOME or any SZFRIENDS_* variable through LSEnvironment;
#   - its helper's build number keys disagree (CFBundleVersion and SZFriendsBuildNumber): the hand-over to a newer
#     helper reads them;
#   - a signed app's helper is not signed by the same team as the app.
# Reads only; changes nothing and starts nothing. Exits 1 with one line per problem.
set -euo pipefail

[ "$#" -ge 1 ] || { sed -n '3,4p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

problems=0
problem() {
  echo "$1: $2"
  problems=$((problems + 1))
}

entitlement() { # <path> <key>: the value of a boolean entitlement, "true" or ""
  local xml
  xml=$(codesign -d --entitlements - --xml "$1" 2>/dev/null || true)
  [ -n "$xml" ] && printf '%s' "$xml" | plutil -extract "$2" raw -o - - 2>/dev/null || true
}

field() { # <path> <field>: one field of codesign -dvvv
  local details
  details=$(codesign -dvvv "$1" 2>&1 || true)
  printf '%s\n' "$details" | awk -F= -v f="$2" '$1 == f && !seen++ { print $2 }'
}

first_cdhash=""
first_app=""
for app in "$@"; do
  name=$(basename "$app")
  helper="$app/Contents/Helpers/Shenzhen Friends.app"
  if [ ! -x "$helper/Contents/MacOS/Shenzhen Friends" ]; then
    problem "$name" "embeds no helper at Contents/Helpers/Shenzhen Friends.app"
    continue
  fi
  cdhash=$(field "$helper" CDHash)
  if [ -z "$first_cdhash" ]; then
    first_cdhash=$cdhash
    first_app=$name
  elif [ "$cdhash" != "$first_cdhash" ]; then
    problem "$name" "its helper (CDHash $cdhash) is not $first_app's ($first_cdhash)"
  fi
  identifier=$(field "$helper" Identifier)
  [ "$identifier" = "com.intuition.shenzhenfriends" ] ||
    problem "$name" "its helper's identifier is $identifier, not com.intuition.shenzhenfriends"
  app_team=$(field "$app" TeamIdentifier)
  helper_team=$(field "$helper" TeamIdentifier)
  if [ -n "$app_team" ] && [ "$app_team" != "not set" ] && [ "$helper_team" != "$app_team" ]; then
    problem "$name" "its helper is signed by team ${helper_team:-none}, the app by $app_team"
  fi
  for signed in "$app" "$helper"; do
    [ "$(entitlement "$signed" com.apple.security.app-sandbox)" = "true" ] &&
      problem "$name" "$(basename "$signed") is sandboxed: its home would be a container"
  done
  environment=$(plutil -extract LSEnvironment json -o - "$app/Contents/Info.plist" 2>/dev/null || true)
  for key in $(printf '%s' "$environment" | /usr/bin/python3 -c \
    'import json, sys; text = sys.stdin.read(); print(" ".join(json.loads(text)) if text else "")'); do
    case "$key" in
      HOME | CFFIXED_USER_HOME | SZFRIENDS_*) problem "$name" "LSEnvironment sets $key" ;;
    esac
  done
  version=$(plutil -extract CFBundleVersion raw -o - "$helper/Contents/Info.plist" 2>/dev/null || true)
  number=$(plutil -extract SZFriendsBuildNumber raw -o - "$helper/Contents/Info.plist" 2>/dev/null || true)
  [ -n "$version" ] && [ "$version" = "$number" ] ||
    problem "$name" "its helper says build ${version:-none} (CFBundleVersion), ${number:-none} (SZFriendsBuildNumber)"
done

if [ "$problems" -gt 0 ]; then
  exit 1
fi
echo "One Friends home: $# apps, one helper (CDHash $first_cdhash), none sandboxed or redirected."
