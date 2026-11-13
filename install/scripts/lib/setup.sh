#!/usr/bin/env bash

: "${MINX_PROFILES_DIR:?Variable does not exist}"

# -----------------------------------------------------------------------------
# minx_backup_user_rc_files
# -----------------------------------------------------------------------------

minx_backup_user_rc_files() { # {{{
	minx_assert_is_non_root || return 1

	local _is_server="${1:-?Variable not set}"
	if [[ "$_is_server" == "yes" ]]; then
		printf "\n=> [is_server=yes] --  Same behaviour\n"
	fi

	printf '\n%s\n' "=> Backing up existing dotfiles"

	mkdir -p -- "$HOME/.backups" || return 1

	local backup_dir
	backup_dir="$HOME/.backups/.rc_$(minx_get_date)"

	local -A files_map # [dst]=src
	files_map=(
		["$backup_dir/.bashrc"]="$HOME/.bashrc"
		["$backup_dir/.gitconfig"]="$HOME/.gitconfig"
		["$backup_dir/.gitconfig-mpcdf"]="$HOME/.gitconfig-mpcdf"
		["$backup_dir/.gitconfig-personal"]="$HOME/.gitconfig-personal"
		["$backup_dir/.gitignore-global"]="$HOME/.gitignore-global"
		["$backup_dir/.gnupg/gpg-agent.conf"]="$HOME/.gnupg/gpg-agent.conf"
		["$backup_dir/.mailcap"]="$HOME/.mailcap"
		["$backup_dir/.mbsyncrc"]="$HOME/.mbsyncrc"
		["$backup_dir/.msmtprc"]="$HOME/.msmtprc"
		["$backup_dir/.inputrc"]="$HOME/.inputrc"
		["$backup_dir/.notmuch-config"]="$HOME/.notmuch-config"
		["$backup_dir/.profile"]="$HOME/.profile"
		["$backup_dir/.ssh/config"]="$HOME/.ssh/config"
		["$backup_dir/.taskrc"]="$HOME/.taskrc"
		["$backup_dir/.tmux.conf"]="$HOME/.tmux.conf"
		["$backup_dir/.vimrc"]="$HOME/.vimrc"
		["$backup_dir/.xinitrc"]="$HOME/.xinitrc"
		["$backup_dir/.xsetroot.sh"]="$HOME/.xsetroot.sh"
	)

	minx_move_map files_map || return 1

	local -A folder_map # [dst]=src
	folder_map=(
		["$backup_dir/.bashrc.d"]="$HOME/.bashrc.d"
		["$backup_dir/.newsboat"]="$HOME/.newsboat"
		["$backup_dir/.config"]="$HOME/.config"
		["$backup_dir/.vim"]="$HOME/.vim"
	)

	minx_move_map folder_map || return 1

} # }}}

# -----------------------------------------------------------------------------
# minx_restore_user_rc_files
# -----------------------------------------------------------------------------

