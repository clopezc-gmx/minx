#!/usr/bin/env bash
#
# minx utils -- base library, meant to be sourced (idempotent).
# Requires bash >= 4.3 (associative arrays, namerefs).
#
# Sections:
#   1. Logging
#   2. Checks and assertions
#   3. Printing and running commands
#   4. Filesystem (symlink / move / copy / maps / PATH / safe rm)
#   5. Templates (render, install rendered file)
#   6. Git
#   7. Downloads and checksums
#   8. System information (cpu, device, os, target user)
#   9. Installation state (info store, version, installation type)
#  10. Configuration loading
#
# Functions prefixed with "_minx_" are private to this file.
#
# shellcheck disable=SC2034 # Variables used by sourced scripts.
# shellcheck disable=SC1091 # Paths resolved at runtime.

if [[ -n "${MINX_INSTALL_UTILS_LOADED:-}" ]]; then
	return 0
fi

# =============================================================================
# 1. Logging
# =============================================================================

minx_log() { printf '%s\n' "=> $*"; }
minx_section() { printf '\n%s\n' "=> $*"; }
minx_pass() { printf '%s\n' "=> [PASS] $*"; }
minx_diag() { printf '%s\n' "=> [DIAG] $*"; }
minx_warn() { printf '%s\n' "=> [WARN] $*" >&2; }
minx_log_server_skip() { printf '\n%s\n' "=> [server installation] -- $*"; }

# Prints the message to stderr and returns 1, so callers can write:
#   cmd || { minx_fail "message"; return 1; }
minx_fail() {
	printf '%s\n' "=> [FAIL] $*" >&2
	return 1
}

# =============================================================================
# 2. Checks and assertions
# =============================================================================

minx_path_exists() { # {{{
	local path="$1"
	[[ -e "$path" || -L "$path" ]]
} # }}}

minx_command_exists() { # {{{
	command -v "$1" >/dev/null 2>&1
} # }}}

minx_assert_is_root() { # {{{
	local name="${1:-${0##*/}}"

	if ((EUID != 0)); then
		minx_fail "Run \"$name\" as ROOT."
		return 1
	fi
} # }}}

minx_assert_is_non_root() { # {{{
	local name="${1:-${0##*/}}"

	if ((EUID == 0)); then
		minx_fail "Run \"$name\" as NON-ROOT."
		return 1
	fi
} # }}}

# minx_assert_equal <actual> <expected> [message]
minx_assert_equal() { # {{{
	local msg="${3:-}"

	if [[ "$1" != "$2" ]]; then
		minx_fail "'$1' != '$2'${msg:+ ($msg)}"
		return 1
	fi
} # }}}

# Quiet predicate: 0 (true) when a graphical session is available.
minx_has_display() { # {{{
	[[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]
} # }}}

# 0 (true), 1 (false), prints an error when false.
minx_assert_has_display() { # {{{
	if ! minx_has_display; then
		minx_fail "No display found. Please ensure you are running in a graphical environment."
		return 1
	fi
} # }}}

# =============================================================================
# 3. Printing and running commands
# =============================================================================

# minx_print_header <num_char> <char> <text...>
minx_print_header() { # {{{
	local num_char="${1:-}"
	local char="${2:-}"
	local sep

	if [[ ! "$num_char" =~ ^[0-9]+$ || ${#char} -ne 1 ]]; then
		printf '%s\n' "Usage: minx_print_header <num_char> <char> <text...>" >&2
		return 1
	fi

	shift 2

	sep="$(printf '%*s' "$num_char" '' | tr ' ' "$char")"

	printf '\n%s\n' "$sep"
	printf '%s\n' "$*"
	printf '%s\n' "$sep"
} # }}}

# minx_header <L1|L2|L3> <text...>
minx_header() { # {{{
	local level="${1:-}"
	shift

	case "$level" in
	L1) minx_print_header 60 '-' "$@" ;;
	L2) minx_print_header 40 '-' "$@" ;;
	L3) minx_print_header 20 '-' "$@" ;;
	*)
		minx_fail "Invalid header level: '$level'"
		return 1
		;;
	esac
} # }}}

# Print a command (shell-quoted) and run it.
minx_run() { # {{{
	printf '$'
	printf ' %q' "$@"
	printf '\n'
	"$@"
} # }}}

