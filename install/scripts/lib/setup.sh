#!/usr/bin/env bash
#
# minx installer library -- meant to be sourced, not executed.
# Requires bash >= 4.3 (associative arrays, namerefs).
#
# Public functions:
#   minx_backup_user_rc_files     minx_restore_user_rc_files
#   minx_backup_root_rc_files     minx_restore_root_rc_files
#   minx_install_mime_types
#   minx_clone_personal_repos     minx_install_user_services
#   minx_install_system_services
#   minx_install_tt               minx_install_wikiviewer
#
# Depends on minx_utils.sh (logging, role/installation checks, symlink/move
# maps, config variables such as MINX_USER_REPOS_DIR). Everything prefixed with
# "_minx_" is private to this file.

if [[ -z "${MINX_INSTALL_UTILS_LOADED:-}" ]]; then
	printf '%s\n' "=> [FAIL] minx_utils.sh must be sourced before this file" >&2
	return 1
fi

# =============================================================================
# Private helpers
# =============================================================================

_minx_rc_backup_dir() {
	printf '%s\n' "$HOME/.backups/.rc_$(minx_get_date)"
}

# =============================================================================
# Private helpers: git
# =============================================================================

# _minx_clone_repo <name> <dest> <remote_prefix>
# Clones "<remote_prefix>$MINX_REMOTE_BAREREPOS_DIR/<name>.git" into <dest>.
_minx_clone_repo() {
	local repo="$1" dest="$2" remote="$3"

	if [[ -d "$dest/.git" ]]; then
		minx_log "$repo already exists, skipping clone."
		return 0
	fi

	if [[ -e "$dest" ]]; then
		minx_fail "Destination exists but is not a Git repository: $dest"
		return 1
	fi

	minx_log "Cloning $repo..."

	git clone -- "${remote}${MINX_REMOTE_BAREREPOS_DIR}/${repo}.git" "$dest" ||
		{
			minx_fail "Failed to clone $repo"
			return 1
		}
}

# =============================================================================
# Dotfiles: user
# =============================================================================

# Relative paths (to $HOME and to the dotfiles repo) that are symlinked files.
_minx_user_rc_files() { # out_array_name
	local -n _out="$1"

	_out=(
		.bashrc
		.gitconfig
		.gitconfig-mpcdf
		.gitconfig-personal
		.gitignore-global
		.inputrc
		.profile
		.vimrc
		.notmuch-config
	)

	minx_is_desktop_install || return 0

	_out+=(
		.gnupg/gpg-agent.conf
		.mail/.aliases
		.mailcap
		.mbsyncrc
		.msmtprc
		.ssh/config
		.taskrc
		.tmux.conf
		.xinitrc
		.xsetroot.sh
	)
}

# Relative paths that are symlinked directories (same name in the dotfiles repo).
_minx_user_rc_dirs() { # out_array_name

	# shellcheck disable=SC2178 #variable passed as reference
	local -n _out="$1"

	_out=(
		.bashrc.d
		.config/pre-commit
		.config/ranger
		.config/vale
		.config/vdirsyncer
		.vim
	)

	minx_is_desktop_install || return 0

	_out+=(
		.config/notmuc
		.config/neomutt
		.config/khal
		.config/rofi
		.config/dunst
		.config/vale
		.config/redshift
		.config/qutebrowser

		.task
		.newsboat
	)
}

minx_backup_user_rc_files() { # {{{

	minx_assert_is_non_root || return 1

	minx_section "Backing up existing dotfiles"

	mkdir -p -- "$HOME/.backups/.config" || return 1

	local backup_dir
	backup_dir="$(_minx_rc_backup_dir)"

	local -a files=() dirs=()
	_minx_user_rc_files files
	_minx_user_rc_dirs dirs

	local -A files_map=() folder_map=() # [dst]=src
	minx_map_paths files_map "$backup_dir" "$HOME" "${files[@]}"
	minx_map_paths folder_map "$backup_dir" "$HOME" "${dirs[@]}"

	minx_move_map files_map || return 1
	minx_move_map folder_map || return 1
} # }}}