minx_restore_user_rc_files() { # {{{

	minx_assert_is_non_root || return 1

	local _is_server="${1:-?Variable not set}"
	if [[ "$_is_server" == "yes" ]]; then
		printf "\n=> [is_server=yes] --  Different behaviour\n"
	fi

	local dotfiles="$MINX_PROFILES_DIR/user/dotfiles"

	local -A files_map

	# shellcheck disable=SC2034 # passed as reference to a function
	files_map=(
		# [dst]=src
		["$HOME/.bashrc"]="$dotfiles/.bashrc"
		["$HOME/.gitconfig"]="$dotfiles/.gitconfig"
		["$HOME/.gitconfig-mpcdf"]="$dotfiles/.gitconfig-mpcdf"
		["$HOME/.gitconfig-personal"]="$dotfiles/.gitconfig-personal"
		["$HOME/.gitignore-global"]="$dotfiles/.gitignore-global"
		["$HOME/.gnupg/gpg-agent.conf"]="$dotfiles/.gnupg/gpg-agent.conf"
		["$HOME/.inputrc"]="$dotfiles/.inputrc"
		["$HOME/.mail/.aliases"]="$dotfiles/.mail/.aliases"
		["$HOME/.mailcap"]="$dotfiles/.mailcap"
		["$HOME/.mbsyncrc"]="$dotfiles/.mbsyncrc"
		["$HOME/.msmtprc"]="$dotfiles/.msmtprc"
		["$HOME/.notmuch-config"]="$dotfiles/.notmuch-config"
		["$HOME/.profile"]="$dotfiles/.profile"
		["$HOME/.ssh/config"]="$dotfiles/.ssh/config"
		["$HOME/.taskrc"]="$dotfiles/.taskrc"
		["$HOME/.tmux.conf"]="$dotfiles/.tmux.conf"
		["$HOME/.vimrc"]="$dotfiles/.vimrc"
		["$HOME/.xinitrc"]="$dotfiles/.xinitrc"
		["$HOME/.xsetroot.sh"]="$dotfiles/.xsetroot.sh"
	)

	minx_symlink_map files_map || return 1

	if [[ "$_is_server" == "yes" ]]; then
		rm "$HOME/.ssh/config"
		rm "$HOME/.tmux.conf"
		rm "$HOME/.xinitrc"
		rm "$HOME/.xsetroot.sh"
	fi

	local -A folder_map
	folder_map+=(
		# [dst]=src
		["$HOME/.bashrc.d"]="$dotfiles/.bashrc.d"
		["$HOME/.config"]="$dotfiles/.config"
		["$HOME/.local/bin/minx"]="$MINX_PROFILES_DIR/user/scripts/bin"
		["$HOME/.newsboat"]="$dotfiles/.newsboat"
		["$HOME/.vim"]="$dotfiles/.vim"
	)

	minx_symlink_map folder_map || return 1
} # }}}

# -----------------------------------------------------------------------------
# minx_backup_root_rc_files
# -----------------------------------------------------------------------------

minx_backup_root_rc_files() { # {{{
	minx_assert_is_root || return 1

	local _is_server="${1:-?Variable not set}"
	if [[ "$_is_server" == "yes" ]]; then
		printf "\n=> [is_server=yes] --  Same behaviour\n"
	fi

	printf '\n%s\n' "=> Backing up existing dotfiles"

	mkdir -p -- "$HOME/.backups" || return 1

	local backup_dir
	backup_dir="$HOME/.backups/.rc_$(minx_get_date)"

	local -A files_map # [dst]=src
	files_map=(
		["$backup_dir/.bashrc"]="$HOME/.bashrc"
	)

	minx_move_map files_map || return 1

	local -A folder_map # [dst]=src
	folder_map=(
	)

	minx_move_map folder_map || return 1
} # }}}

# -----------------------------------------------------------------------------
# minx_restore_root_rc_files
# -----------------------------------------------------------------------------

minx_restore_root_rc_files() { # {{{

	local _is_server="${1:-?Variable not set}"
	if [[ "$_is_server" == "yes" ]]; then
		printf "\n=> [is_server=yes] --  Same behaviour\n"
	fi

	minx_assert_is_root || return 1

	local -A files_map

	# shellcheck disable=SC2034 # passed as reference to a function
	files_map=(
		# [dst]=src
		["$HOME/.bashrc"]="$MINX_PROFILES_DIR/root/dotfiles/.bashrc"
	)

	minx_symlink_map files_map || return 1

	local -A folder_map
	folder_map+=(
		# [dst]=src
	)

	minx_symlink_map folder_map || return 1
} # }}}

# -----------------------------------------------------------------------------
# minx_install_mime_types
# -----------------------------------------------------------------------------

