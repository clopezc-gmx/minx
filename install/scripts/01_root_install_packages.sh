#!/usr/bin/env bash
# shellcheck disable=SC1091 # paths are resolved at runtime.

# 01_root.sh
# Debian 13 provisioning for headless servers and dwm laptops.
#
# Run the options you need, in this order (each is safe to re-run):
#   --run-update --initial-setup --install-firmware
#   --install-base                                                   (server: stop here)
#   --install-dev --install-desktop --install-radio --install-power
#   --install-latex                                                  (optional, large)
#
# Each action runs in a child bash (MINX_CHILD=1) so `set -e` really works:
# bash disables errexit inside anything called from `if` / `||`, which is how
# the parent calls the logger.

set -euo pipefail
#set -x

# Setup
# ----------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
source "$SCRIPT_DIR/lib/utils.sh"

minx_assert_is_root "${0##*/}" || exit 1
minx_test_all_info || exit 1

# Config
# ----------------------------------------------------------------------

BACKPORTS_SUITE="$(minx_load_info backports)" || exit 1

# Passwordless mount/umount is effectively passwordless root. Removable media
# is handled by udisks2 (see _install_desktop), so this stays off.
SUDO_ALLOW_MOUNT=0

export DEBIAN_FRONTEND=noninteractive

WORKDIR="$(mktemp -d)"
trap 'rm -rf -- "$WORKDIR"' EXIT

_APT_UPDATED=0
FILE_CHANGED=0

# Helpers
# ----------------------------------------------------------------------

_run() {
	printf '$'
	printf ' %q' "$@"
	printf '\n'
	"$@"
}

_warn() { printf '=> WARNING: %s\n' "$*" >&2; }

_logfile() {
	printf '%s\n' "$MINX_LOG_DIR/$(minx_get_script_name)${1}_$(minx_get_date).log"
}

_print_reboot_msg() {
	printf '\n=> Finished. Please REBOOT.\n'
}

# Write stdin to <dest> only if the content differs. Sets FILE_CHANGED=0/1.
_install_file_if_changed() { # <mode> <dest>
	local mode="$1" dest="$2"
	local tmp="$WORKDIR/${dest//\//_}.new"

	cat >"$tmp"
	if cmp -s "$tmp" "$dest" 2>/dev/null; then
		FILE_CHANGED=0
	else
		install -m "$mode" "$tmp" "$dest"
		FILE_CHANGED=1
	fi
}

# The user this machine is set up for (never root). Resolved by the parent.
_target_user() {
	local user="${MINX_USER:-}"

	if [[ -z "$user" || "$user" == root ]]; then
		printf 'Cannot determine target user. Run via sudo, or set MINX_USER=<name>.\n' >&2
		return 1
	fi
	id -u "$user" >/dev/null 2>&1 || {
		printf 'User does not exist: %s\n' "$user" >&2
		return 1
	}
	# sudoers.d ignores file names containing "." or "~".
	[[ "$user" =~ ^[a-z_][a-z0-9_-]*$ ]] || {
		printf 'Unsupported user name for sudoers.d: %s\n' "$user" >&2
		return 1
	}
	printf '%s\n' "$user"
}

_add_user_to_groups() {
	local user group
	user="$(_target_user)" || {
		_warn "no target user; skipping groups: $*"
		return 0
	}
	for group in "$@"; do
		if getent group "$group" >/dev/null; then
			_run usermod -aG "$group" "$user"
		else
			_warn "group does not exist, skipping: $group"
		fi
	done
}

# First package apt knows about, from the argument list.
_first_available() {
	local pkg
	for pkg in "$@"; do
		if apt-cache show "$pkg" >/dev/null 2>&1; then
			printf '%s\n' "$pkg"
			return 0
		fi
	done
	return 1
}

# APT
# ----------------------------------------------------------------------