minx_restore_user_rc_files() { # {{{

	minx_assert_is_non_root || return 1

	minx_backup_user_rc_files || return 1

	local dotfiles="$MINX_PROFILES_DIR/user/dotfiles"

	mkdir -p "$HOME/.config"

	local -a files=() dirs=()
	_minx_user_rc_files files
	_minx_user_rc_dirs dirs

	# shellcheck disable=SC2034 # maps are passed by name to the helpers below
	local -A files_map=() folder_map=() # [dst]=src
	minx_map_paths files_map "$HOME" "$dotfiles" "${files[@]}"
	minx_map_paths folder_map "$HOME" "$dotfiles" "${dirs[@]}"

	# Private dirs first; minx_symlink creates every other parent itself.
	if minx_is_desktop_install; then
		mkdir -p -- "$HOME/.ssh" "$HOME/.gnupg" || return 1
		chmod 700 -- "$HOME/.ssh" "$HOME/.gnupg" || return 1
	fi

	minx_symlink_map files_map || return 1
	minx_symlink_map folder_map || return 1
} # }}}

# =============================================================================
# Dotfiles: root
# =============================================================================

minx_backup_root_rc_files() { # {{{
	minx_assert_is_root || return 1

	minx_section "Backing up existing dotfiles"

	mkdir -p -- "$HOME/.backups" || return 1

	local backup_dir
	backup_dir="$(_minx_rc_backup_dir)"

	local -a files=(.bashrc)

	local -A files_map=() # [dst]=src
	minx_map_paths files_map "$backup_dir" "$HOME" "${files[@]}"

	minx_move_map files_map || return 1
} # }}}

minx_restore_root_rc_files() { # {{{

	minx_assert_is_root || return 1

	minx_backup_root_rc_files || return 1

	local -a files=(.bashrc)

	# shellcheck disable=SC2034 # map is passed by name to the helper below
	local -A files_map=() # [dst]=src
	minx_map_paths files_map "$HOME" "$MINX_PROFILES_DIR/root/dotfiles" "${files[@]}"

	minx_symlink_map files_map || return 1
} # }}}

# =============================================================================
# MIME types
# =============================================================================

minx_install_mime_types() { # {{{
	minx_assert_is_non_root || return 1

	if ! minx_is_desktop_install; then
		minx_log_server_skip "Does not include \"custom mime_types\""
		return 0
	fi

	local desktop_dir="$HOME/.local/share/applications"
	local mime_dir="$HOME/.local/share/mime"

	mkdir -p -- "$desktop_dir" "$mime_dir/packages" || return 1

	local -A desktop_files=() # [dst]=src
	local file

	for file in "$MINX_PROFILES_DIR/user/mimetypes"/*.desktop; do
		[[ -f "$file" ]] || continue
		# shellcheck disable=SC2034 # maps are passed by name to the helpers below
		desktop_files["$desktop_dir/${file##*/}"]="$file"
	done

	minx_symlink_map desktop_files || return 1

	update-mime-database "$mime_dir" || return 1
} # }}}

# =============================================================================
# Vim
# =============================================================================

minx_install_vim_vundle() { # {{{
	minx_assert_is_non_root || return 1
	minx_path_exists "$HOME/.vim" || return 1

	local minx_vim_vundle_repo="$MINX_INSTALLATION_DIR/repos/vim_vundle"

	if ! minx_path_exists "$minx_vim_vundle_repo"; then
		printf "=> Vundle.vim does not exist, clone it first with ../01_user_download_repos.sh\n"
		return 1
	fi

	local vundle="$HOME/.vim/bundle/Vundle.vim"
	if [[ -L "$vundle" ]]; then
		rm "$vundle"
	fi

	mkdir -p "$HOME/.vim/bundle"
	ln -s "$minx_vim_vundle_repo" "$vundle"

	vim -es -u ~/.vimrc -i NONE -c "PluginInstall" -c "qa"

} # }}}

# =============================================================================
# Personal repositories
# =============================================================================