minx_install_mime_types() { # {{{

	local _is_server="${1:-?Variable not set}"
	if [[ "$_is_server" == "yes" ]]; then
		printf "\n=> [is_server=yes] --  Different behaviour\n"
		printf "\n=> [is_server=yes] --  Do nothing\n"
		return 0
	fi

	minx_assert_is_non_root || return 1

	local desktop_dir="$HOME/.local/share/applications"
	local mime_dir="$HOME/.local/share/mime"

	mkdir -p -- "$desktop_dir" || return 1
	mkdir -p -- "$mime_dir/packages" || return 1

	local -A desktop_files=()
	local file
	local filename

	for file in "$MINX_PROFILES_DIR/user/mimetypes"/*.desktop; do
		[[ -f "$file" ]] || continue

		filename="${file##*/}"
		desktop_files+=(
			["$desktop_dir/$filename"]="$file"
		)
	done

	minx_symlink_map desktop_files || return 1

	update-mime-database "$mime_dir" || return 1
} # }}}

# -----------------------------------------------------------------------------
# minx_get_vim_vundle
# -----------------------------------------------------------------------------

minx_get_vim_vundle() { # {{{

	local _is_server="${1:-?Variable not set}"
	if [[ "$_is_server" == "yes" ]]; then
		printf "\n=> [is_server=yes] --  Same behaviour\n"
	fi

	minx_path_exists "$HOME/.vim" || return 1

	local vundle_dir="$HOME/.vim/bundle/Vundle.vim"

	minx_path_exists "$vundle_dir" && rm -rf -- "$vundle_dir"

	git clone https://github.com/VundleVim/Vundle.vim.git "$vundle_dir"
} # }}}

# -----------------------------------------------------------------------------
# minx_clone_personal_repos
# -----------------------------------------------------------------------------

minx_clone_personal_repos() { # {{{

	minx_assert_is_non_root || return 1

	local _is_server="${1:-?Variable not set}"

	if [[ "$_is_server" == "yes" ]]; then
		printf "\n=> [is_server=yes] --  Different behaviour\n"
	fi

	local dst_dir="$MINX_USER_REPOS_DIR/personal"

	local personal_repos=(
		.abook
		.password-store
		family-server
		minx-profiles
		mytools.d/tt.d/tt-src
		mytools.d/tt.d/tt-data.d/activities
		mytools.d/tt.d/tt-data.d/notes
		mytools.d/tt.d/tt-data.d/goals
		mytools.d/wikiviewer
		projects.d/coursera.d/cpp-in-scicomp
		projects.d/hpc-python
	)

	mkdir -p -- "$dst_dir" || return 1

	local repo
	local repo_dir

	local remote=""
	if [ "$_is_server" == "no" ]; then
		remote="$MINX_REMOTE_SSH_SERVER:"
	fi

	for repo in "${personal_repos[@]}"; do
		repo_dir="$dst_dir/$repo"

		if [[ -d "$repo_dir/.git" ]]; then
			printf '%s\n' "=> $repo already exists, skipping clone."
			continue
		fi

		if [[ -e "$repo_dir" ]]; then
			printf '%s\n' "=> Error: destination exists but is not a Git repository: $repo_dir" >&2
			return 1
		fi

		printf '%s\n' "=> Cloning $repo..."

		git clone "${remote}${MINX_REMOTE_BAREREPOS_DIR}/${repo}.git" "${repo_dir}" || {
			printf '%s\n' "=> Error: failed to clone $repo" >&2
			return 1
		}
	done

	repo_dir="$MINX_USER_DOCUMENTS_DIR"
	repo=mydocuments

	if [[ -d "$repo_dir/.git" ]]; then
		printf '%s\n' "=> $repo already exists, skipping clone."
	elif [[ -e "$repo_dir" ]]; then
		printf '%s\n' "=> Error: destination exists but is not a Git repository: $repo_dir" >&2
		return 1
	else
		printf '%s\n' "=> Cloning $repo..."
		git clone "${remote}${MINX_REMOTE_BAREREPOS_DIR}/${repo}.git" "$MINX_USER_DOCUMENTS_DIR" || {
			printf '%s\n' "=> Error: failed to clone $repo" >&2
			return 1
		}
	fi

	local -A folder_map
	folder_map+=(
		# [dst]=src
		["$HOME/.abook"]="$dst_dir/.abook"
		["$HOME/.password-store"]="$dst_dir/.password-store"
		["$HOME/.timewarrior"]="$dst_dir/mytools.d/tt.d/tt-data.d/activities"
	)

	minx_symlink_map folder_map
} # }}}