_configure_apt() {

	local src=/etc/apt/sources.list.d/debian.sources

	# Netinst/upgraded installs use the classic sources.list: convert it to
	# deb822 so the Components edit below can apply. Keeps sources.list.bak.
	if [[ ! -f "$src" ]] && grep -qE '^[[:space:]]*deb(-src)?[[:space:]]' /etc/apt/sources.list 2>/dev/null; then
		printf '=> Converting /etc/apt/sources.list to deb822 format\n'
		_run apt modernize-sources -y
	fi

	# intel-microcode lives in non-free; firmware in non-free-firmware.
	if [[ -f "$src" ]]; then
		local tmp="$WORKDIR/debian.sources"
		sed -E 's/^Components:.*/Components: main contrib non-free non-free-firmware/' "$src" >"$tmp"
		if ! cmp -s "$tmp" "$src"; then
			printf 'Updating components in %s\n' "$src"
			install -m 0644 "$tmp" "$src"
		fi
	else
		_warn "$src not found; enable contrib/non-free/non-free-firmware yourself."
	fi

	if [[ "$BACKPORTS_SUITE" != none ]]; then
		if grep -rqs -- "$BACKPORTS_SUITE" /etc/apt/sources.list /etc/apt/sources.list.d; then
			return 0
		fi

		local keyring=""
		local candidate
		for candidate in /usr/share/keyrings/debian-archive-keyring.pgp /usr/share/keyrings/debian-archive-keyring.gpg; do
			if [[ -f "$candidate" ]]; then
				keyring="$candidate"
				break
			fi
		done
		[[ -n "$keyring" ]] || {
			printf 'Debian archive keyring not found.\n' >&2
			return 1
		}

		_install_file_if_changed 0644 /etc/apt/sources.list.d/minx-backports.sources <<EOF
Types: deb
URIs: http://deb.debian.org/debian
Suites: $BACKPORTS_SUITE
Components: main contrib non-free non-free-firmware
Signed-By: $keyring
EOF
	fi
}

_apt_update_once() {
	((_APT_UPDATED == 0)) || return 0
	_configure_apt
	_run apt-get update
	_APT_UPDATED=1
}

