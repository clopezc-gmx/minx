#!/usr/bin/env bash

# Define service name and port
SERVICE_NAME="languagetool.service"
PORT=8085

echo "==> Checking if port $PORT is open..."

if ss -tuln | grep -q ":$PORT"; then
	echo "[PASS] Port $PORT is open and the server is listening."
else
	echo "[FAIL] Port $PORT is not open. Service may not be running."
	exit 1
fi

echo "==> Testing LanguageTool server with MPI and an unknown word..."

RESPONSE=$(curl -sS -X POST \
	-d "text=This is MPI and this is xyzclopez." \
	-d "language=en-US" \
	http://localhost:8085/v2/check)

if [[ -z "$RESPONSE" ]]; then
	echo "[FAIL] No response from server."
	exit 1
fi

echo "[PASS] Server response received:"

if command -v jq >/dev/null 2>&1; then
	echo "$RESPONSE" | jq '.matches[] | {
		offset,
		length,
		message,
		shortMessage,
		rule: .rule.id,
		text: .context.text
	}'
else
	echo "$RESPONSE"
fi

echo "==> Displaying last 20 lines of user service logs..."

if journalctl --user -u "$SERVICE_NAME" -n 20 --no-pager >/dev/null 2>&1; then
	journalctl --user -u "$SERVICE_NAME" -n 20 --no-pager
else
	echo "[WARN] Logs not accessible or service not found in user journal."
fi

echo "==> Test complete."
