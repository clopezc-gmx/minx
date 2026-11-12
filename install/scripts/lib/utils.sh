#!/usr/bin/env bash
# shellcheck disable=SC2034 # Variables used by sourced scripts.
# shellcheck disable=SC1091 # Paths resolved at runtime.

if [[ -n "${MINX_INSTALL_UTILS_LOADED:-}" ]]; then
	return 0
fi

minx_assert_has_display() { # {{{
	if [[ -z "${DISPLAY:-}" ]]; then
		printf '%s\n' "=> ERROR: No display found. Please ensure you are running in a graphical environment." >&2
		return 1
	fi
	return 0
} # }}}

minx_safe_rm_dir() { # {{{
	local path="$1"

	# on purpose hardcoded as second layer of protection

	[[ -n "$path" ]] || {
		printf '%s\n' "=> [minx_safe_rm_dir] ERROR: empty path" >&2
		return 1
	}

	[[ "$path" == /* ]] || {
		printf '%s\n' "=> [minx_safe_rm_dir] ERROR: path must be absolute: $path" >&2
		return 1
	}

	[[ -e "$path" || -L "$path" ]] || {
		printf '%s\n' "=> [minx_safe_rm_dir] INFO: nothing to remove, path does not exist: $path" >&2
		return 0
	}

	local resolved
	resolved="$(realpath -e -- "$path")" || {
		printf '%s\n' "=> [minx_safe_rm_dir] ERROR: cannot resolve path: $path" >&2
		return 1
	}

	case "$resolved" in
	$MINX_INSTALLATION_DIR/* | /tmp/*)
		rm -rf -- "$resolved"
		;;
	*)
		printf '%s\n' "=> [minx_safe_rm_dir] ERROR: refusing to remove path outside allowed roots: $resolved" >&2
		return 1
		;;
	esac
} # }}}

minx_add_to_PATH() { # {{{
	local path="$1"
	local profile_file="/etc/profile.d/minx_profile.sh"
	local line="export PATH=\"$path:\$PATH\""

	if ((EUID != 0)); then
		printf '%s\n' "=> [minx_add_to_PATH] ERROR: run as root." >&2
		return 1
	fi

	[[ -n "$path" ]] || {
		printf '%s\n' "=> [minx_add_to_PATH] ERROR: empty path" >&2
		return 1
	}

	[[ "$path" == /* ]] || {
		printf '%s\n' "=> [minx_add_to_PATH] ERROR: path must be absolute: $path" >&2
		return 1
	}

	[[ -d "$path" ]] || {
		printf '%s\n' "=> [minx_add_to_PATH] ERROR: directory does not exist: $path" >&2
		return 1
	}

	[[ -f "$profile_file" ]] || {
		: >"$profile_file"
		chmod 644 "$profile_file"
	}

	if grep -Fqx -- "$line" "$profile_file"; then
		printf '%s\n' "=> [minx_add_to_PATH] INFO: already configured in $profile_file: $path"
		return 0
	fi

	printf '%s\n' "$line" >>"$profile_file"
	printf '%s\n' "=> Added to system PATH: $path"
} # }}}

minx_path_exists() { # {{{
	local path="$1"
	[[ -e "$path" || -L "$path" ]]
} # }}}

_get_installer_root() { # {{{
	local script_dir
	local minx_root

	script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || return 1

	minx_root="$(cd -- "$script_dir/../../.." 2>/dev/null && pwd)" || {
		printf '%s\n' "=> $script_dir/../../.. does not exist or is not a directory" >&2
		return 1
	}

	minx_path_exists "$minx_root/.git" || {
		printf '%s\n' "=> $minx_root is not a root git repository" >&2
		return 1
	}

	printf '%s\n' "$minx_root"
} # }}}

minx_assert_is_root() { # {{{
	local name=${1:-${0##*/}}
	if ((EUID != 0)); then
		printf '%s\n' "=> Run \"$name\" as a ROOT." >&2
		return 1
	fi
} # }}}