minx_clone_personal_repos() { # {{{
	minx_assert_is_non_root || return 1

	local dst_dir="$MINX_USER_REPOS_DIR/personal"

	local -a repos=(
		family-server
		minx-profiles
		mytools.d/wikiviewer
	)

	# Desktops clone over ssh from the server; the server clones from its own
	# local bare repos.
	local remote=""

	if minx_is_desktop_install; then
		remote="$MINX_REMOTE_SSH_SERVER:"

		repos+=(
			.abook
			.password-store
			mytools.d/tt.d/tt-src
			mytools.d/tt.d/tt-data.d/activities
			mytools.d/tt.d/tt-data.d/notes
			mytools.d/tt.d/tt-data.d/goals
			projects.d/coursera.d/cpp-in-scicomp
			projects.d/hpc-python
		)
	fi

	mkdir -p -- "$dst_dir" || return 1

	local repo
	for repo in "${repos[@]}"; do
		_minx_clone_repo "$repo" "$dst_dir/$repo" "$remote" || return 1
	done

	minx_is_desktop_install || return 0

	_minx_clone_repo mydocuments "$MINX_USER_DOCUMENTS_DIR" "$remote" || return 1

	# shellcheck disable=SC2034 # maps are passed by name to the helpers below
	local -A folder_map=( # [dst]=src
		["$HOME/.abook"]="$dst_dir/.abook"
		["$HOME/.password-store"]="$dst_dir/.password-store"
		["$HOME/.timewarrior"]="$dst_dir/mytools.d/tt.d/tt-data.d/activities"
	)

	minx_symlink_map folder_map || return 1
} # }}}

# =============================================================================
# User systemd services
# =============================================================================

# _minx_render_user_units <tmp_dir> <unit>...
_minx_render_user_units() {
	local tmp_dir="$1"
	local unit
	shift

	minx_log "Rendering user systemd units"

	for unit in "$@"; do
		minx_render_template \
			"$MINX_INSTALLER_SERVICES_DIR/user/$unit" "$tmp_dir/$unit" || return 1

		chmod 0644 -- "$tmp_dir/$unit" ||
			{
				minx_fail "Failed to set permissions: $tmp_dir/$unit"
				return 1
			}

		minx_pass "Rendered $unit"
	done
}

# _minx_replace_user_units <tmp_dir> <dest_dir> <unit>...
# Stops/removes any installed copy of each unit, then installs the rendered one.
_minx_replace_user_units() {
	local tmp_dir="$1" dest_dir="$2"
	local unit dst
	shift 2

	minx_log "Stopping and disabling existing user units"

	for unit in "$@"; do
		systemctl --user disable --now "$unit" >/dev/null 2>&1 || true
	done

	minx_log "Removing existing user units"

	for unit in "$@"; do
		dst="$dest_dir/$unit"
		[[ -e "$dst" || -L "$dst" ]] || continue

		rm -f -- "$dst" ||
			{
				minx_fail "Failed to remove: $dst"
				return 1
			}

		minx_log "- $dst"
	done

	minx_log "Installing rendered user systemd units"

	for unit in "$@"; do
		dst="$dest_dir/$unit"

		install -m 0644 -- "$tmp_dir/$unit" "$dst" ||
			{
				minx_fail "Failed to install: $dst"
				return 1
			}

		minx_pass "Installed $unit"
	done

	minx_log "Reloading user systemd"

	systemctl --user daemon-reload ||
		{
			minx_fail "systemd daemon-reload failed"
			return 1
		}
}

# _minx_enable_user_units <unit>...
_minx_enable_user_units() {
	local unit

	minx_log "Enabling and starting user units"

	for unit in "$@"; do
		if ! systemctl --user enable --now "$unit"; then
			systemctl --user status "$unit" --no-pager || true
			minx_fail "Failed to enable/start $unit"
			return 1
		fi

		minx_pass "Enabled $unit"
	done

	minx_log "User systemd status:"

	for unit in "$@"; do
		if ! systemctl --user is-active --quiet "$unit"; then
			systemctl --user status "$unit" --no-pager || true
			minx_fail "$unit is not active"
			return 1
		fi

		minx_pass "$unit is active"
	done
}

