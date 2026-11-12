#!/usr/bin/env bash
# ta_reminder.sh

set -euo pipefail
# set -x

#=================================================================================
# load user environment
#=================================================================================

# shellcheck disable=SC1091 # path is resolved at runtime.
source "/etc/profile.d/minx_profile.sh"

export DISPLAY=:0
export XAUTHORITY="$HOME/.Xauthority"

#=================================================================================
# helper functions
#=================================================================================

_is_timew_active() {
	local active
	active=$(timew get dom.active 2>/dev/null || echo 0)
	((active == 1))
}

_is_screen_locked() {
	# slock is active while the X session is locked
	pgrep -u "$(id -u)" -x slock >/dev/null
}

_is_sleep_transition() {
	systemctl list-jobs 2>/dev/null | grep -Eq 'suspend|hibernate|hybrid-sleep|suspend-then-hibernate'
}

#=================================================================================
# main
#=================================================================================

if _is_screen_locked || _is_sleep_transition; then
	exit 0
fi

if ! _is_timew_active; then
	minx-launcher tt_shell
fi
