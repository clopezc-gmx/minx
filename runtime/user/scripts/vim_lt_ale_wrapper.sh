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
MODE="server"    # default mode: server
LANGUAGE="en-US" # default language

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

# Optional language override
[[ -n "$2" ]] && LANGUAGE="$2"

# ------------------------------
# Helper: Compute line and column from character offset
# ------------------------------
compute_line_col() {
	local text="$1"
	local offset="$2"
	local line=1
	local col=1

	# Loop through text up to the offset
	for ((i = 0; i < offset; i++)); do
		char="${text:i:1}"
		if [[ "$char" == $'\n' ]]; then
			((line++))
			col=1
		else
			((col++))
		fi
	done

	echo "$line $col"
}

# ------------------------------
# Preprocess the text by removing backtick content
# ------------------------------
preprocess_text() {
	# Hard-coded flag to determine whether to remove backtick content
	remove_backtick_content=1

	if [[ $remove_backtick_content -eq 1 ]]; then
		# Use Perl to replace each character inside backticks with an asterisk
		modified_content=$(perl -0777 -pe 's/`([^`]+)`/sprintf("`%*s`", length($1), "*" x length($1))/ge' "$1")
	else
		# no processing
		modified_content=$(cat "$1")
	fi

	# Output the final processed content
	echo "$modified_content"
}

# ------------------------------
# Run LanguageTool via server
# ------------------------------
run_server() {
	# Read the entire file content once
	local content
	content=$(preprocess_text "$FILE")

	# Send the processed content to LanguageTool server
	local response
	response=$(
		curl -s -X POST "$LT_SERVER_URL" \
			-d "language=$LANGUAGE" \
			--data-urlencode "text=$content"
	)

	# Iterate over each match
	local i=1
	jq -c '.matches[]' <<<"$response" | while read -r match; do
		local offset length msg rule line col marker
		offset=$(jq '.offset' <<<"$match")
		length=$(jq '.length' <<<"$match")
		msg=$(jq -r '.message' <<<"$match")
		rule=$(jq -r '.rule.id' <<<"$match")

		# Compute the line/column of the error
		read -r line col < <(compute_line_col "$content" "$offset")

		((length < 1)) && length=1 # Default to 1 if length is 0
		marker=$(printf '%*s' "$length" '' | tr ' ' '^')

		# Output in ALE-friendly format
		echo "$i.) Line $line, column $col, Rule ID: $rule"
		echo "Message: $msg"
		echo "  $marker"
		echo ""
		((i++))
	done
}

# ------------------------------
# Run LanguageTool via jar
# ------------------------------
run_jar() {
	# Read the entire file content once
	local content
	content=$(preprocess_text "$FILE")

	# Run LanguageTool directly via jar
	echo "$content" | java -cp "$LT_JAR" org.languagetool.commandline.Main \
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
