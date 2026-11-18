#!/usr/bin/env bash
set -euo pipefail

msg=$(mktemp)
trap 'rm -f "$msg"' EXIT
cat >"$msg"

# Message-ID from the top-level headers only
mid=$(sed -n '1,/^$/p' "$msg" | grep -m1 -i '^message-id:' |
	sed -E 's/^[^:]*:[[:space:]]*<?([^> ]*)>?.*/\1/' || true)

if [ -z "$mid" ]; then
	echo "no Message-ID" >&2
	exit 1
fi

if [ "$(notmuch count "id:$mid and tag:gmail")" -gt 0 ]; then
	a=gmail
elif [ "$(notmuch count "id:$mid and tag:gmx")" -gt 0 ]; then
	a=gmx
else
	echo "unknown account" >&2
	exit 1
fi

"$MINX_INSTALLATION_DIR/runtime/user/scripts/neomutt_helper.sh" --mail-to-task -a "$a" <"$msg"
