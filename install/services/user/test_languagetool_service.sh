#!/usr/bin/env bash
#
# MINX - LanguageTool Service Health Check
#
# File: test_languagetool_service.sh
#
# Usage:
#   ./test_languagetool_service.sh
#
# Read-only: does not start, stop, restart or modify services.
#

set -uo pipefail

SERVICE_NAME="languagetool.service"
HOST="127.0.0.1"
PORT=8085
ENDPOINT="http://${HOST}:${PORT}/v2/check"

PASS=0
WARN=0
FAIL=0

pass() {
	printf '\033[0;32m[PASS]\033[0m %s\n' "$1"
	((PASS += 1))
}

warn() {
	printf '\033[0;33m[WARN]\033[0m %s\n' "$1"
	((WARN += 1))
}

fail() {
	printf '\033[0;31m[FAIL]\033[0m %s\n' "$1"
	((FAIL += 1))
}

echo
echo "========================================"
echo "MINX LanguageTool Health Check"
echo "========================================"
echo

# 1. Check systemd service.

echo "==> Checking systemd service..."

if ! systemctl --user show "$SERVICE_NAME" >/dev/null 2>&1; then
	fail "Cannot inspect $SERVICE_NAME"
	exit 1
fi

ACTIVE_STATE="$(systemctl --user show "$SERVICE_NAME" \
	-p ActiveState --value)"

if [[ "$ACTIVE_STATE" == "active" ]]; then
	pass "Service is active"
else
	fail "Service state: $ACTIVE_STATE"
fi

# 2. Check listening port.

echo
echo "==> Checking port $PORT..."

if ! command -v ss >/dev/null 2>&1; then
	warn "ss command not available"
else
	if ss -ltnH "sport = :$PORT" | grep -q .; then
		pass "TCP port $PORT is listening"
	else
		fail "TCP port $PORT is not listening"
	fi
fi

# 3. Check HTTP endpoint.

echo
echo "==> Testing LanguageTool HTTP endpoint..."

if ! command -v curl >/dev/null 2>&1; then
	fail "curl is not installed"
	exit 1
fi

RESPONSE_FILE="$(mktemp)"
HTTP_STATUS=""

trap 'rm -f "$RESPONSE_FILE"' EXIT

HTTP_STATUS="$(curl -sS \
	--connect-timeout 3 \
	--max-time 15 \
	-o "$RESPONSE_FILE" \
	-w '%{http_code}' \
	-X POST \
	--data-urlencode "text=This is MPI and this is xyzclopez." \
	--data-urlencode "language=en-US" \
	"$ENDPOINT" 2>/dev/null)" || HTTP_STATUS="000"

if [[ "$HTTP_STATUS" == "200" ]]; then
	pass "LanguageTool returned HTTP 200"
else
	fail "HTTP request failed (status: ${HTTP_STATUS:-unknown})"
fi

# 4. Validate response.

echo
echo "==> Validating LanguageTool response..."

if [[ ! -s "$RESPONSE_FILE" ]]; then

	fail "Empty response"

elif command -v jq >/dev/null 2>&1; then

	if jq -e '.matches | type == "array"' \
		"$RESPONSE_FILE" >/dev/null 2>&1; then

		pass "Valid LanguageTool JSON response"

		if jq -e \
			'[.matches[] | select(.context.text != null)] | length > 0' \
			"$RESPONSE_FILE" >/dev/null 2>&1; then

			pass "LanguageTool returned spelling/grammar matches"

			echo
			echo "Detected matches:"

			jq '.matches[] | {
                offset,
                length,
                message,
                shortMessage,
                rule: .rule.id,
                text: .context.text
            }' "$RESPONSE_FILE"

		else
			warn "No matches with context were returned"
		fi

	else
		fail "Invalid LanguageTool JSON response"
	fi

else
	warn "jq unavailable; JSON validation skipped"
	cat "$RESPONSE_FILE"
fi

# 5. Recent service logs.

echo
echo "==> Recent service logs..."

if journalctl --user -u "$SERVICE_NAME" \
	-n 20 --no-pager 2>/dev/null; then
	:
else
	warn "Service logs unavailable"
fi

# 6. Summary.

echo
echo "========================================"
echo "LANGUAGETOOL HEALTH CHECK SUMMARY"
echo "========================================"

echo "PASS: $PASS"
echo "WARN: $WARN"
echo "FAIL: $FAIL"

echo

if ((FAIL > 0)); then
	echo "RESULT: LanguageTool health check failed."
	exit 1
elif ((WARN > 0)); then
	echo "RESULT: LanguageTool check completed with warnings."
	exit 0
else
	echo "RESULT: LanguageTool is healthy."
	exit 0
fi
