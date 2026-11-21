#!/usr/bin/env bash
#
# MINX - Shutdown Services Diagnostic
#
# File: 10_inspect_shutdown_services.sh
#
# Usage:
#   ./10_inspect_shutdown_services.sh
#   ./10_inspect_shutdown_services.sh --test
#   ./10_inspect_shutdown_services.sh --logs
#   ./10_inspect_shutdown_services.sh --help
#
# Default mode is READ-ONLY.
# --test executes each shutdown hook through systemd.
# --logs displays recent journal entries.
#
# IMPORTANT:
# --test does NOT reboot, poweroff, or halt the machine.
#

set -uo pipefail

readonly SERVICE_TEMPLATE="/etc/systemd/system/shutdown-pre@.service"
readonly HOOK="/opt/minx/runtime/user/hooks/system_shutdown_pre.sh"
readonly SLEEP_HOOK="/lib/systemd/system-sleep/sleep_dispatch.sh"

TARGET_USER="${SUDO_USER:-clopez}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

RUN_TESTS=0
SHOW_LOGS=0

PASS=0
WARN=0
FAIL=0

for arg in "$@"; do
	case "$arg" in
	--test) RUN_TESTS=1 ;;
	--logs) SHOW_LOGS=1 ;;
	--help)
		echo "Usage: $0 [--test] [--logs]"
		exit 0
		;;
	*)
		echo "Unknown argument: $arg"
		exit 1
		;;
	esac
done

if [[ $EUID -ne 0 ]]; then
	echo "Please run as root:"
	echo "sudo $0 $*"
	exit 1
fi

if [[ -z "$TARGET_HOME" ]]; then
	echo "[FAIL] Cannot determine home for $TARGET_USER"
	exit 1
fi

log() {
	printf '\n\033[1;36m=> %s\033[0m\n' "$1"
}

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

inspect_file() {
	local file="$1"

	if [[ -e "$file" ]]; then
		pass "Exists: $file"
		ls -l "$file"
	else
		fail "Missing: $file"
	fi
}

inspect_unit() {
	local instance="$1"
	local unit="shutdown-pre@${instance}.service"

	log "Inspecting $unit"

	if ! systemctl cat "$unit" >/dev/null 2>&1; then
		fail "$unit cannot be loaded"
		return
	fi

	pass "$unit loaded"

	systemctl show "$unit" \
		-p LoadState \
		-p ActiveState \
		-p SubState \
		-p UnitFileState \
		-p User \
		-p Group \
		-p WorkingDirectory \
		-p ExecStart \
		-p Environment \
		-p Before \
		-p After \
		-p Requires \
		-p Wants \
		-p Conflicts \
		-p WantedBy

	echo
	systemctl status "$unit" --no-pager || true
}

inspect_target() {
	local target="$1"
	local instance="$2"

	local link="/etc/systemd/system/${target}.target.wants/shutdown-pre@${instance}.service"

	log "Inspecting ${target}.target"

	if [[ -L "$link" ]]; then
		local destination
		destination="$(readlink -f "$link")"

		if [[ "$destination" == "$SERVICE_TEMPLATE" ]]; then
			pass "$link -> $destination"
		else
			fail "Unexpected symlink destination: $link -> $destination"
		fi
	else
		fail "Missing or invalid symlink: $link"
	fi

	systemctl list-dependencies "${target}.target" --no-pager || true
}

log "MINX Shutdown Diagnostic"

echo "Date:        $(date)"
echo "Hostname:    $(hostname)"
echo "Target user: $TARGET_USER"
echo "Target home: $TARGET_HOME"
echo "Mode:        $([[ $RUN_TESTS -eq 1 ]] && echo TEST || echo READ-ONLY)"

log "1. Systemd service template"

inspect_file "$SERVICE_TEMPLATE"

if systemd-analyze verify "$SERVICE_TEMPLATE"; then
	>-pass "Systemd unit syntax verification"
else
	>-fail "Systemd unit syntax verification"
fi

log "2. Shutdown hook"

inspect_file "$HOOK"

if [[ -x "$HOOK" ]]; then
	pass "Shutdown hook executable"
else
	fail "Shutdown hook is not executable"
fi

if [[ -f "$HOOK" ]]; then
	stat -c 'Owner: %U:%G | Permissions: %A | Size: %s bytes' "$HOOK"

	if [[ "$(stat -c %U "$HOOK")" == "$TARGET_USER" ]]; then
		pass "Hook owned by target user"
	else
		warn "Hook is not owned by $TARGET_USER"
	fi

	if head -n 1 "$HOOK" | grep -q '^#!'; then
		pass "Hook has a shebang"
	else
		warn "Hook has no shebang"
	fi
fi

log "3. Sleep dispatch hook"

inspect_file "$SLEEP_HOOK"

if [[ -x "$SLEEP_HOOK" ]]; then
	pass "Sleep dispatch hook executable"
else
	warn "Sleep dispatch hook is not executable"
fi

log "4. Target user environment"

id "$TARGET_USER"

echo "HOME=$TARGET_HOME"

getent passwd "$TARGET_USER"

log "5. Shutdown service instances"

inspect_unit reboot
inspect_unit poweroff
inspect_unit halt

log "6. Target dependency mappings"

inspect_target reboot reboot
inspect_target poweroff poweroff
inspect_target halt halt

log "7. Mount information"

findmnt /
findmnt /home || warn "/home is not currently a separate mounted filesystem"

systemctl status home.mount --no-pager 2>/dev/null || true

log "8. Shutdown ordering"

for instance in reboot poweroff halt; do
	unit="shutdown-pre@${instance}.service"

	echo
	echo "[$unit]"

	systemctl show "$unit" \
		-p Before \
		-p After \
		-p Requires \
		-p Conflicts
done

log "9. Recent journal entries"

if [[ $SHOW_LOGS -eq 1 ]]; then
	journalctl \
		-u 'shutdown-pre@reboot.service' \
		-u 'shutdown-pre@poweroff.service' \
		-u 'shutdown-pre@halt.service' \
		-n 100 --no-pager
else
	echo "Use --logs to display recent journal entries."
fi

log "10. Optional execution tests"

if [[ $RUN_TESTS -eq 1 ]]; then

	echo
	echo "WARNING: This executes your actual shutdown hooks."
	echo "It does NOT perform a system shutdown."

	for instance in reboot poweroff halt; do

		unit="shutdown-pre@${instance}.service"

		echo
		echo "Testing: $unit"

		if systemctl start "$unit"; then
			pass "Execution successful: $unit"
		else
			fail "Execution failed: $unit"
		fi

		systemctl status "$unit" --no-pager || true

		journalctl -u "$unit" -n 30 --no-pager
	done

else
	echo "Execution tests skipped."
	echo "Use --test to execute the hooks."
fi

log "FINAL SUMMARY"

echo
echo "PASS: $PASS"
echo "WARN: $WARN"
echo "FAIL: $FAIL"

echo

if ((FAIL > 0)); then
	echo "RESULT: Problems detected. Review FAIL entries."
	exit 1
elif ((WARN > 0)); then
	echo "RESULT: Completed with warnings."
	exit 0
else
	echo "RESULT: All diagnostic checks passed."
	exit 0
fi
