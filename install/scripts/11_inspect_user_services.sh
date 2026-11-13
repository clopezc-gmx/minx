#!/usr/bin/env bash
#
# MINX - User Services & Timers Diagnostic
#
# File: 11_inspect_user_services.sh
#
# Usage:
#   ./11_inspect_user_services.sh
#   ./11_inspect_user_services.sh --logs
#   ./11_inspect_user_services.sh --verify
#   ./11_inspect_user_services.sh --logs --verify
#   ./11_inspect_user_services.sh --unit-dir /path/to/services/user
#
# Read-only by default.
# Never starts, stops, restarts or enables services.
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARGET_USER="${USER:-$(id -un)}"
TARGET_HOME="${HOME}"

DEFAULT_UNIT_DIR="$SCRIPT_DIR/../services/user"

if [[ -d "$DEFAULT_UNIT_DIR" ]]; then
	UNIT_DIR="$(realpath "$DEFAULT_UNIT_DIR")"
else
	UNIT_DIR="$TARGET_HOME/.config/systemd/user"
fi

SHOW_LOGS=0
VERIFY=0

PASS=0
WARN=0
FAIL=0

# Parse arguments.

while [[ $# -gt 0 ]]; do
	case "$1" in
	--logs)
		SHOW_LOGS=1
		shift
		;;
	--verify)
		VERIFY=1
		shift
		;;
	--unit-dir)
		if [[ $# -lt 2 ]]; then
			echo "Missing directory after --unit-dir"
			exit 1
		fi
		UNIT_DIR="$2"
		shift 2
		;;
	--help)
		echo "Usage: $0 [--logs] [--verify] [--unit-dir DIR]"
		exit 0
		;;
	*)
		echo "Unknown argument: $1"
		exit 1
		;;
	esac
done

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

log() {
	printf '\n\033[1;36m=> %s\033[0m\n' "$1"
}

# Ensure execution as the actual user.

if [[ "$EUID" -eq 0 ]]; then
	echo "Do not run this script with sudo."
	echo "Run it as $TARGET_USER:"
	echo "./$(basename "$0")"
	exit 1
fi

if [[ ! -d "$UNIT_DIR" ]]; then
	echo "[FAIL] Unit directory does not exist:"
	echo "$UNIT_DIR"
	exit 1
fi

if ! systemctl --user show-environment >/dev/null 2>&1; then
	echo "[FAIL] Cannot connect to systemd user manager."
	echo "Check that your user session and DBus are running."
	exit 1
fi

shopt -s nullglob

