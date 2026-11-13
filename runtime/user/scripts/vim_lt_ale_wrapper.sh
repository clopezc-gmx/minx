#!/bin/bash
# =========================================
# vim_lt_ale_wrapper.sh - LanguageTool wrapper for ALE in Vim
#
# Checks a file for grammar and style issues using LanguageTool.
# Supports either the command-line jar or a running LanguageTool server.
# Outputs in a format compatible with ALE.
# =========================================

LT_ROOT="/opt/minx/languagetool/LanguageTool-6.9-SNAPSHOT/"

# ------------------------------
# Configuration
# ------------------------------
LT_JAR="$LT_ROOT/languagetool-commandline.jar"
LT_SERVER_URL="http://localhost:8085/v2/check"
MODE="server"
LANGUAGE="en-US"

# ------------------------------
# Parse mode from first argument
# ------------------------------
case "$1" in
--jar)
	MODE="jar"
	shift
	;;
--server)
	MODE="server"
	shift
	;;
esac

# ------------------------------
# File to check
# ------------------------------
FILE="$1"

[[ -f "$FILE" ]] || {
	echo "File not found: $FILE" >&2
	exit 1
}

[[ -n "$2" ]] && LANGUAGE="$2"

# ------------------------------
# Find repository ignore file
# ------------------------------
FILE_DIR=$(cd "$(dirname "$FILE")" && pwd)

GIT_ROOT=$(git -C "$FILE_DIR" rev-parse --show-toplevel 2>/dev/null)

IGNORE_FILE=""

if [[ -n "$GIT_ROOT" ]]; then
	IGNORE_FILE="$GIT_ROOT/.languagetool-ignore"
fi

# ------------------------------
# Preprocess Markdown
# ------------------------------
preprocess_text() {
	local remove_backtick_content=1

	if [[ $remove_backtick_content -eq 1 ]]; then
		perl -0777 -pe \
			's/`([^`]+)`/sprintf("`%*s`", length($1), "*" x length($1))/ge' \
			"$1"
	else
		cat "$1"
	fi
}

# ------------------------------
# Run LanguageTool via server
# ------------------------------
run_server() {
	local tmp_content tmp_response

	tmp_content=$(mktemp)
	tmp_response=$(mktemp)

	trap 'rm -f "$tmp_content" "$tmp_response"' RETURN

	preprocess_text "$FILE" >"$tmp_content"

	if ! curl -fsS -X POST "$LT_SERVER_URL" \
		--data-urlencode "language=$LANGUAGE" \
		--data-urlencode "text@$tmp_content" \
		-o "$tmp_response"; then
		echo "LanguageTool server call failed." >&2
		return 1
	fi

	python3 - "$tmp_content" "$tmp_response" "$IGNORE_FILE" <<'PY'
import json
import os
import sys


content_file, response_file, ignore_file = sys.argv[1:]

with open(content_file, encoding="utf-8") as f:
    content = f.read()

with open(response_file, encoding="utf-8") as f:
    response = json.load(f)

if not isinstance(response, dict) or not isinstance(response.get("matches"), list):
    print("Invalid LanguageTool response", file=sys.stderr)
    sys.exit(1)

# Load repository-specific ignored words.
ignored_words = set()

if ignore_file and os.path.isfile(ignore_file):
    with open(ignore_file, encoding="utf-8") as f:
        ignored_words = {
            line.strip().casefold()
            for line in f
            if line.strip() and not line.lstrip().startswith("#")
        }


def utf16_to_python_index(text, offset):
    """Convert LanguageTool UTF-16 offsets to Python indices."""
    units = 0

    for index, char in enumerate(text):
        if units >= offset:
            return index

        units += 2 if ord(char) > 0xFFFF else 1

    return len(text)


def is_ignored(match):
    rule = match.get("rule", {}).get("id", "")

    # Only ignore spelling errors.
    if not rule.startswith("MORFOLOGIK_RULE_"):
        return False

    offset = match.get("offset")
    length = match.get("length")

    if not isinstance(offset, int) or not isinstance(length, int):
        return False

    start = utf16_to_python_index(content, offset)
    end = utf16_to_python_index(content, offset + length)

    word = content[start:end].casefold()

    return word in ignored_words


def get_line_col(text, index):
    prefix = text[:index]
    line = prefix.count("\n") + 1
    column = len(prefix.rsplit("\n", 1)[-1]) + 1

    return line, column


i = 1

for match in response["matches"]:
    if is_ignored(match):
        continue

    offset = match.get("offset")
    length = match.get("length", 1)
    message = match.get("message", "")
    rule = match.get("rule", {}).get("id", "")

    if not isinstance(offset, int):
        continue

    index = utf16_to_python_index(content, offset)
    line, col = get_line_col(content, index)

    marker = "^" * max(1, length)

    print(f"{i}.) Line {line}, column {col}, Rule ID: {rule}")
    print(f"Message: {message}")
    print(f"  {marker}")
    print()

    i += 1
PY
}

# ------------------------------
# Run LanguageTool via jar
# ------------------------------
run_jar() {
	preprocess_text "$FILE" |
		java -cp "$LT_JAR" org.languagetool.commandline.Main \
			-l "$LANGUAGE" -
}

# ------------------------------
# Execute selected mode
# ------------------------------
if [[ "$MODE" == "server" ]]; then
	run_server
else
	run_jar
fi
