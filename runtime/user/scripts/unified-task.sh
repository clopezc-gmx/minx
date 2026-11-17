#!/usr/bin/env bash
set -euo pipefail
msg=$(mktemp)
trap 'rm -f "$msg"' EXIT
cat >"$msg"
mid=$(grep -m1 -i '^message-id:' "$msg" | sed -E 's/^[^:]*:[[:space:]]*<?([^> ]*)>?.*/\1/')
if [ "$(notmuch count "id:$mid and tag:gmail")" -gt 0 ]; then
	a=gmail
elif [ "$(notmuch count "id:$mid and tag:gmx")" -gt 0 ]; then
	a=gmx
else
	echo "unknown account"
	exit 1
fi
"$MINX_INSTALLTION_DIR/runtime/user/scripts/neomutt_helper.sh" --mail-to-task -a "$a" <"$msg"