FILES=("$UNIT_DIR"/*.service "$UNIT_DIR"/*.timer)

if [[ ${#FILES[@]} -eq 0 ]]; then
	echo "[FAIL] No service or timer files found in $UNIT_DIR"
	exit 1
fi

log "MINX User Services Diagnostic"

echo "Date:        $(date)"
echo "Hostname:    $(hostname)"
echo "Target user: $TARGET_USER"
echo "Target home: $TARGET_HOME"
echo "Unit dir:    $UNIT_DIR"
echo "Unit files:  ${#FILES[@]}"
echo "Mode:        READ-ONLY"

# 1. User systemd manager.

log "1. User systemd manager"

systemctl --user is-system-running || true

echo
systemctl --user show \
	-p Version \
	-p Virtualization \
	-p ControlGroup

# 2. Unit files.

log "2. Unit files"

for file in "${FILES[@]}"; do

	unit="$(basename "$file")"

	echo
	echo "[$unit]"

	if [[ -r "$file" ]]; then
		pass "Readable: $unit"
	else
		fail "Not readable: $unit"
		continue
	fi

	stat -c 'Owner: %U:%G | Permissions: %A | Size: %s bytes' "$file"

	if [[ "$(stat -c %U "$file")" == "$TARGET_USER" ]]; then
		pass "Correct owner: $unit"
	else
		warn "Unexpected owner: $unit"
	fi

	if [[ "$VERIFY" -eq 1 ]]; then
		if systemd-analyze --user verify "$file" 2>&1; then
			pass "Syntax verification: $unit"
		else
			fail "Syntax verification: $unit"
		fi
	fi

done

# 3. Loaded services and timers.

log "3. Loaded services and timers"

for file in "${FILES[@]}"; do

	unit="$(basename "$file")"

	echo
	echo "========================================"
	echo "$unit"
	echo "========================================"

	if ! systemctl --user show "$unit" >/dev/null 2>&1; then
		fail "Cannot inspect $unit"
		continue
	fi

	fragment="$(systemctl --user show "$unit" -p FragmentPath --value)"

	if [[ -z "$fragment" ]]; then
		fail "Unit not loaded: $unit"
		continue
	fi

	pass "Unit loaded: $unit"

	echo
	systemctl --user show "$unit" \
		-p LoadState \
		-p ActiveState \
		-p SubState \
		-p UnitFileState \
		-p FragmentPath \
		-p Description \
		-p User \
		-p Group \
		-p ExecStart \
		-p WorkingDirectory \
		-p Environment \
		-p Requires \
		-p Wants \
		-p After \
		-p Before \
		-p TriggeredBy \
		-p Triggers \
		-p Result \
		-p ExecMainCode \
		-p ExecMainStatus

	echo
	systemctl --user status "$unit" --no-pager || true

done

# 4. Timer schedule overview.

log "4. Timer schedule overview"

systemctl --user list-timers --all --no-pager

# 5. Timer-to-service relationships.

log "5. Timer-to-service relationships"

for file in "${FILES[@]}"; do

	[[ "$file" == *.timer ]] || continue

	timer="$(basename "$file")"
	service="${timer%.timer}.service"

	echo
	echo "Timer:  $timer"
	echo "Service: $service"

	if systemctl --user show "$timer" >/dev/null 2>&1; then
		pass "Timer recognized: $timer"
	else
		fail "Timer not recognized: $timer"
		continue
	fi

	if systemctl --user show "$service" >/dev/null 2>&1; then
		pass "Associated service recognized: $service"
	else
		warn "Associated service not found: $service"
	fi

	echo
	systemctl --user show "$timer" \
		-p Unit \
		-p TimersCalendar \
		-p TimersMonotonic \
		-p LastTriggerUSec \
		-p NextElapseUSecRealtime \
		-p NextElapseUSecMonotonic \
		-p ActiveState \
		-p SubState

done

# 6. Failed user units.

log "6. Failed user units"

FAILED_UNITS="$(systemctl --user --failed --no-legend --plain)"

if [[ -z "$FAILED_UNITS" ]]; then
	pass "No failed user units"
else
	fail "Failed user units detected"
	echo "$FAILED_UNITS"
fi

# 7. Service execution configuration.

log "7. Service execution configuration"

for file in "${FILES[@]}"; do

	[[ "$file" == *.service ]] || continue

	unit="$(basename "$file")"

	echo
	echo "[$unit]"

	systemctl --user show "$unit" \
		-p ExecStart \
		-p ExecStartPre \
		-p ExecStartPost \
		-p User \
		-p Group \
		-p WorkingDirectory \
		-p Environment \
		-p EnvironmentFiles \
		-p Restart \
		-p RestartUSec \
		-p TimeoutStartUSec \
		-p Result

done

# 8. User manager environment.

log "8. User manager environment"

echo "HOME=$HOME"
echo "USER=$USER"
echo "SHELL=$SHELL"
echo "PATH=$PATH"

systemctl --user show-environment

# 9. Recent journal entries.

log "9. Recent journal entries"

if [[ "$SHOW_LOGS" -eq 1 ]]; then

	for file in "${FILES[@]}"; do

		unit="$(basename "$file")"

		echo
		echo "[$unit]"

		journalctl --user -u "$unit" \
			-n 30 --no-pager

	done

else
	echo "Use --logs to inspect recent logs."
fi

# 10. Timer activation and service execution summary.

log "10. Timer activation and service execution summary"

for file in "${FILES[@]}"; do

	unit="$(basename "$file")"

	echo
	echo "[$unit]"

	systemctl --user show "$unit" \
		-p ActiveState \
		-p SubState \
		-p Result \
		-p LastTriggerUSec \
		-p NextElapseUSecRealtime \
		-p ExecMainStartTimestamp \
		-p ExecMainExitTimestamp

done

# 11. Application health checks.

log "11. Application health checks"

LANGUAGETOOL_TEST="$SCRIPT_DIR/test_languagetool_service.sh"

if [[ -x "$LANGUAGETOOL_TEST" ]]; then

	if [[ -f "$UNIT_DIR/languagetool.service" ]]; then

		if "$LANGUAGETOOL_TEST"; then
			pass "LanguageTool application health check"
		else
			fail "LanguageTool application health check"
		fi

	else
		warn "LanguageTool unit not found; health check skipped"
	fi

else
	warn "LanguageTool health-check script not found or not executable"
fi

# FINAL SUMMARY.

log "FINAL SUMMARY"

echo
echo "Unit files: ${#FILES[@]}"
echo "PASS:       $PASS"
echo "WARN:       $WARN"
echo "FAIL:       $FAIL"

echo

if ((FAIL > 0)); then
	echo "RESULT: Problems detected."
	exit 1
elif ((WARN > 0)); then
	echo "RESULT: Completed with warnings."
	exit 0
else
	echo "RESULT: All diagnostic checks passed."
	exit 0
fi