# minx_run_and_log <logfile> <command> [args...]
# Runs the command, mirroring output to <logfile>. Returns the command's status.
minx_run_and_log() { # {{{
	local logfile="${1:-}"
	local marker

	if [[ -z "$logfile" || $# -lt 2 ]]; then
		printf '%s\n' "Usage: minx_run_and_log <logfile> <command> [args...]" >&2
		return 1
	fi

	shift

	if [[ -f "$MINX_INSTALLATION_DIR/version" ]]; then
		marker="$(printf '%*s' 80 '' | tr ' ' '*')"

		{
			printf '\n%s\n' "$marker"
			printf '%s\n' "$(date)"
			cat -- "$MINX_INSTALLATION_DIR/version"
			printf '%s\n' "$marker"
		} >>"$logfile" || return 1
	fi

	"$@" 2>&1 | tee -a "$logfile"

	return "${PIPESTATUS[0]}"
} # }}}

minx_get_date() { # {{{
	date +%Y%m%dT%H%M%S
} # }}}

# Name (without extension) of the file that called this function.
minx_get_script_name() { # {{{
	local script_name="${BASH_SOURCE[1]##*/}"
	printf '%s\n' "${script_name%.*}"
} # }}}

# =============================================================================
# 4. Filesystem
# =============================================================================

# minx_safe_rm_dir <absolute_path>
# Removes a path only if it resolves to somewhere below an allowed root.
# The roots are hardcoded on purpose, as a second layer of protection.
minx_safe_rm_dir() { # {{{
	local path="${1:-}"
	local resolved root
	local -a roots=(/tmp)

	[[ -z "${MINX_INSTALLATION_DIR:-}" ]] || roots+=("$MINX_INSTALLATION_DIR")

	if [[ -z "$path" ]]; then
		minx_fail "minx_safe_rm_dir: empty path"
		return 1
	fi

	if [[ "$path" != /* ]]; then
		minx_fail "minx_safe_rm_dir: path must be absolute: $path"
		return 1
	fi

	if ! minx_path_exists "$path"; then
		minx_log "minx_safe_rm_dir: nothing to remove, path does not exist: $path"
		return 0
	fi

	resolved="$(realpath -e -- "$path")" ||
		{
			minx_fail "minx_safe_rm_dir: cannot resolve path: $path"
			return 1
		}

	for root in "${roots[@]}"; do
		if [[ "$resolved" == "$root"/* ]]; then
			rm -rf -- "$resolved"
			return
		fi
	done

	minx_fail "minx_safe_rm_dir: refusing to remove path outside allowed roots: $resolved"
	return 1
} # }}}

# minx_add_to_PATH <absolute_dir>   (root only)
minx_add_to_PATH() { # {{{
	local path="${1:-}"
	local profile_file="/etc/profile.d/minx_profile.sh"
	local line

	minx_assert_is_root minx_add_to_PATH || return 1

	if [[ -z "$path" ]]; then
		minx_fail "minx_add_to_PATH: empty path"
		return 1
	fi

	if [[ "$path" != /* ]]; then
		minx_fail "minx_add_to_PATH: path must be absolute: $path"
		return 1
	fi

	if [[ ! -d "$path" ]]; then
		minx_fail "minx_add_to_PATH: directory does not exist: $path"
		return 1
	fi

	line="export PATH=\"$path:\$PATH\""

	if [[ ! -f "$profile_file" ]]; then
		install -m 0644 /dev/null "$profile_file" || return 1
	fi

	if grep -Fqx -- "$line" "$profile_file"; then
		minx_log "minx_add_to_PATH: already configured in $profile_file: $path"
		return 0
	fi

	printf '%s\n' "$line" >>"$profile_file" || return 1
	minx_log "Added to system PATH: $path"
} # }}}

# minx_symlink <source> <destination>
# Atomically (re)points <destination> at <source>. Never replaces a real file
# or directory, and a bad source never destroys a good existing link.
minx_symlink() { # {{{
	local source="$1"
	local destination="$2"
	local tmp_link

	mkdir -p -- "$(dirname -- "$destination")" || return 1

	if [[ -e "$destination" && ! -L "$destination" ]]; then
		minx_fail "Destination already exists and is not a symlink: $destination"
		return 1
	fi

	# Build the link under a temporary name, verify it resolves, then replace.
	tmp_link="${destination}.minx-tmp.$$"
	rm -f -- "$tmp_link"
	ln -s -- "$source" "$tmp_link" || return 1

	if ! readlink -e -- "$tmp_link" >/dev/null; then
		rm -f -- "$tmp_link"
		minx_fail "Source does not exist: $source"
		return 1
	fi

	minx_log "Linking $destination -> $source"
	mv -T -f -- "$tmp_link" "$destination"
} # }}}

minx_move() { # {{{
	local source="$1"
	local destination="$2"

	mkdir -p -- "$(dirname -- "$destination")" || return 1
	minx_log "Moving $source -> $destination"

	# -T: never move INTO an existing directory; fail loudly instead.
	mv -T -- "$source" "$destination"
} # }}}

minx_copy() { # {{{
	local source="$1"
	local destination="$2"

	minx_log "Copying $source -> $destination"

	if [[ -d "$source" ]]; then
		# Copy contents so a re-run does not nest dest/src.
		mkdir -p -- "$destination" || return 1
		cp -a -- "$source/." "$destination/"
	else
		mkdir -p -- "$(dirname -- "$destination")" || return 1
		cp -af -- "$source" "$destination"
	fi
} # }}}

# _minx_apply_map <operation> <map_name> <skip|fail>
# Applies <operation> <source> <destination> to every [destination]=source
# entry. <skip|fail> says what to do when a source does not exist.
_minx_apply_map() {
	local _op="$1"
	local _on_missing="$3"
	local -n _minx_map="$2"
	local _dst _src

	for _dst in "${!_minx_map[@]}"; do
		_src="${_minx_map[$_dst]}"

		if minx_path_exists "$_src"; then
			"$_op" "$_src" "$_dst" || return 1
		elif [[ "$_on_missing" == skip ]]; then
			minx_log "$_src does not exist, skipping"
		else
			minx_fail "$_src does not exist"
			return 1
		fi
	done
}

# Maps are associative arrays: [destination]=source
minx_symlink_map() { _minx_apply_map minx_symlink "$1" skip; }
minx_move_map() { _minx_apply_map minx_move "$1" skip; }
minx_copy_map() { _minx_apply_map minx_copy "$1" fail; }

# minx_map_paths <map_name> <dst_root> <src_root> <relative_path>...
# Fills the map with [dst_root/rel]=src_root/rel for every relative path.
minx_map_paths() { # {{{
	local -n _minx_paths_map="$1"
	local dst_root="$2"
	local src_root="$3"
	local rel

	shift 3

	for rel in "$@"; do
		_minx_paths_map["$dst_root/$rel"]="$src_root/$rel"
	done
} # }}}

# =============================================================================
# 5. Templates
# =============================================================================

_minx_sed_escape() {
	printf '%s' "$1" | sed 's/[\\&|]/\\&/g'
}

# minx_render_template <src> <dst> [target_user target_home]
#
# Replaces @@MINX_NAME@@ (and the legacy form @MINX_NAME@@) with $MINX_NAME,
# falling back to $MXC_NAME. If the template uses the legacy @TARGET_USER@ /
# @TARGET_HOME@ placeholders, target_user and target_home must be given.
# Fails if any placeholder is left unresolved.
minx_render_template() {
	local src="$1" dst="$2"
	local target_user="${3:-}" target_home="${4:-}"
	local name ref legacy value escaped

	local -a names=()
	local -a sed_args=(-e '') # keeps sed valid even without placeholders

	if [[ ! -r "$src" ]]; then
		minx_fail "Cannot read template: $src"
		return 1
	fi

	mapfile -t names < <(
		grep -oE '@{1,2}MINX_[A-Z0-9_]+@@' -- "$src" |
			sed -E 's/^@+MINX_//; s/@+$//' |
			sort -u
	)

	for name in "${names[@]}"; do
		ref="MINX_$name"
		legacy="MXC_$name"

		value="${!ref:-}"
		[[ -n "$value" ]] || value="${!legacy:-}"

		if [[ -z "$value" ]]; then
			minx_fail "$ref (or $legacy) is not set or empty"
			return 1
		fi

		escaped="$(_minx_sed_escape "$value")"
		sed_args+=(
			-e "s|@@MINX_${name}@@|${escaped}|g"
			-e "s|@MINX_${name}@@|${escaped}|g"
		)
	done

	if grep -qE '@TARGET_(USER|HOME)@' -- "$src"; then
		if [[ -z "$target_user" || -z "$target_home" ]]; then
			minx_fail "Template uses @TARGET_*@ but no target user was given: $src"
			return 1
		fi

		sed_args+=(
			-e "s|@TARGET_USER@|$(_minx_sed_escape "$target_user")|g"
			-e "s|@TARGET_HOME@|$(_minx_sed_escape "$target_home")|g"
		)
	fi

	if ! sed "${sed_args[@]}" -- "$src" >"$dst"; then
		rm -f -- "$dst"
		minx_fail "Failed to render: $src"
		return 1
	fi

	if grep -qE '@+MINX_[A-Z0-9_]+@@|@@[A-Z0-9_]+@@|@TARGET_(USER|HOME)@' -- "$dst"; then
		rm -f -- "$dst"
		minx_fail "Unresolved placeholder in: $src"
		return 1
	fi
}

# minx_install_rendered_file <src> <dst> <mode> [target_user target_home]
# Renders the template next to its destination, then moves it into place
# atomically as root:root with the given mode (root only). target_user and
# target_home are only needed for templates using @TARGET_*@ placeholders.
minx_install_rendered_file() {
	local src="$1" dst="$2" mode="$3" target_user="${4:-}" target_home="${5:-}"
	local tmp

	tmp="$(mktemp -- "${dst}.XXXXXX")" ||
		{
			minx_fail "mktemp failed for: $dst"
			return 1
		}

	minx_render_template "$src" "$tmp" "$target_user" "$target_home" ||
		{
			rm -f -- "$tmp"
			return 1
		}

	if ! chown root:root -- "$tmp" ||
		! chmod "$mode" -- "$tmp" ||
		! mv -f -- "$tmp" "$dst"; then
		rm -f -- "$tmp"
		minx_fail "Failed to install: $dst"
		return 1
	fi

	minx_diag "Installed: $dst"
	ls -l -- "$dst"
}

# =============================================================================
# 6. Git
# =============================================================================

# Exit status 0 when the working tree has staged, unstaged or untracked changes.
_minx_git_is_dirty() {
	local dir="$1"

	! git -C "$dir" diff --quiet ||
		! git -C "$dir" diff --cached --quiet ||
		[[ -n "$(git -C "$dir" ls-files --others --exclude-standard)" ]]
}

# Prints the absolute path of a patch file. Needed because "git -C <dir> apply"
# resolves relative paths against <dir>, not against the caller's directory.
_minx_resolve_patch_file() {
	if [[ ! -f "$1" ]]; then
		minx_fail "Patch file does not exist: $1"
		return 1
	fi

	realpath -- "$1"
}

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
	local app current_commit
	local at_target=0
	local patched=0

	if [[ -z "$app_dir" || -z "$url" || -z "$commit" ]]; then
		printf '%s\n' "Usage: minx_git_clone_at_commit <directory> <url> <commit> [patch_file]" >&2
		return 1
	fi

	app_dir="${app_dir%/}"
	app="${app_dir##*/}"

	if [[ ! "$commit" =~ ^[0-9a-f]{7,64}$ ]]; then
		minx_fail "Commit must be a hex hash (7-64 chars): $commit"
		return 1
	fi

	if [[ -n "$patch_file" ]]; then
		patch_file="$(_minx_resolve_patch_file "$patch_file")" || return 1
	fi

	if [[ ! -d "$app_dir/.git" ]]; then
		if minx_path_exists "$app_dir"; then
			minx_fail "$app_dir exists but is not a Git repository."
			return 1
		fi

		minx_log "Cloning $app."
		git clone -- "$url" "$app_dir" ||
			{
				minx_fail "Failed to clone $url into $app_dir."
				return 1
			}
	fi

	current_commit="$(git -C "$app_dir" rev-parse HEAD)" || return 1

	if [[ "$current_commit" == "$commit"* ]]; then
		at_target=1
	fi

	if [[ -n "$patch_file" ]] &&
		git -C "$app_dir" apply --reverse --check "$patch_file" 2>/dev/null; then
		patched=1
	fi

	if ((at_target && patched)); then
		minx_log "$app already at commit $commit with patch applied."
	else
		if _minx_git_is_dirty "$app_dir"; then
			minx_log "Force reset: discarding local changes in $app."
			git -C "$app_dir" reset --hard HEAD || return 1
			git -C "$app_dir" clean -fd || return 1
		fi

		if ((! at_target)); then
			# Only hit the network when the commit is not available locally.
			if ! git -C "$app_dir" cat-file -e "$commit^{commit}" 2>/dev/null; then
				minx_log "Fetching $app at commit $commit."

				git -C "$app_dir" fetch --tags origin ||
					{
						minx_fail "Failed to fetch repository for $app."
						return 1
					}

				if ! git -C "$app_dir" cat-file -e "$commit^{commit}" 2>/dev/null; then
					minx_fail "Commit $commit not found in $app."
					return 1
				fi
			fi

			git -C "$app_dir" checkout --detach "$commit" ||
				{
					minx_fail "Failed to checkout commit $commit for $app."
					return 1
				}
		fi
	fi

	current_commit="$(git -C "$app_dir" rev-parse HEAD)" || return 1

	if [[ "$current_commit" != "$commit"* ]]; then
		minx_fail "Checked out $current_commit, expected $commit."
		return 1
	fi

	minx_log "Updating submodules for $app."

	git -C "$app_dir" submodule update --init --recursive ||
		{
			minx_fail "Failed to update submodules for $app."
			return 1
		}

	minx_log "$app is at commit $current_commit."
} # }}}

# minx_git_clone_and_patch <dir> <url> <commit> [patch_file]
minx_git_clone_and_patch() { # {{{
	local app_dir="${1:-}"
	local url="${2:-}"
	local commit="${3:-}"
	local patch_file="${4:-}"
	local app

	if [[ -n "$patch_file" ]]; then
		patch_file="$(_minx_resolve_patch_file "$patch_file")" || return 1
	fi

	minx_git_clone_at_commit "$app_dir" "$url" "$commit" "$patch_file" || return 1

	[[ -n "$patch_file" ]] || return 0

	app_dir="${app_dir%/}"
	app="${app_dir##*/}"

	if git -C "$app_dir" apply --reverse --check "$patch_file" 2>/dev/null; then
		minx_log "Patch already applied to $app, skipping."
	elif git -C "$app_dir" apply --check "$patch_file"; then
		minx_log "Applying patch to $app."
		git -C "$app_dir" apply "$patch_file" || return 1
	else
		minx_fail "Patch cannot be applied to $app: $patch_file"
		return 1
	fi
} # }}}

# minx_get_git_root_dir <username> [directory]
minx_get_git_root_dir() { # {{{
	local username="$1"
	local directory="${2:-.}"
	local git_root_dir

	git_root_dir="$(runuser -u "$username" -- git -C "$directory" rev-parse --show-toplevel)" ||
		{
			minx_fail "Cannot determine Git repository root for $directory"
			return 1
		}

	printf '%s\n' "$git_root_dir"
} # }}}

# =============================================================================
# 7. Downloads and checksums
# =============================================================================

# minx_verify_sha256 <file> <expected_sha256>
minx_verify_sha256() { # {{{
	local file="$1"
	local expected="${2:-}"
	local actual

	if [[ -z "$expected" ]]; then
		minx_fail "No sha256 pinned for $file"
		return 1
	fi

	actual="$(sha256sum -- "$file")" || return 1
	actual="${actual%% *}"

	if [[ "$actual" != "$expected" ]]; then
		minx_fail "sha256 mismatch: $file"
		printf '   expected: %s\n   actual:   %s\n' "$expected" "$actual" >&2
		return 1
	fi

	minx_log "sha256 OK: ${file##*/}"
} # }}}

# minx_download_file <url> <output_file> [sha256]
# An existing output file is kept. A freshly downloaded file that fails the
# checksum is removed, so a bad download is never mistaken for a cached one.
minx_download_file() { # {{{
	local url="$1"
	local output_file="$2"
	local sha256="${3:-}"
	local part="${output_file}.part"
	local fresh=0

	if minx_path_exists "$output_file"; then
		minx_log "File $output_file exists..."
	else
		mkdir -p -- "$(dirname -- "$output_file")" || return 1

		minx_log "Download $url ..."

		curl --progress-bar --fail --location --show-error \
			--retry 10 --retry-delay 15 --retry-all-errors \
			--output "$part" "$url" ||
			{
				rm -f -- "$part"
				return 1
			}

		mv -f -- "$part" "$output_file" || return 1
		fresh=1
	fi

	if [[ -n "$sha256" ]] && ! minx_verify_sha256 "$output_file" "$sha256"; then
		((! fresh)) || rm -f -- "$output_file"
		return 1
	fi
} # }}}

# =============================================================================
# 8. System information
# =============================================================================

minx_get_cpu_vendor() { # {{{
	local vendor

	vendor="$(awk -F: '/^vendor_id/ {gsub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo)"

	if [[ "$vendor" != "$MINX_INTEL" && "$vendor" != "$MINX_AMD" ]]; then
		minx_fail "Unknown CPU vendor: '$vendor'"
		return 1
	fi

	printf '%s\n' "$vendor"
} # }}}

minx_get_device_type() { # {{{
	# The file is missing in some VMs and containers.
	local chassis_type
	chassis_type="$(cat /sys/class/dmi/id/chassis_type 2>/dev/null || true)"

	# 8 portable, 9 laptop, 10 notebook, 11 handheld, 14 sub-notebook,
	# 30 tablet, 31 convertible, 32 detachable.
	if [[ "$chassis_type" =~ ^(8|9|10|11|14|30|31|32)$ ]]; then
		printf '%s\n' "portable"
	else
		printf '%s\n' "not-portable"
	fi
} # }}}

# minx_get_target_info <out_user_var> <out_home_var>
# The target user is the human behind sudo/su: $SUDO_USER, else logname.
minx_get_target_info() {
	local -n _tgt_user="$1" _tgt_home="$2"

	_tgt_user="${SUDO_USER:-}"
	[[ -n "$_tgt_user" ]] || _tgt_user="$(logname 2>/dev/null || true)"

	if [[ -z "$_tgt_user" || "$_tgt_user" == root ]]; then
		minx_fail "Could not determine target user"
		return 1
	fi

	if ! id "$_tgt_user" >/dev/null 2>&1; then
		minx_fail "Target user does not exist: $_tgt_user"
		return 1
	fi

	minx_log "Target user: $_tgt_user"

	_tgt_home="$(getent passwd "$_tgt_user" | cut -d: -f6)"

	if [[ -z "$_tgt_home" ]]; then
		minx_fail "Could not determine home for: $_tgt_user"
		return 1
	fi

	minx_log "Target home: $_tgt_home"
}

minx_get_os_codename() { # {{{
	# lsb_release is not part of a minimal Debian; /etc/os-release always is.
	(
		. /etc/os-release
		printf '%s\n' "${VERSION_CODENAME:-}"
	)
} # }}}

# =============================================================================
# 9. Installation state
# =============================================================================

# --- info store ---------------------------------------------------------------

# Info file names are plain file names: no slashes, no hidden (dot) files.
_minx_check_info_name() {
	if [[ -z "$1" || "$1" == */* || "$1" == .* ]]; then
		minx_fail "Invalid info filename: '$1'"
		return 1
	fi
}

minx_write_info() { # {{{
	local filename="$1"
	local content="$2"

	_minx_check_info_name "$filename" || return 1

	printf '%s\n' "$content" >"$MINX_INFO_DIR/$filename"
} # }}}

minx_load_info() { # {{{
	local filename="$1"
	local file="$MINX_INFO_DIR/$filename"
	local available

	_minx_check_info_name "$filename" || return 1

	if [[ -f "$file" ]]; then
		if [[ ! -s "$file" ]]; then
			minx_fail "File is empty: '$file'"
			return 1
		fi

		cat -- "$file"
		return
	fi

	available="$(find "$MINX_INFO_DIR" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null)"

	minx_fail "'$filename' not found."
	printf '%s\n%s\n' "=> Available files are:" "$available" >&2
	return 1
} # }}}

# Cross-checks the stored info against the live system.
minx_test_all_info() { # {{{
	local value

	value="$(minx_load_info codename)" || return 1
	minx_assert_equal "$value" "$(minx_get_os_codename)" "codename" || return 1

	value="$(minx_load_info hostname)" || return 1
	minx_assert_equal "$value" "$(hostname)" "hostname" || return 1

	value="$(minx_load_info cpu_vendor)" || return 1
	minx_assert_equal "$value" "$(minx_get_cpu_vendor)" "cpu_vendor" || return 1

	value="$(minx_load_info device_type)" || return 1
	minx_assert_equal "$value" "$(minx_get_device_type)" "device_type" || return 1

	# Must be "none" or a suite name such as "trixie-backports".
	value="$(minx_load_info backports)" || return 1
	if [[ ! "$value" =~ ^[a-z0-9-]+$ ]]; then
		minx_fail "Invalid backports value: '$value'"
		return 1
	fi
} # }}}

# --- base dirs and version ------------------------------------------------------

minx_create_base_dirs() { # {{{
	mkdir -p -- \
		"$MINX_INSTALLATION_DIR" \
		"$MINX_INFO_DIR" \
		"$MINX_LOG_DIR" \
		"$MINX_REPOS_DIR" || return 1

	# Everyone can create files, but users can only delete/rename their own.
	chmod 1777 "$MINX_LOG_DIR" || return 1

	# NOTE: a world-writable repos dir lets any local user plant a hostile
	# .git/config that root may later run git against. Kept because other
	# scripts may build here as a normal user; tighten to 0755 root:root if
	# they do not.
	chmod 1777 "$MINX_REPOS_DIR" || return 1

	minx_register_commit
} # }}}

minx_register_commit() { # {{{
	local repo_dir="$MINX_INSTALLER_ROOT"
	local state_file="$MINX_INSTALLATION_DIR/version"
	local old_commit=""
	local commit dirty version

	# The repo is usually user-owned while this runs as root.
	local -a git_cmd=(git -c "safe.directory=$repo_dir" -C "$repo_dir")

	if [[ -f "$state_file" ]]; then
		old_commit="$(<"$state_file")"
	fi

	commit="$("${git_cmd[@]}" rev-parse HEAD)" ||
		{
			minx_fail "Failed to determine Git commit in $repo_dir"
			return 1
		}

	dirty="$("${git_cmd[@]}" status --porcelain)" ||
		{
			minx_fail "Failed to determine Git status in $repo_dir"
			return 1
		}

	version="$commit"
	[[ -z "$dirty" ]] || version="$commit - dirty"

	printf '%s\n' "$version" >"$state_file" ||
		{
			minx_fail "Failed to write install state to $state_file"
			return 1
		}

	minx_log "Registered version:"
	minx_log "previous: $old_commit"
	minx_log "current : $version"
} # }}}

# --- installation type ------------------------------------------------------------

# Prints "desktop" or "server".
minx_load_installation_type() { # {{{
	local file="$MINX_INFO_DIR/minx_installation_type"
	local variant

	if [[ ! -e "$file" ]]; then
		minx_fail "$file does not exist. Run 00_root_init.sh."
		return 1
	fi

	variant="$(<"$file")"

	case "$variant" in
	desktop | server) printf '%s\n' "$variant" ;;
	*)
		minx_fail "Invalid value for minx_installation_type: '$variant' (expected 'desktop' or 'server')."
		return 1
		;;
	esac
} # }}}

# Quiet predicates (0 = true, 1 = false). Use these in conditionals.
minx_is_desktop_install() { [[ "$(minx_load_installation_type)" == desktop ]]; }
minx_is_server_install() { [[ "$(minx_load_installation_type)" == server ]]; }

# Assertions: same checks, but print an error when they fail.
minx_assert_is_desktop_install() { # {{{
	local installation_type

	installation_type="$(minx_load_installation_type)" || return 1

	if [[ "$installation_type" != desktop ]]; then
		minx_fail "minx_assert_is_desktop_install: desktop != $installation_type"
		return 1
	fi
} # }}}

minx_assert_is_server_install() { # {{{
	local installation_type

	installation_type="$(minx_load_installation_type)" || return 1

	if [[ "$installation_type" != server ]]; then
		minx_fail "minx_assert_is_server_install: server != $installation_type"
		return 1
	fi
} # }}}

# Returns 0 (skip) on a server install without display, 1 (carry on) otherwise.
# Usage: minx_skip_in_server_install "name" && return 0
minx_skip_in_server_install() { # {{{
	minx_is_server_install || return 1
	minx_has_display && return 1

	minx_log "[Server install] no display, skipping $1."
	return 0
} # }}}

# For two-phase installers (build as user, install as root).
#   --build:   skip when there is no display
#   --install: skip when the build output is missing
# Returns 0 (skip) or 1 (carry on); 2 on a usage error.
# Usage: minx_skip_unless_built "$ACTION" "name" "/path/to/output" && return 0
minx_skip_unless_built() { # <action> <label> <build-output-path> {{{
	local action="$1"
	local label="$2"
	local output="$3"

	case "$action" in
	--build | build)
		minx_has_display && return 1
		minx_log "No display, skipping build of $label."
		return 0
		;;
	--install | install)
		minx_path_exists "$output" && return 1
		minx_log "No build output ($output), skipping install of $label."
		return 0
		;;
	*)
		minx_fail "minx_skip_unless_built: unknown action '$action' (expected --build or --install)"
		return 2
		;;
	esac
} # }}}

# =============================================================================
# 10. Configuration loading
# =============================================================================

# Resolves the root of the installer git repository (three levels above this file).
_minx_get_installer_root() {
	local script_dir minx_root

	script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || return 1

	minx_root="$(cd -- "$script_dir/../../.." 2>/dev/null && pwd)" ||
		{
			minx_fail "$script_dir/../../.. does not exist or is not a directory"
			return 1
		}

	if ! minx_path_exists "$minx_root/.git"; then
		minx_fail "$minx_root is not a root git repository"
		return 1
	fi

	printf '%s\n' "$minx_root"
}

# Exports every MXC_<NAME> from minx.conf as a readonly MINX_<NAME>.
_minx_import_conf() {
	local name ref

	for name in \
		USER_ASSETS_DIR \
		USER_REPOS_DIR \
		USER_DOCUMENTS_DIR \
		USER_REFERENCE_FILE \
		USER_CPP_PROJECT_LIST \
		REMOTE_SSH_SERVER \
		REMOTE_BAREREPOS_DIR \
		REMOTE_ASSETS_BASEDIR \
		REMOTE_BINARIES_DIR \
		INSTALLATION_DIR \
		PROFILES_DIR; do

		ref="MXC_$name"

		if [[ -z "${!ref:-}" ]]; then
			minx_fail "$ref is not set or empty (see minx.conf)"
			return 1
		fi

		declare -gr "MINX_$name=${!ref}"
	done

	# Other scripts rm -rf below this directory: it must be absolute and not "/".
	if [[ "$MINX_INSTALLATION_DIR" != /?* ]]; then
		minx_fail "MXC_INSTALLATION_DIR must be an absolute path other than /: $MINX_INSTALLATION_DIR"
		return 1
	fi
}

# Fills the global associative array MINX_PINNED_VERSIONS from pinned_versions.txt
# (lines of "key = value", with "#" comments).
_minx_load_pinned_versions() {
	local pinned_file="$MINX_INSTALLER_ROOT/install/config/pinned_versions.txt"
	local line key value

	declare -gA MINX_PINNED_VERSIONS=()

	if [[ ! -f "$pinned_file" ]]; then
		minx_fail "Pinned versions file not found: $pinned_file"
		return 1
	fi

	while IFS= read -r line || [[ -n "$line" ]]; do
		line="${line%%#*}"

		[[ "$line" =~ ^[[:space:]]*$ ]] && continue

		if [[ "$line" =~ ^[[:space:]]*([[:alnum:]_.-]+)[[:space:]]*=[[:space:]]*([^[:space:]]+)[[:space:]]*$ ]]; then
			key="${BASH_REMATCH[1]}"
			value="${BASH_REMATCH[2]}"
			MINX_PINNED_VERSIONS["$key"]="$value"
		else
			minx_fail "Invalid entry in $pinned_file: $line"
			return 1
		fi
	done <"$pinned_file"
}

MINX_INSTALLER_ROOT="$(_minx_get_installer_root)" || return 1
readonly MINX_INSTALLER_ROOT

source "$MINX_INSTALLER_ROOT/install/config/minx.conf" || return 1
_minx_import_conf || return 1

# --- directories ----------------------------------------------------------------

readonly MINX_INSTALLER_PATCHES_DIR="$MINX_INSTALLER_ROOT/install/patches"
readonly MINX_INSTALLER_SERVICES_DIR="$MINX_INSTALLER_ROOT/install/services"

readonly MINX_INFO_DIR="$MINX_INSTALLATION_DIR/info"
readonly MINX_LOG_DIR="$MINX_INSTALLATION_DIR/logs"
readonly MINX_REPOS_DIR="$MINX_INSTALLATION_DIR/repos"
readonly MINX_DOWNLOADS_DIR="$MINX_REPOS_DIR/downloads"

# --- constants --------------------------------------------------------------------

_minx_load_pinned_versions || return 1
readonly MINX_PINNED_VERSIONS

readonly MINX_INTEL="GenuineIntel"
readonly MINX_AMD="AuthenticAMD"

readonly MINX_INSTALL_UTILS_LOADED=1