# -----------------------------------------------------------------------------
# minx_install_user_services
# -----------------------------------------------------------------------------

minx_install_user_services() { # {{{
	minx_assert_is_non_root || return 1

	local _is_server="${1:-?Variable not set}"
	if [[ "$_is_server" == "yes" ]]; then
		printf "\n=> [is_server=yes] --  Different behaviour\n"
		printf "\n=> [is_server=yes] --  Do nothing\n"
		return 0
	fi

	#
	# Ensure user systemd is available
	#

	if ! systemctl --user show-environment >/dev/null 2>&1; then
		printf '%s\n' "=> Error: systemd user session is not available."
		return 1
	fi

	#
	# Config
	#

	local dest_dir="$HOME/.config/systemd/user"

	local -A units=(
		["languagetool.service"]="$MINX_INSTALLER_SERVICES_DIR/user/languagetool.service"
		["wikiviewer.service"]="$MINX_INSTALLER_SERVICES_DIR/user/wikiviewer.service"

		["ssync-mail.service"]="$MINX_INSTALLER_SERVICES_DIR/user/ssync-mail.service"
		["ssync-mail.timer"]="$MINX_INSTALLER_SERVICES_DIR/user/ssync-mail.timer"

		["ssync-calendar.service"]="$MINX_INSTALLER_SERVICES_DIR/user/ssync-calendar.service"
		["ssync-calendar.timer"]="$MINX_INSTALLER_SERVICES_DIR/user/ssync-calendar.timer"

		["ssync-pass.service"]="$MINX_INSTALLER_SERVICES_DIR/user/ssync-pass.service"
		["ssync-pass.timer"]="$MINX_INSTALLER_SERVICES_DIR/user/ssync-pass.timer"

		["ssync-taskwarrior.service"]="$MINX_INSTALLER_SERVICES_DIR/user/ssync-taskwarrior.service"
		["ssync-taskwarrior.timer"]="$MINX_INSTALLER_SERVICES_DIR/user/ssync-taskwarrior.timer"

		["ssync-files.service"]="$MINX_INSTALLER_SERVICES_DIR/user/ssync-files.service"
		["ssync-files.timer"]="$MINX_INSTALLER_SERVICES_DIR/user/ssync-files.timer"

		["ssync-notes.service"]="$MINX_INSTALLER_SERVICES_DIR/user/ssync-notes.service"
		["ssync-notes.timer"]="$MINX_INSTALLER_SERVICES_DIR/user/ssync-notes.timer"

		["ssync-ta.service"]="$MINX_INSTALLER_SERVICES_DIR/user/ssync-ta.service"
		["ssync-ta.timer"]="$MINX_INSTALLER_SERVICES_DIR/user/ssync-ta.timer"

		["update_feeds.service"]="$MINX_INSTALLER_SERVICES_DIR/user/update_feeds.service"
		["update_feeds.timer"]="$MINX_INSTALLER_SERVICES_DIR/user/update_feeds.timer"
	)

	#
	# Units to enable/start
	#

	local -a enabled_units=(
		languagetool.service
		wikiviewer.service

		ssync-mail.timer
		ssync-calendar.timer
		ssync-pass.timer
		ssync-taskwarrior.timer
		ssync-files.timer
		ssync-notes.timer
		ssync-ta.timer
		update_feeds.timer
	)

	#
	# Ensure destination exists
	#

	mkdir -p -- "$dest_dir" || {
		printf '%s\n' "=> [FAIL] Failed to create: $dest_dir" >&2
		return 1
	}

	#
	# Install units
	#

	printf '%s\n' "=> Installing user systemd units to $dest_dir"

	local unit
	local src
	local dst

	for unit in "${!units[@]}"; do
		src="${units[$unit]}"
		dst="$dest_dir/$unit"

		if [[ ! -f "$src" ]]; then
			printf '%s\n' "=> [FAIL] Missing unit file: $src" >&2
			return 1
		fi

		install -m 0644 -- "$src" "$dst" || {
			printf '%s\n' "=> [FAIL] Failed to install: $dst" >&2
			return 1
		}

		printf '%s\n' "=> - $dst"
	done

	#
	# Reload user systemd
	#

	printf '%s\n' "=> Reloading user systemd"

	systemctl --user daemon-reload || {
		printf '%s\n' "=> [FAIL] systemd daemon-reload failed" >&2
		return 1
	}

	#
	# Enable + start
	#

	printf '%s\n' "=> Enabling and starting user units"

	for unit in "${enabled_units[@]}"; do
		if ! systemctl --user enable --now "$unit"; then
			printf '%s\n' \
				"=> [FAIL] Failed to enable/start $unit" >&2

			systemctl --user status "$unit" --no-pager || true
			return 1
		fi

		printf '%s\n' "=> [PASS] Enabled $unit"
	done

	#
	# Status check
	#

	printf '%s\n' "=> User systemd status:"

	for unit in "${enabled_units[@]}"; do
		if systemctl --user is-active --quiet "$unit"; then
			printf '%s\n' "=> [PASS] $unit is active"
		else
			printf '%s\n' "=> [FAIL] $unit is not active" >&2

			systemctl --user status "$unit" --no-pager || true
			return 1
		fi
	done

} # }}}