minx_install_user_services() { # {{{
	minx_assert_is_non_root || return 1

	if ! minx_is_desktop_install; then
		minx_log_server_skip "Does not include system services. Additional services must be installed manually. See documentation."
		return 0
	fi

	if ! systemctl --user show-environment >/dev/null 2>&1; then
		minx_fail "systemd user session is not available"
		return 1
	fi

	local dest_dir="$HOME/.config/systemd/user"

	# Standalone services (enabled directly).
	local -a services=(
		languagetool.service
		wikiviewer.service
	)

	# Service + timer pairs (the timer is what gets enabled).
	local -a timed_jobs=(
		ssync-mail
		ssync-calendar
		ssync-passwords
		ssync-taskwarrior
		ssync-assets
		ssync-documents
		ssync-ta
		update_feeds
	)

	local -a units=("${services[@]}")
	local -a enabled_units=("${services[@]}")
	local job

	for job in "${timed_jobs[@]}"; do
		units+=("$job.service" "$job.timer")
		enabled_units+=("$job.timer")
	done

	mkdir -p -- "$dest_dir" ||
		{
			minx_fail "Failed to create: $dest_dir"
			return 1
		}

	local tmp_dir rc
	tmp_dir="$(mktemp -d -p /tmp)" ||
		{
			minx_fail "Cannot create temporary directory"
			return 1
		}

	_minx_render_user_units "$tmp_dir" "${units[@]}" &&
		_minx_replace_user_units "$tmp_dir" "$dest_dir" "${units[@]}"
	rc=$?

	minx_safe_rm_dir "$tmp_dir"
	((rc == 0)) || return 1

	_minx_enable_user_units "${enabled_units[@]}" || return 1

	minx_log "User services successfully installed"
} # }}}

# =============================================================================
# System systemd services
# =============================================================================

# _minx_verify_link <link> <expected_target>
_minx_verify_link() {
	local link="$1" expected="$2"

	if [[ -L "$link" && -e "$link" && "$(readlink -- "$link")" == "$expected" ]]; then
		minx_pass "$link -> $expected"
	else
		minx_fail "Invalid dependency link: $link"
	fi
}

