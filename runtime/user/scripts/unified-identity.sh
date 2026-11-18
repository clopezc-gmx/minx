#!/usr/bin/env bash
set -euo pipefail

dir="$HOME/.config/neomutt/identities"

mid=$(grep -m1 -i '^message-id:' | sed -E 's/^[^:]*:[[:space:]]*<?([^> ]*)>?.*/\1/' || true)

if [ -n "$mid" ] && [ "$(notmuch count "id:$mid and tag:gmx")" -gt 0 ]; then
	id=gmx
else
	id=gmail
fi

cp "$dir/$id.rc" /tmp/neomutt-identity.rc