minx_assert_is_non_root() { # {{{
	local name=${1:-${0##*/}}
	if ((EUID == 0)); then
		printf '%s\n' "=> Run \"$name\" as a NON-ROOT." >&2
		return 1
	fi
} # }}}

minx_assert_equal() { # {{{
	local msg=${3:-}
	if [[ "$1" != "$2" ]]; then
		printf '=> Failed: %s != %s\n' "$1" "$2" >&2
		if [[ -n "$msg" ]]; then
			printf '%s\n' "=> $msg" >&2
		fi
		return 1
	fi
} # }}}

minx_command_exists() { # {{{
	command -v "$1" >/dev/null 2>&1
} # }}}

minx_print_header() { # {{{
	local num_char="$1"
	local char="$2"
	local sep

	if [[ ! "$num_char" =~ ^[0-9]+$ || ${#char} -ne 1 ]]; then
		printf '%s\n' \
			"Usage: minx_print_header <num_char> <char> <text...>" >&2
		return 1
	fi

	sep=$(printf '%*s' "$num_char" '' | tr ' ' "$char")

	shift 2

	printf '\n%s\n' "$sep"
	printf '%s\n' "$*"
	printf '%s\n' "$sep"
} # }}}

minx_run_and_log() { # {{{
	local logfile="$1"
	shift

	if [[ -z "$logfile" || $# -eq 0 ]]; then
		printf '%s\n' \
			"Usage: minx_run_and_log <logfile> <command> [args...]" >&2
		return 1
	fi

	if [[ -f "$MINX_INSTALLATION_DIR/version" ]]; then
		{
			local marker="********************************************************************************"
			printf "\n%s" "$marker"
			printf "\n%s\n" "$(date)"
			cat "$MINX_INSTALLATION_DIR/version"
			printf "%s\n" "$marker"
		} >>"$logfile"
	fi

	"$@" 2>&1 | tee -a "$logfile"

	local cmd_status="${PIPESTATUS[0]}"
	return "$cmd_status"
} # }}}

# minx_git_clone_at_commit <dir> <url> <commit> [patch_file]
#
# Clones (if needed) and checks out <commit> detached. Local changes are
# discarded, EXCEPT when the tree is already at <commit> with <patch_file>
# applied: then nothing is touched, so build output survives re-runs.
minx_git_clone_at_commit() { # {{{
	local app_dir="${1:-}"
	local url="${2:-}"
	local commit="${3:-}"
	local patch_file="${4:-}"
	local app="${app_dir##*/}"
	local current_commit=""
	local at_target=0
	local patched=0

	if [[ -z "$app_dir" || -z "$url" || -z "$commit" ]]; then
		printf '%s\n' "Usage: minx_git_clone_at_commit <directory> <url> <commit> [patch_file]" >&2
		return 1
	fi

	if [[ ! "$commit" =~ ^[0-9a-f]{7,64}$ ]]; then
		printf '=> Error: commit must be a hex hash (7-64 chars): %s\n' "$commit" >&2
		return 1
	fi

	if [[ ! -d "$app_dir/.git" ]]; then
		if [[ -e "$app_dir" ]]; then
			printf '=> Error: %s exists but is not a Git repository.\n' "$app_dir" >&2
			return 1
		fi

		printf '=> Cloning %s.\n' "$app"
		git clone "$url" "$app_dir" || {
			printf '=> Error: failed to clone %s into %s.\n' "$url" "$app_dir" >&2
			return 1
		}
	fi

	current_commit="$(git -C "$app_dir" rev-parse HEAD)" || return 1
	if [[ "$current_commit" == "$commit"* ]]; then
		at_target=1
	fi

	if [[ -n "$patch_file" && -f "$patch_file" ]] &&
		git -C "$app_dir" apply --reverse --check "$patch_file" 2>/dev/null; then
		patched=1
	fi

	if ((at_target && patched)); then
		printf '=> %s already at commit %s with patch applied.\n' "$app" "$commit"
	else
		if ! git -C "$app_dir" diff --quiet ||
			! git -C "$app_dir" diff --cached --quiet ||
			[[ -n "$(git -C "$app_dir" ls-files --others --exclude-standard)" ]]; then
			printf '=> Force reset: discarding local changes in %s.\n' "$app"
			git -C "$app_dir" reset --hard HEAD || return 1
			git -C "$app_dir" clean -fd || return 1
		fi
	fi

	if ((! at_target)); then
		printf '=> Fetching %s at commit %s.\n' "$app" "$commit"

		git -C "$app_dir" fetch --tags origin || {
			printf '=> Error: failed to fetch repository for %s.\n' "$app" >&2
			return 1
		}

		if ! git -C "$app_dir" cat-file -e "$commit^{commit}" 2>/dev/null; then
			printf '=> Error: commit %s not found in %s.\n' "$commit" "$app" >&2
			return 1
		fi

		git -C "$app_dir" checkout --detach "$commit" || {
			printf '=> Error: failed to checkout commit %s for %s.\n' "$commit" "$app" >&2
			return 1
		}
	fi

	current_commit="$(git -C "$app_dir" rev-parse HEAD)" || return 1

	if [[ "$current_commit" != "$commit"* ]]; then
		printf '=> Error: checked out %s, expected %s.\n' "$current_commit" "$commit" >&2
		return 1
	fi

	printf '=> Updating submodules for %s.\n' "$app"

	git -C "$app_dir" submodule update --init --recursive || {
		printf '=> Error: failed to update submodules for %s.\n' "$app" >&2
		return 1
	}

	printf '=> %s is at commit %s.\n' "$app" "$current_commit"
} # }}}

minx_git_clone_and_patch() { # {{{
	local app_dir="$1"
	local url="$2"
	local commit="$3"
	local patch_file="${4:-}"

	local app="${app_dir##*/}"

	minx_git_clone_at_commit "$app_dir" "$url" "$commit" "$patch_file" || return 1

	if [[ -z "$patch_file" ]]; then
		return 0
	fi

	if [[ ! -f "$patch_file" ]]; then
		printf '=> Error: Patch file does not exist: %s\n' \
			"$patch_file" >&2
		return 1
	fi

	if git -C "$app_dir" apply --reverse --check "$patch_file" 2>/dev/null; then
		printf '=> Patch already applied to %s, skipping.\n' "$app"
	elif git -C "$app_dir" apply --check "$patch_file"; then
		printf '=> Applying patch to %s\n' "$app"
		git -C "$app_dir" apply "$patch_file" || return 1
	else
		printf '=> Error: Patch cannot be applied to %s: %s\n' \
			"$app" "$patch_file" >&2
		return 1
	fi
} # }}}

minx_get_cpu_vendor() { # {{{
	local vendor

	vendor="$(awk -F: '/^vendor_id/ {gsub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo)"

	if [[ "$vendor" == "$MINX_INTEL" || "$vendor" == "$MINX_AMD" ]]; then
		printf '%s\n' "$vendor"
	else
		printf '=> Error: unknown vendor %s\n' "$vendor" >&2
		return 1
	fi
} # }}}

minx_get_device_type() { # {{{
	local chassis_type=""

	# Missing in some VMs and containers.
	chassis_type="$(cat /sys/class/dmi/id/chassis_type 2>/dev/null)" || chassis_type=""

	# 8 portable, 9 laptop, 10 notebook, 11 handheld, 14 sub-notebook,
	# 30 tablet, 31 convertible, 32 detachable.
	if [[ "$chassis_type" =~ ^(8|9|10|11|14|30|31|32)$ ]]; then
		printf '%s\n' "portable"
	else
		printf '%s\n' "not-portable"
	fi
} # }}}

minx_symlink() { # {{{
	local source="$1"
	local destination="$2"
	local tmp_link

	mkdir -p -- "$(dirname -- "$destination")" || return 1

	if [[ -e "$destination" && ! -L "$destination" ]]; then
		# Never silently delete a real file or directory.
		printf '%s\n' "=> Error: destination already exists and is not a symlink: $destination" >&2
		return 1
	fi

	# Build the new link under a temporary name, verify it resolves, then
	# atomically replace the old one. A bad source never destroys a good link.
	tmp_link="${destination}.minx-tmp.$$"
	rm -f -- "$tmp_link"
	ln -s -- "$source" "$tmp_link" || return 1

	if ! readlink -e -- "$tmp_link" >/dev/null; then
		printf '%s\n' "=> Error: source does not exist: $source" >&2
		rm -f -- "$tmp_link"
		return 1
	fi

	printf '%s\n' "=> Linking $destination -> $source"
	mv -T -f -- "$tmp_link" "$destination"
} # }}}

minx_symlink_map() { # {{{
	local -n _minx_map="$1"

	local destination
	local source

	for destination in "${!_minx_map[@]}"; do
		source="${_minx_map[$destination]}"

		if minx_path_exists "$source"; then
			minx_symlink "$source" "$destination" || return 1
		else
			printf '=> %s does not exist, skipping\n' "$source"
		fi
	done
} # }}}

minx_move() { # {{{
	local source="$1"
	local destination="$2"

	mkdir -p -- "$(dirname -- "$destination")" || return 1
	printf '=> Moving %s -> %s\n' "$source" "$destination"
	# -T: never move INTO an existing directory; fail loudly instead.
	mv -T -- "$source" "$destination"
} # }}}

minx_copy() { # {{{
	local source="$1"
	local destination="$2"

	printf '=> Copying %s -> %s\n' "$source" "$destination"

	if [[ -d "$source" ]]; then
		# Copy contents so a re-run does not nest dest/src.
		mkdir -p -- "$destination" || return 1
		cp -a -- "$source/." "$destination/"
	else
		mkdir -p -- "$(dirname -- "$destination")" || return 1
		cp -af -- "$source" "$destination"
	fi
} # }}}

minx_move_map() { # {{{
	local -n _minx_map="$1"

	local destination
	local source

	for destination in "${!_minx_map[@]}"; do
		source="${_minx_map[$destination]}"

		if minx_path_exists "$source"; then
			minx_move "$source" "$destination" || return 1
		else
			printf '=> %s does not exist, skipping\n' "$source"
		fi
	done
} # }}}

minx_copy_map() { # {{{
	local -n _minx_map="$1"

	local destination
	local source

	for destination in "${!_minx_map[@]}"; do
		source="${_minx_map[$destination]}"

		if ! minx_path_exists "$source"; then
			printf '=> %s does not exist\n' "$source" >&2
			return 1
		fi

		minx_copy "$source" "$destination" || return 1
	done
} # }}}

minx_get_script_name() { # {{{
	# Get the filename of the script that sourced this file, without its extension.
	local script_name="${BASH_SOURCE[1]##*/}"
	printf '%s\n' "${script_name%.*}"
} # }}}

minx_get_os_codename() { # {{{
	# lsb_release is not part of a minimal Debian; /etc/os-release always is.
	(
		# shellcheck disable=SC1091
		. /etc/os-release
		printf '%s\n' "${VERSION_CODENAME:-}"
	)
} # }}}

minx_test_all_info() { # {{{
	local _codename
	local _hostname
	local _cpu_vendor
	local _device_type
	local _backports

	_codename="$(minx_load_info codename)" || return 1
	minx_assert_equal "$_codename" "$(minx_get_os_codename)" || return 1

	_hostname="$(minx_load_info hostname)" || return 1
	minx_assert_equal "$_hostname" "$(hostname)" || return 1

	_cpu_vendor="$(minx_load_info cpu_vendor)" || return 1
	minx_assert_equal "$_cpu_vendor" "$(minx_get_cpu_vendor)" || return 1

	_device_type="$(minx_load_info device_type)" || return 1
	minx_assert_equal "$_device_type" "$(minx_get_device_type)" || return 1

	# Must be "none" or a suite name such as "trixie-backports".
	_backports="$(minx_load_info backports)" || return 1
	if [[ ! "$_backports" =~ ^[a-z0-9-]+$ ]]; then
		printf '=> Error: invalid backports value: %s\n' "$_backports" >&2
		return 1
	fi
} # }}}

minx_get_date() { # {{{
	date +%Y%m%dT%H%M%S
} # }}}

_get_git_root_dir() { # {{{
	local username="$1"
	local directory="${2:-.}"
	local git_root_dir

	git_root_dir="$(runuser -u "$username" -- git -C "$directory" rev-parse --show-toplevel)" || {
		printf '=> Error: cannot determine Git repository root for %s\n' "$directory" >&2
		return 1
	}

	printf '%s\n' "$git_root_dir"
} # }}}

minx_header() { # {{{
	local level="$1"
	shift

	case "$level" in
	L1) minx_print_header '60' '-' "$@" ;;
	L2) minx_print_header '40' '-' "$@" ;;
	L3) minx_print_header '20' '-' "$@" ;;
	*)
		printf '%s\n' "=> Error: Invalid level=$level" >&2
		return 1
		;;
	esac
} # }}}

# minx_download_file <url> <output_file> [sha256]
minx_download_file() { # {{{
	local url="$1"
	local output_file="$2"
	local sha256="${3:-}"
	local part="${output_file}.part"

	if minx_path_exists "$output_file"; then
		printf '=> File %s exists...\n' "$output_file"
	else
		printf '=> Download %s ...\n' "$url"
		curl --progress-bar --fail --location --show-error --retry 10 --retry-delay 15 --retry-all-errors \
			--output "$part" "$url" || {
			rm -f -- "$part"
			return 1
		}
		mv -f -- "$part" "$output_file" || return 1
	fi

	if [[ -n "$sha256" ]]; then
		if ! printf '%s  %s\n' "$sha256" "$output_file" | sha256sum --check --status; then
			printf '=> Error: SHA-256 mismatch for %s\n' "$output_file" >&2
			return 1
		fi
		printf '=> SHA-256 OK: %s\n' "$output_file"
	fi
} # }}}

_load_pinned_versions() { # {{{
	local pinned_file="$MINX_INSTALLER_ROOT/install/config/pinned_versions.txt"
	local line key value

	declare -gA MINX_PINNED_VERSIONS=()

	[[ -f "$pinned_file" ]] || {
		printf '%s\n' "=> Pinned versions file not found: $pinned_file" >&2
		return 1
	}

	while IFS= read -r line || [[ -n "$line" ]]; do
		# Strip comments.
		line="${line%%#*}"

		# Skip empty lines.
		[[ "$line" =~ ^[[:space:]]*$ ]] && continue

		if [[ "$line" =~ ^[[:space:]]*([[:alnum:]_.-]+)[[:space:]]*=[[:space:]]*([^[:space:]]+)[[:space:]]*$ ]]; then
			key="${BASH_REMATCH[1]}"
			value="${BASH_REMATCH[2]}"
			MINX_PINNED_VERSIONS["$key"]="$value"
		else
			printf '%s\n' "=> Invalid entry in $pinned_file: $line" >&2
			return 1
		fi
	done <"$pinned_file"
} # }}}

minx_create_base_dirs() { # {{{
	mkdir -p "$MINX_INSTALLATION_DIR" || return 1
	mkdir -p "$MINX_INFO_DIR" || return 1
	mkdir -p "$MINX_LOG_DIR" || return 1
	mkdir -p "$MINX_REPOS_DIR" || return 1

	# Everyone can create files, but users can only delete/rename files they own (or root can).
	chmod 1777 "$MINX_LOG_DIR"
	# NOTE: world-writable repos dir lets any local user plant a hostile .git/config
	# that root may later run git against. Kept because other scripts may build
	# here as a normal user; tighten to 0755 root:root if they do not.
	chmod 1777 "$MINX_REPOS_DIR"

	minx_register_commit
} # }}}

minx_register_commit() { # {{{
	local repo_dir="$MINX_INSTALLER_ROOT"
	local state_file="$MINX_INSTALLATION_DIR/version"
	local old_commit=""
	local commit=""
	local version=""

	# The repo is usually user-owned while this runs as root.
	local git_cmd=(git -c "safe.directory=$repo_dir" -C "$repo_dir")

	if [[ -f "$state_file" ]]; then
		old_commit="$(cat "$state_file")"
	fi

	commit="$("${git_cmd[@]}" rev-parse HEAD)" || {
		printf '=> Failed to determine Git commit in %s\n' "$repo_dir" >&2
		return 1
	}

	if [[ -n "$("${git_cmd[@]}" status --porcelain)" ]]; then
		version="$commit - dirty"
	else
		version="$commit"
	fi

	printf '%s\n' "$version" >"$state_file" || {
		printf '=> Failed to write install state to %s\n' "$state_file" >&2
		return 1
	}

	printf '=> Registered version:\n'
	printf '=> previous: %s\n' "$old_commit"
	printf '=> current : %s\n' "$version"
} # }}}

minx_write_info() { # {{{
	local filename="$1"
	local content="$2"

	printf '%s\n' "$content" >"$MINX_INFO_DIR/$filename"
} # }}}

minx_load_info() { # {{{
	local filename="$1"
	local file
	local available

	file="$MINX_INFO_DIR/$filename"

	if [[ "$filename" == */* || "$filename" == ..* ]]; then
		printf "=> Error: invalid info filename: '%s'\n" "$filename" >&2
		return 1
	fi

	if [[ -f "$file" ]]; then
		if [[ ! -s "$file" ]]; then
			printf "=> Error: file is empty: '%s'\n" "$file" >&2
			return 1
		fi

		cat -- "$file"
		return
	fi

	available="$(
		find "$MINX_INFO_DIR" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null
	)"

	printf "=> Error: '%s' not found.\n" "$filename" >&2
	printf "=> Available files are:\n%s\n" "$available" >&2
	return 1
} # }}}

# Print a command (shell-quoted) and run it.
minx_run() { # {{{
	printf '$'
	printf ' %q' "$@"
	printf '\n'
	"$@"
} # }}}

minx_verify_sha256() { # <file> <expected-sha256>
	local file="$1" expected="${2:-}" actual

	if [[ -z "$expected" ]]; then
		printf '=> [FAIL] No sha256 pinned for %s\n' "$file" >&2
		return 1
	fi

	actual="$(sha256sum -- "$file" | cut -d' ' -f1)" || return 1

	if [[ "$actual" != "$expected" ]]; then
		printf '=> [FAIL] sha256 mismatch: %s\n' "$file" >&2
		printf '   expected: %s\n   actual:   %s\n' "$expected" "$actual" >&2
		return 1
	fi

	printf '=> sha256 OK: %s\n' "${file##*/}"
}

# --------------------------------------
# Load install configuration
# --------------------------------------

MINX_INSTALLER_ROOT="$(_get_installer_root)" || exit 1
readonly MINX_INSTALLER_ROOT

source "$MINX_INSTALLER_ROOT/install/config/minx.conf"

: "${MXC_USER_FILES_DIR:?Variable not set or empty}"
: "${MXC_USER_REPOS_DIR:?Variable not set or empty}"
: "${MXC_USER_NOTES_DIR:?Variable not set or empty}"
: "${MXC_USER_REFERENCE_FILE:?Variable not set or empty}"
: "${MXC_USER_CPP_PROJECT_LIST:?Variable not set or empty}"
: "${MXC_REMOTE_SSH_SERVER:?Variable not set or empty}"
: "${MXC_REMOTE_BAREREPOS_DIR:?Variable not set or empty}"
: "${MXC_REMOTE_FILES_DIR:?Variable not set or empty}"
: "${MXC_REMOTE_BINARIES_DIR:?Variable not set or empty}"
: "${MXC_INSTALLATION_DIR:?Variable not set or empty}"
: "${MXC_PROFILES_DIR:?Variable not set or empty}"

# --------------------------------------
# Directories
# --------------------------------------
readonly MINX_INSTALLER_PATCHES_DIR="$MINX_INSTALLER_ROOT/install/patches"
readonly MINX_INSTALLER_SERVICES_DIR="$MINX_INSTALLER_ROOT/install/services"

readonly MINX_INSTALLATION_DIR="$MXC_INSTALLATION_DIR"
readonly MINX_INFO_DIR="$MINX_INSTALLATION_DIR/info"
readonly MINX_LOG_DIR="$MINX_INSTALLATION_DIR/logs"
readonly MINX_REPOS_DIR="$MINX_INSTALLATION_DIR/repos"
readonly MINX_DOWNLOADS_DIR="$MINX_INSTALLATION_DIR/repos/downloads"

# --------------------------------------
# Variables
# --------------------------------------
_load_pinned_versions || exit 1
readonly MINX_PINNED_VERSIONS
readonly MINX_INTEL="GenuineIntel"
readonly MINX_AMD="AuthenticAMD"

readonly MINX_INSTALL_UTILS_LOADED=1