# -----------------------------------------------------------------------------
# minx_init_mail
# -----------------------------------------------------------------------------

minx_init_mail() { # {{{

	local _is_server="${1:-?Variable not set}"
	if [[ "$_is_server" == "yes" ]]; then
		printf "\n=> [is_server=yes] --  Same behaviour\n"
	fi

	minx_assert_is_non_root || return 1

	local _is_server="${1:-?Variable not set}"
	echo "$_is_server" >/dev/null

	local mail_tmp_dir="/tmp/neomutt-$UID"
	local account

	__setup_account() {
		local account="$1"

		printf '%s\n' "=> Setting up $account"
		printf '%s\n' "=> - Create dirs"

		mkdir -p \
			"$HOME/.mail/$account" \
			"$mail_tmp_dir/$account" || return 1

		printf '%s\n' "=> - mbsync $account"

		time mbsync "$account" || return 1
	}

	local accounts=(
		gmx
		gmail
	)

	for account in "${accounts[@]}"; do
		__setup_account "$account" || return 1
	done

	notmuch new || return 1
} # }}}

# -----------------------------------------------------------------------------
# helpers
# -----------------------------------------------------------------------------

_get_target_info() { # {{{
	local -n user="$1"
	local -n home="$2"

	user="$(logname 2>/dev/null || true)"

	if [[ -z "$user" || "$user" == "root" ]]; then
		printf '%s\n' \
			"=> [FAIL] Could not determine target user" >&2
		return 1
	fi

	if ! id "$user" >/dev/null 2>&1; then
		printf '%s\n' \
			"=> [FAIL] Target user does not exist: $user" >&2
		return 1
	fi

	printf '%s\n' "=> Target user: $user"

	home="$(getent passwd "$user" | cut -d: -f6)" || {
		printf '%s\n' \
			"=> [FAIL] Could not determine home for: $user" >&2
		return 1
	}

	if [[ -z "$home" ]]; then
		printf '%s\n' \
			"=> [FAIL] Target home is empty" >&2
		return 1
	fi

	printf '%s\n' "=> Target home: $home"
} # }}}

# -----------------------------------------------------------------------------
# minx_install_system_services
# -----------------------------------------------------------------------------