_install_packages() {
	(($# > 0)) || return 0
	_apt_update_once

	local opts=(-y)
	if [[ "$BACKPORTS_SUITE" != none ]]; then
		opts+=(-t "$BACKPORTS_SUITE")
	fi
	_run apt-get "${opts[@]}" install "$@"
}

# ----------------------------------------------------------------------
# run update
# ----------------------------------------------------------------------

_run_update() {
	_apt_update_once
	_run apt-get autoclean
	_run apt-get -y full-upgrade
	_run apt-get -y autoremove
}

# ----------------------------------------------------------------------
# Initial setup
# ----------------------------------------------------------------------

_initial_setup() {

	__configure_keyboard() {
		_install_packages console-setup keyboard-configuration

		_install_file_if_changed 0644 /etc/default/keyboard <<'EOF'
XKBMODEL="pc105"
XKBLAYOUT="us"
XKBVARIANT=""
XKBOPTIONS="ctrl:nocaps"
BACKSPACE="guess"
EOF
		if ((FILE_CHANGED)); then
			printf '=> Updated /etc/default/keyboard\n'
			setupcon || _warn "setupcon failed (no console?); applies after reboot"
		else
			printf '=> Keymap settings are already correct. No changes made.\n'
		fi

		_run localectl --no-pager
	}

	__configure_sudoers() {
		local username="${1:?username required}"
		local sudo_file="/etc/sudoers.d/${username}"
		local tmp_file="$WORKDIR/sudoers.new"

		printf '\n=> Configure sudoers for %s: %s\n' "$username" "$sudo_file"

		# Power off, reboot and suspend need no sudo: logind + polkit allow the
		# active local session (systemctl poweroff|reboot|suspend as the user).
		# /usr/bin/bluetooth and /usr/bin/wifi are your own wrappers: they must
		# be root-owned and not writable by anyone else.
		local sudo_cmds=(
			"/usr/bin/bluetooth"
			"/usr/bin/wifi"
			"/usr/sbin/rfkill"
		)
		if ((SUDO_ALLOW_MOUNT)); then
			sudo_cmds+=("/usr/bin/mount" "/usr/bin/umount")
		fi

		{
			printf '# Managed by provisioning script for %s\n' "$username"
			local cmd
			for cmd in "${sudo_cmds[@]}"; do
				printf '%s ALL=(ALL) NOPASSWD: %s\n' "$username" "$cmd"
			done
		} >"$tmp_file"

		/usr/sbin/visudo -cf "$tmp_file"
		install -m 0440 "$tmp_file" "$sudo_file"

		_run cat "$sudo_file"
	}

	# ----------
	# Body
	# ----------

	local username
	username="$(_target_user)"

	_run timedatectl set-timezone Europe/Berlin

	# sudo is not part of a minimal Debian install.
	_install_packages sudo systemd-timesyncd

	__configure_keyboard

	__configure_sudoers "$username"

	# Disable PC speaker
	if [[ "$(minx_load_info device_type)" == "portable" ]]; then
		local mod
		for mod in pcspkr snd_pcsp; do
			if lsmod | grep -q "^${mod} "; then
				_run rmmod "$mod"
			fi
		done

		_install_file_if_changed 0644 /etc/modprobe.d/pcspkr.conf <<'EOF'
blacklist pcspkr
blacklist snd_pcsp
EOF
	fi
}

# ----------------------------------------------------------------------
# Firmware and CPU microcode
# ----------------------------------------------------------------------

_install_firmware() {
	local firmware_common=(
		firmware-misc-nonfree
		firmware-linux-nonfree
		firmware-linux
		firmware-iwlwifi
		firmware-realtek
	)

	local cpu_vendor
	cpu_vendor="$(minx_load_info cpu_vendor)"

	local vendor_packages=()
	if [[ "$cpu_vendor" == "$MINX_AMD" ]]; then
		vendor_packages=(amd64-microcode firmware-amd-graphics)
	elif [[ "$cpu_vendor" == "$MINX_INTEL" ]]; then
		# firmware-netxen is for QLogic NICs; drop it if you do not have one.
		vendor_packages=(intel-microcode firmware-netxen)
	else
		printf 'Error: Unknown CPU vendor: %s\n' "$cpu_vendor" >&2
		return 1
	fi

	_install_packages "${firmware_common[@]}" "${vendor_packages[@]}"
}

# ----------------------------------------------------------------------
# Group: base (CLI system, no X11)
# ----------------------------------------------------------------------

_install_base() {
	local system=(
		sudo
		polkitd
		libpam-systemd
		bash-completion
		ca-certificates
		curl
		wget
		rsync
		git
		gnupg
		htop
		acpi
		jq
		less
		locate
		rfkill
		systemd-timesyncd
		tmux
		uuid-runtime
		dosfstools
		openssh-client
		openssh-server
		vnstat
		vnstati
		sshfs
		socat
	)

	local docs_and_files=(
		manpages
		manpages-dev
		mandoc
		fzf
		direnv
		highlight
		unison
	)

	local mail_and_web=(
		neomutt
		w3m
		urlview
		urlscan
		newsboat
		notmuch
		abook
		msmtp
		isync
	)

	local secrets=(
		pass
		pass-extension-otp
		pinentry-curses
		pwgen
	)

	_install_packages \
		"${system[@]}" \
		"${docs_and_files[@]}" \
		"${mail_and_web[@]}" \
		"${secrets[@]}"
}

# ----------------------------------------------------------------------
# Group: dev (toolchains, languages, libraries, scientific computing)
# ----------------------------------------------------------------------

_install_dev() {
	local toolchain=(
		build-essential
		automake
		cmake
		pkg-config
		libtool
		libtool-bin
		gawk
		byacc
		perl
		git-lfs
		clang
		clang-tidy
		clang-format
		clang-tools
		doxygen
		plantuml
	)

	local python=(
		python3
		python3-dev
		python3-full
		python3-pip
		pipx
	)

	local libraries=(
		libcurl4-openssl-dev
		libssl-dev
		libxml2-dev
		libreadline-dev
		libncurses-dev
		libgcr-3-dev
		libgirepository1.0-dev
		libglib2.0-dev
		libgdk-pixbuf-2.0-dev
		libpurple-dev
	)

	# One MPI stack (OpenMPI); HDF5 is built against it.
	local scientific=(
		python3-numpy
		python3-scipy
		python3-matplotlib
		python3-pyrsistent
		gfortran
		openmpi-bin
		libopenmpi-dev
		libscalapack-openmpi-dev
		libfftw3-dev
		liblapack-dev
		libhdf5-openmpi-dev
		libhwloc-dev
		gnuplot
		vite
		xdot
	)

	_install_packages \
		"${toolchain[@]}" \
		"${python[@]}" \
		"${libraries[@]}" \
		"${scientific[@]}"
}

# ----------------------------------------------------------------------
# GPU (detected via lspci; part of the desktop group)
# ----------------------------------------------------------------------

_install_gpu() {
	# Generic Mesa stack for every GPU (OpenGL, Vulkan).
	_install_packages \
		pciutils \
		libgl1-mesa-dri \
		libglx-mesa0 \
		mesa-vulkan-drivers \
		mesa-utils \
		vainfo

	local gpus
	gpus="$(lspci -nn | grep -Ei 'vga|3d controller|display controller' || true)"

	if [[ -z "$gpus" ]]; then
		_warn "no GPU found via lspci (VM?); only the generic Mesa stack was installed."
		return 0
	fi
	printf '=> Detected GPU(s):\n%s\n' "$gpus"

	# Hybrid laptops report more than one GPU, so check each vendor.
	if grep -qi 'intel' <<<"$gpus"; then
		printf '=> Intel GPU: VA-API video acceleration\n'
		# Modesetting driver is the X11 default; no xserver-xorg-video-intel.
		_install_packages intel-media-va-driver
	fi

	if grep -Eqi 'amd|ati|radeon' <<<"$gpus"; then
		printf '=> AMD GPU: VA-API/VDPAU video acceleration\n'
		# firmware-amd-graphics comes from --install-firmware.
		_install_packages mesa-va-drivers mesa-vdpau-drivers
	fi

	if grep -qi 'nvidia' <<<"$gpus"; then
		# The proprietary driver needs DKMS, headers and Secure Boot handling;
		# installing it unattended can leave you without X. Nouveau works by default.
		_warn "NVIDIA GPU detected: using nouveau. For the proprietary driver install 'nvidia-driver' manually."
	fi
}

# ----------------------------------------------------------------------
# Group: desktop (X11, GPU, audio/video, apps, printing, removable media)
# ----------------------------------------------------------------------

_install_desktop() {
	local x11=(
		xorg
		xorg-dev
		x11-xserver-utils
		xdg-utils
		xutils-dev
		xclip
		xinput
		dbus-x11
		xss-lock
		feh
		scrot
		xdotool
		dunst
		autocutsel
		redshift
		libnotify-bin
		libinput-tools
		ueberzug
		xserver-xorg-video-all
	)

	# GPU drivers are handled by _install_gpu.
	local graphics_and_fonts=(
		brightnessctl
		unifont
		fonts-dejavu
		fonts-noto-color-emoji
	)

	local audio_video=(
		alsa-utils
		libspa-0.2-bluetooth
		libspa-0.2-modules
		mpv
		mpv-mpris
		pavucontrol
		pipewire
		pipewire-audio
		pipewire-audio-client-libraries
		pipewire-pulse
		playerctl
		pulseaudio-utils
		wireplumber
	)

	local printing_and_scanning=(
		cups
		avahi-utils
		printer-driver-all
		sane-utils
		system-config-printer
		gscan2pdf
		simple-scan
		tesseract-ocr
		tesseract-ocr-deu
		tesseract-ocr-spa
	)

	# Mounting pendrives without sudo: udisks2 + polkit (active local session).
	# Start `udiskie --no-tray &` (or -a -n) from your dwm autostart.
	local removable_media=(
		udisks2
		udiskie
		gvfs
		ntfs-3g
		exfatprogs
	)

	local apps=(
		chromium
		tigervnc-viewer
		zathura
		zathura-pdf-poppler
		evince
		libjs-pdf
		pcmanfm
		gthumb
		gparted
		rofi
		qalc
		bat
	)

	# Runtime libraries for a pip/venv qutebrowser.
	local qutebrowser_libs=(
		libgl1
		libxkbcommon-x11-0
		libegl1
		libfontconfig1
		libglib2.0-0
		libdbus-1-3
		libxcb-cursor0
		libxcb-icccm4
		libxcb-keysyms1
		libxcb-shape0
		libnss3
		libxcomposite1
		libxdamage1
		libxrender1
		libxrandr2
		libxtst6
		libxi6
		libasound2
	)

	local calix=(
		curl
		jq
		tar
		libgtk-4-1
		libadwaita-1-0
		xdg-utils
		gnome-keyring
	)

	local jdk
	jdk="$(_first_available openjdk-25-jdk openjdk-21-jdk)" || {
		printf 'No OpenJDK JDK package found.\n' >&2
		return 1
	}
	printf '=> Using %s\n' "$jdk"

	_install_packages \
		"${x11[@]}" \
		"${graphics_and_fonts[@]}" \
		"${audio_video[@]}" \
		"${printing_and_scanning[@]}" \
		"${removable_media[@]}" \
		"${apps[@]}" \
		"${qutebrowser_libs[@]}" \
		"${calix[@]}" \
		"$jdk"

	_install_gpu

	# Debian ships bat as batcat.
	if [[ -x /usr/bin/batcat ]]; then
		_run ln -sf /usr/bin/batcat /usr/local/bin/bat
	fi

	# video: brightnessctl, input: libinput debug-events,
	# lpadmin/scanner: printing and scanning.
	_add_user_to_groups video input lpadmin scanner
}

# ----------------------------------------------------------------------
# Group: radio (network + bluetooth)
# ----------------------------------------------------------------------

_install_radio() {
	_install_packages \
		network-manager \
		blueman \
		bluez \
		bluez-firmware \
		bluez-tools

	printf '\n%s\n' "################################################################################"
	printf '%s\n\n' "=> Settings to reduce boot-time"
	printf '%s\n' "- Disable wait-online services"

	local online_services=(
		NetworkManager-wait-online.service
	)

	local svc
	for svc in "${online_services[@]}"; do
		printf '%s:\n' "$svc"
		if systemctl cat "$svc" >/dev/null 2>&1; then
			_run systemctl disable "$svc"
		fi
	done

	printf '%s\n' "- NetworkManager manages interfaces from /etc/network/interfaces: [ifupdown] managed=true"

	local network_conf=/etc/NetworkManager/NetworkManager.conf
	[[ -f "$network_conf" ]] || {
		printf 'Missing %s\n' "$network_conf" >&2
		return 1
	}

	if grep -q '^\[ifupdown\]' "$network_conf"; then
		if sed -n '/^\[ifupdown\]/,/^\[/p' "$network_conf" | grep -q '^managed='; then
			sed -i '/^\[ifupdown\]/,/^\[/{s/^managed=.*/managed=true/}' "$network_conf"
		else
			sed -i '/^\[ifupdown\]/a managed=true' "$network_conf"
		fi
	else
		printf '\n%s\n%s\n' '[ifupdown]' 'managed=true' >>"$network_conf"
	fi

	_run cat "$network_conf"

	local section
	section="$(sed -n '/^\[ifupdown\]/,/^\[/p' "$network_conf")"
	if grep -qx 'managed=true' <<<"$section"; then
		printf '\n=> %s\n' "[PASS] NetworkManager configuration"
	else
		printf '\n=> %s\n' "[FAIL] NetworkManager configuration"
		return 1
	fi

	printf '################################################################################\n'
}

# ----------------------------------------------------------------------
# Group: power (laptops only)
# ----------------------------------------------------------------------

_install_power() {
	if [[ "$(minx_load_info device_type)" != "portable" ]]; then
		printf '=> Skipping power packages: device is not portable.\n'
		return 0
	fi

	_install_packages tlp tlp-rdw
	_run systemctl enable --now tlp
}

# ----------------------------------------------------------------------
# Group: latex
# ----------------------------------------------------------------------

_install_latex() {
	_install_packages texlive-full
}

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------

main() {

	local action="${1:-"--help"}"
	local function_name=""

	case "$action" in
	"--run-update")
		function_name="_run_update"
		;;
	"--initial-setup")
		function_name="_initial_setup"
		;;
	"--install-firmware")
		function_name="_install_firmware"
		;;
	"--install-base")
		function_name="_install_base"
		;;
	"--install-dev")
		function_name="_install_dev"
		;;
	"--install-desktop")
		function_name="_install_desktop"
		;;
	"--install-radio")
		function_name="_install_radio"
		;;
	"--install-power")
		function_name="_install_power"
		;;
	"--install-latex")
		function_name="_install_latex"
		;;
	*)
		printf '\n%s\n' "Try with a valid argument:"
		source "$SCRIPT_DIR/lib/list_dispatch_options.sh"
		minx_list_options "$0"
		if [[ "$action" == "--help" || "$action" == "-h" ]]; then
			return 0
		fi
		return 1
		;;
	esac

	# Child: run the action with working errexit.
	if [[ "${MINX_CHILD:-}" == 1 ]]; then
		"$function_name"
		return
	fi

	# Parent: resolve the target user while there is still a login context
	# (logname does not work inside the logging pipe), then re-exec.
	if [[ -z "${MINX_USER:-}" ]]; then
		MINX_USER="${SUDO_USER:-$(logname 2>/dev/null || true)}"
	fi
	export MINX_USER

	mkdir -p "$MINX_LOG_DIR"

	local logfile rc=0
	logfile="$(_logfile "$function_name")"

	minx_run_and_log "$logfile" env MINX_CHILD=1 bash "${BASH_SOURCE[0]}" "$action" || rc=$?

	if ((rc == 0)); then
		printf '\nLOG: %s\n' "$logfile"
		_print_reboot_msg
	else
		printf '\nFAILED (exit %d). LOG: %s\n' "$rc" "$logfile" >&2
	fi
	return "$rc"
}

main "$@"
