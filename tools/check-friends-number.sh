#!/usr/bin/env bash
# Fails when Shenzhen Friends changed after its helper build number was last raised.
#
#   tools/check-friends-number.sh [<commit>]      (default HEAD)
#
# The helper build number is YYMMDDBB from MAC_VERSION and MAC_BUILD in apps/pdf/portable/Makefile. Every app embeds
# the same helper and a running helper hands over only to a higher number, so two different Friends builds must never
# carry the same one (docs/FRIENDS.md). This finds the last commit that changed MAC_VERSION or MAC_BUILD and lists the
# commits after it that changed Friends code: apps/pdf/portable/friends, apart from its docs, tests and Markdown.
# Release jobs run it before they build.
#
# When this repository was formed, Friends had already changed a good deal since the number was last raised (26.10.11
# build 1), so the check fails until the next ShenzhenPDF release is prepared: that release raises MAC_BUILD (or
# MAC_VERSION) and clears it. Prepare it before releasing Shenzhen Files or Shenzhen 3D.
set -euo pipefail

commit=${1:-HEAD}
root=$(git rev-parse --show-toplevel)
makefile=apps/pdf/portable/Makefile
friends=apps/pdf/portable/friends

version=$(git -C "$root" show "$commit:$makefile" | awk '$1 == "MAC_VERSION" && $2 == "?=" && !n++ { print $3 }')
build=$(git -C "$root" show "$commit:$makefile" | awk '$1 == "MAC_BUILD" && $2 == "?=" && !n++ { print $3 }')
number=$(echo "$version $build" | awk '{ split($1, v, "."); printf "%02d%02d%02d%02d", v[1] % 100, v[2], v[3], $2 }')

raised=$(git -C "$root" log -1 --format=%H -G'^MAC_(VERSION|BUILD) \?= ' "$commit" -- "$makefile")
[ -n "$raised" ] || { echo "error: no commit sets MAC_VERSION or MAC_BUILD in $makefile" >&2; exit 2; }

changes=$(git -C "$root" log --format='  %h %s' "$raised..$commit" -- "$friends" \
  ":(exclude)$friends/docs" ":(exclude)$friends/tests" ":(exclude)$friends/*.md" ":(exclude)$friends/**/*.md")
if [ -n "$changes" ]; then
  echo "Friends changed after its helper build number was last raised to $number" \
    "($(git -C "$root" log -1 --format='%h %s' "$raised")):"
  count=$(printf '%s\n' "$changes" | wc -l | tr -d ' ')
  printf '%s\n' "$changes" | sed -n 1,20p
  [ "$count" -le 20 ] || echo "  ... $count commits in all"
  echo "Raise it first: prepare a ShenzhenPDF release (apps/pdf/portable/cut-release.sh --prepare-only), which sets a"
  echo "new MAC_VERSION or MAC_BUILD. Do this before releasing any app, even if the ShenzhenPDF release is published later."
  exit 1
fi
echo "Friends helper build number $number covers Friends at $(git -C "$root" rev-parse --short "$commit")."
