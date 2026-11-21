#!/usr/bin/env bash
# shellcheck disable=SC1091 # path is resolved at runtime.

set -euo pipefail

# Run as root
if ((EUID != 0)); then
	printf '%s\n' "=> Run \"$0\" as ROOT." >&2
	exit 1
fi

# Load configuration
# ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
if [[ -z "${__MINX_CONF_LOADED:-}" ]]; then
	source "$SCRIPT_DIR/../config/minx.conf" || exit 1
	__MINX_CONF_LOADED=1
fi

# Set/check installation type
INSTALLATION_TYPE=${1:-"desktop"}

FILE="$MXC_INSTALLATION_DIR/info/installation_type"

if [[ -f "$FILE" ]]; then
	if [[ "$(cat "$FILE")" != "$INSTALLATION_TYPE" ]]; then
		printf 'ERROR:\nIt seems like you want to have a different installation.\nRemove the entire MINX installation and reinstall it again, otherwise things might not work properly.\n' >&2
		exit 1
	fi
else
	mkdir -p "$MXC_INSTALLATION_DIR/info"
	echo "$INSTALLATION_TYPE" >"$FILE"
fi

# ----

source "$SCRIPT_DIR/lib/utils.sh"

minx_create_base_dirs || exit 1

LOGFILE="$MINX_LOG_DIR/$(minx_get_script_name).log"

_run_and_log() {
	minx_run_and_log "$LOGFILE" "$@"
}

main() {
	local codename
	local hostname
	local device_type
	local cpu_vendor
	local backports

	minx_header "L1" "$(lsb_release -a)"

	codename=$(lsb_release -sc)
	hostname=$(hostname)
	device_type="$(minx_get_device_type)"
	cpu_vendor="$(minx_get_cpu_vendor)"
	backports="none"

	minx_write_info "backports" "$backports"
	minx_write_info "codename" "$codename"
	minx_write_info "cpu_vendor" "$cpu_vendor"
	minx_write_info "device_type" "$device_type"
	minx_write_info "hostname" "$hostname"

	# ----------------------------------------------------------------------
	# Summary
	# ----------------------------------------------------------------------

	minx_test_all_info || exit 1

	cat <<EOF

Configuration summary:
----------------------
BACKPORTS         = $backports
CODENAME          = $codename
CPU_VENDOR        = $cpu_vendor
DEVICE_TYPE       = $device_type
HOSTNAME          = $hostname
INSTALLATION_TYPE = $(minx_load_installation_type)
EOF

	"$SCRIPT_DIR/installer.sh" --install runtime || return 1

	printf "\nLOG: %s\n" "$LOGFILE"
}

_run_and_log main "$@"