minx_install_system_services() { # {{{
	minx_assert_is_root || return 1

	if minx_is_server_install; then
		minx_log_server_skip "Does not install minx system services. Additional system services must be installed manually. See documentation."
		return 0
	fi

	local target_user target_home
	minx_get_target_info target_user target_home || return 1

	local service_src="$MINX_INSTALLER_SERVICES_DIR/system/shutdown-pre@.service"
	local service_dst="/etc/systemd/system/shutdown-pre@.service"
	local dispatcher_src="$MINX_INSTALLER_SERVICES_DIR/system/sleep_dispatch.sh"
	local dispatcher_dst="/lib/systemd/system-sleep/sleep_dispatch.sh"

	# Each action X maps: X.target -> wants -> shutdown-pre@X.service
	local -a actions=(reboot poweroff halt)

	local action other instance link wants_dir
	local load_state fragment exec_start
	local failed=0

	#
	# Prepare directories
	#

	minx_log "Installing system services for: $target_user"

	local -a dirs=(/etc/systemd/system /lib/systemd/system-sleep)
	for action in "${actions[@]}"; do
		dirs+=("/etc/systemd/system/${action}.target.wants")
	done

	install -d -m 0755 -- "${dirs[@]}" ||
		{
			minx_fail "Failed to prepare system directories"
			return 1
		}

	#
	# Render and install files
	#

	minx_section "Rendering system service templates"

	minx_install_rendered_file \
		"$service_src" "$service_dst" 0644 "$target_user" "$target_home" || return 1
	minx_install_rendered_file \
		"$dispatcher_src" "$dispatcher_dst" 0755 "$target_user" "$target_home" || return 1

	#
	# Rebuild target dependency links (remove stale ones, create exact ones)
	#

	minx_section "Configuring shutdown target dependencies"

	for action in "${actions[@]}"; do
		for other in "${actions[@]}"; do
			link="/etc/systemd/system/${action}.target.wants/shutdown-pre@${other}.service"
			[[ -e "$link" || -L "$link" ]] || continue

			minx_diag "Removing old link: $link"
			rm -f -- "$link" ||
				{
					minx_fail "Failed to remove: $link"
					failed=1
				}
		done
	done

	((failed == 0)) || return 1

	for action in "${actions[@]}"; do
		link="/etc/systemd/system/${action}.target.wants/shutdown-pre@${action}.service"

		minx_symlink "$service_dst" "$link" || failed=1
	done

	((failed == 0)) || return 1

	#
	# Reload and verify
	#

	minx_section "Reloading systemd"

	systemctl daemon-reload ||
		{
			minx_fail "systemd daemon-reload failed"
			return 1
		}

	minx_section "Verifying service template"

	systemd-analyze verify "$service_dst" ||
		{
			minx_fail "systemd verification failed"
			return 1
		}

	for action in "${actions[@]}"; do
		instance="shutdown-pre@${action}.service"
		minx_section "Verifying $instance"

		load_state="$(systemctl show "$instance" -p LoadState --value)"
		fragment="$(systemctl show "$instance" -p FragmentPath --value)"
		exec_start="$(systemctl show "$instance" -p ExecStart --value)"

		if [[ "$load_state" != loaded ]]; then
			minx_fail "$instance is not loaded"
			failed=1
		fi

		if [[ "$fragment" != "$service_dst" ]]; then
			minx_fail "$instance uses an unexpected unit file"
			failed=1
		fi

		# An empty or unresolved executable is never acceptable.
		if [[ -z "$exec_start" || "$exec_start" == *'@MINX_'* || "$exec_start" == *'@@'* ]]; then
			minx_fail "Invalid or unresolved ExecStart: $instance"
			failed=1
		fi

		systemctl cat "$instance" ||
			{
				minx_fail "Unable to display: $instance"
				failed=1
			}
	done

	minx_section "Checking target dependency mappings"

	for action in "${actions[@]}"; do
		wants_dir="/etc/systemd/system/${action}.target.wants"

		_minx_verify_link \
			"$wants_dir/shutdown-pre@${action}.service" "$service_dst" || failed=1

		for other in "${actions[@]}"; do
			[[ "$other" == "$action" ]] && continue

			if [[ -e "$wants_dir/shutdown-pre@${other}.service" ||
				-L "$wants_dir/shutdown-pre@${other}.service" ]]; then
				minx_fail "Unexpected cross-target link: $wants_dir/shutdown-pre@${other}.service"
				failed=1
			fi
		done

		systemctl list-dependencies "${action}.target" --all --no-pager || true
	done

	#
	# Final diagnostics
	#

	minx_section "Effective service properties"

	for action in "${actions[@]}"; do
		instance="shutdown-pre@${action}.service"
		printf '\n[%s]\n' "$instance"

		systemctl show "$instance" \
			-p LoadState \
			-p UnitFileState \
			-p ActiveState \
			-p SubState \
			-p Before \
			-p After \
			-p Conflicts \
			-p WantedBy || true

		systemctl list-dependencies --reverse "$instance" --all --no-pager || true
	done

	minx_section "Final service status"

	for action in "${actions[@]}"; do
		systemctl status "shutdown-pre@${action}.service" --no-pager || true
	done

	if ((failed != 0)); then
		printf '\n' >&2
		minx_fail "Installation completed with diagnostic failures"
		return 1
	fi

	minx_section "[PASS] System services installed and diagnostics completed"
} # }}}

# =============================================================================
# Mail
# =============================================================================

# _minx_setup_mail_account <account> <tmp_dir>
_minx_setup_mail_account() {
	local account="$1" tmp_dir="$2"

	minx_log "Setting up $account"
	minx_log "- Create dirs"

	mkdir -p -- "$HOME/.mail/$account" "$tmp_dir/$account" || return 1

	minx_log "- mbsync $account"

	time mbsync "$account"
}

# =============================================================================
# Tools
# =============================================================================

# Both installers run in a subshell so the caller's working directory is kept.

minx_install_tt() { # {{{
	minx_assert_is_non_root || return 1

	if minx_is_server_install; then
		minx_log_server_skip "Does not include \"tt\""
		return 0
	fi

	(
		cd "$MINX_USER_REPOS_DIR/personal/mytools.d/tt.d/tt-src" || exit 1
		./install.sh "$@" --force
	)
} # }}}

minx_install_wikiviewer() { # {{{
	minx_assert_is_non_root || return 1

	(
		cd "$MINX_USER_REPOS_DIR/personal/mytools.d/wikiviewer" || exit 1
		./install.sh --force
	)
} # }}}