minx_install_system_services() { # {{{
	minx_assert_is_root || return 1

	local _is_server="${1:-?Variable not set}"
	if [[ "$_is_server" == "yes" ]]; then
		printf "\n=> [is_server=yes] --  Different behaviour\n"
		printf "\n=> [is_server=yes] --  Do nothing\n"
		return 0
	fi

	local target_user target_home
	_get_target_info target_user target_home || return 1

	local service_src="$MINX_INSTALLER_SERVICES_DIR/system/shutdown-pre@.service"
	local service_dst="/etc/systemd/system/shutdown-pre@.service"
	local dispatcher_src="$MINX_INSTALLER_SERVICES_DIR/system/sleep_dispatch.sh"
	local dispatcher_dst="/lib/systemd/system-sleep/sleep_dispatch.sh"

	local -a service_instances=(
		shutdown-pre@reboot.service
		shutdown-pre@poweroff.service
		shutdown-pre@halt.service
	)
	local -a targets=(
		reboot.target
		poweroff.target
		halt.target
	)

	local target service_instance expected_instance
	local wants_dir link tmp source destination mode
	local i failed=0

	#
	# Internal Function Helpers
	#

	_minx_diag() {
		printf '[DIAG] %s\n' "$*"
	}

	_minx_fail() {
		printf '[FAIL] %s\n' "$*" >&2
		failed=1
	}

	_minx_install_template() {
		local source=$1 destination=$2 mode=$3
		local tmp

		if [[ ! -f "$source" ]]; then
			_minx_fail "Missing source file: $source"
			return 1
		fi

		tmp="$(mktemp "${destination}.XXXXXX")" || {
			_minx_fail "mktemp failed for: $destination"
			return 1
		}

		if ! sed \
			-e "s|@TARGET_USER@|$target_user|g" \
			-e "s|@TARGET_HOME@|$target_home|g" \
			"$source" >"$tmp"; then
			rm -f -- "$tmp"
			_minx_fail "Failed to generate: $destination"
			return 1
		fi

		if grep -qE '@TARGET_(USER|HOME)@' "$tmp"; then
			rm -f -- "$tmp"
			_minx_fail "Unexpanded placeholders in: $destination"
			return 1
		fi

		if ! chown root:root "$tmp" ||
			! chmod "$mode" "$tmp" ||
			! mv -f -- "$tmp" "$destination"; then
			rm -f -- "$tmp"
			_minx_fail "Failed to install: $destination"
			return 1
		fi

		_minx_diag "Installed: $destination"
		ls -l -- "$destination" || return 1
	}

	#
	# Validate and prepare
	#

	printf '=> Installing system services for: %s\n' "$target_user"

	_minx_diag "Target home: $target_home"

	if ! install -d -m 0755 \
		/etc/systemd/system \
		/lib/systemd/system-sleep \
		/etc/systemd/system/reboot.target.wants \
		/etc/systemd/system/poweroff.target.wants \
		/etc/systemd/system/halt.target.wants; then
		_minx_fail "Failed to prepare system directories"
		return 1
	fi

	#
	# Install generated files
	#

	_minx_install_template "$service_src" "$service_dst" 0644 || return 1
	_minx_install_template "$dispatcher_src" "$dispatcher_dst" 0755 || return 1

	#
	# Rebuild exact target-to-instance mappings
	#

	printf '\n%s\n' "=> Configuring shutdown target dependencies"

	for i in "${!targets[@]}"; do
		target=${targets[$i]}
		wants_dir="/etc/systemd/system/${target}.wants"

		for service_instance in "${service_instances[@]}"; do
			link="${wants_dir}/${service_instance}"

			if [[ -e "$link" || -L "$link" ]]; then
				_minx_diag "Removing old link: $link"
				if ! rm -f -- "$link"; then
					_minx_fail "Failed to remove: $link"
				fi
			fi
		done
	done

	((failed == 0)) || return 1

	for i in "${!targets[@]}"; do
		target=${targets[$i]}
		service_instance=${service_instances[$i]}
		link="/etc/systemd/system/${target}.wants/${service_instance}"

		if ! ln -s "$service_dst" "$link"; then
			_minx_fail "Failed to create link: $link"
			continue
		fi

		if [[ ! -L "$link" || ! -e "$link" ]] ||
			[[ "$(readlink -- "$link")" != "$service_dst" ]]; then
			_minx_fail "Invalid dependency link: $link"
			continue
		fi

		printf '[PASS] %s -> %s\n' "$link" "$service_dst"
	done

	((failed == 0)) || return 1

	#
	# Reload and validate systemd
	#

	printf '\n%s\n' "=> Reloading systemd"

	if ! systemctl daemon-reload; then
		_minx_fail "systemd daemon-reload failed"
		return 1
	fi

	printf '\n%s\n' "=> Verifying service template"

	if ! systemd-analyze verify "$service_dst"; then
		_minx_fail "systemd verification failed"
		return 1
	fi

	for service_instance in "${service_instances[@]}"; do
		printf '\n%s\n' "=> Verifying $service_instance"

		if ! systemctl show "$service_instance" \
			-p LoadState \
			-p UnitFileState \
			-p ActiveState \
			-p SubState \
			-p FragmentPath \
			-p ExecStart \
			-p User \
			-p Group \
			-p Before \
			-p After \
			-p Conflicts \
			-p Requires \
			-p Wants \
			-p WantedBy; then
			_minx_fail "Unable to inspect: $service_instance"
			continue
		fi

		if [[ "$(systemctl show "$service_instance" -p LoadState --value)" != loaded ]]; then
			_minx_fail "$service_instance is not loaded"
		fi

		if [[ "$(systemctl show "$service_instance" -p FragmentPath --value)" != "$service_dst" ]]; then
			_minx_fail "$service_instance uses an unexpected unit file"
		fi

		systemctl cat "$service_instance" || {
			_minx_fail "Unable to display: $service_instance"
		}
	done

	#
	# Verify exact target mappings and report dependencies
	#

	printf '\n%s\n' "=> Checking target dependency mappings"

	for i in "${!targets[@]}"; do
		target=${targets[$i]}
		expected_instance=${service_instances[$i]}
		wants_dir="/etc/systemd/system/${target}.wants"

		link="${wants_dir}/${expected_instance}"

		if [[ ! -L "$link" || ! -e "$link" ]] ||
			[[ "$(readlink -- "$link")" != "$service_dst" ]]; then
			_minx_fail "Invalid expected dependency link: $link"
		else
			printf '[PASS] %s -> %s\n' "$link" "$service_dst"
		fi

		for service_instance in "${service_instances[@]}"; do
			[[ "$service_instance" == "$expected_instance" ]] && continue

			if [[ -e "${wants_dir}/${service_instance}" ||
				-L "${wants_dir}/${service_instance}" ]]; then
				_minx_fail "Unexpected cross-target link: ${wants_dir}/${service_instance}"
			fi
		done

		systemctl list-dependencies "$target" --all --no-pager || true
	done

	#
	# Final diagnostics
	#

	printf '\n%s\n' "=> Effective service properties"

	for service_instance in "${service_instances[@]}"; do
		printf '\n[%s]\n' "$service_instance"

		systemctl show "$service_instance" \
			-p LoadState \
			-p UnitFileState \
			-p ActiveState \
			-p SubState \
			-p Before \
			-p After \
			-p Conflicts \
			-p WantedBy || true

		systemctl list-dependencies \
			--reverse "$service_instance" --all --no-pager || true
	done

	printf '\n%s\n' "=> Final service status"

	for service_instance in "${service_instances[@]}"; do
		systemctl status "$service_instance" --no-pager || true
	done

	if ((failed != 0)); then
		printf '\n%s\n' "[FAIL] Installation completed with diagnostic failures" >&2
		return 1
	fi

	printf '\n%s\n' "=> [PASS] System services installed and diagnostics completed"
	return 0
} # }}}

minx_install_tt() { #{{{
	minx_assert_is_non_root || return 1
	cd "$MINX_USER_REPOS_DIR/personal/mytools.d/tt.d/tt-src" || return 1
	./install.sh "$@"
} #}}}

minx_install_wikiviewer() { #{{{
	minx_assert_is_non_root || return 1
	cd "$MINX_USER_REPOS_DIR/personal/mytools.d/wikiviewer" || return 1
	./install.sh "$@"
} #}}}
