#!/bin/sh
# Refuses a Node image that is not pinned by digest (ADR 0005 § Runtime). node:sqlite is still experimental in
# the 22 line, so a rebuild must never pick up another Node silently: the Dockerfile runs this before anything else
# and the build stops here unless NODE_IMAGE ends in @sha256:<64 hex digits>.
#
#   sh deploy/check-node-image.sh "node:22-alpine@sha256:<digest>"
case "$1" in
    *@sha256:*) digest=${1##*@sha256:} ;;
    *) digest= ;;
esac
if [ "${#digest}" -ne 64 ] || ! printf '%s' "$digest" | grep -Eq '^[0-9a-f]{64}$'; then
    echo "NODE_IMAGE must be pinned by digest, such as node:22-alpine@sha256:<64 hex digits>; got '$1'." >&2
    echo "Look it up with: docker buildx imagetools inspect node:22-alpine (DEPLOY.md, \"Pin the Node image\")." >&2
    exit 1
fi
