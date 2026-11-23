#!/usr/bin/env bash
#
# Installs one application per call.
#
# Usage: install_apps.sh <--build|--install> <app>
#
# Two-phase apps are built as the regular user (--build) and installed as root
# (--install). Single-phase apps ignore the phase and run entirely as root or
# entirely as the regular user; each installer asserts what it needs.
#
# shellcheck disable=SC1090,SC1091 # sourced paths are resolved at runtime
# shellcheck disable=SC2329 # functions are called indirectly

set -euo pipefail

# Setup
# ----------------------------------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# Every app "<name>" is installed by the function minx_install_<name>.
readonly -a APPS=(
	calix
	ctags
	dwm
	go
	go_packages
	invariant_repos
	jetbrains_mono
	languagetool
	librewolf
	nodejs_packages
	nvm_and_nodejs
	onlyoffice
	pdfjs
	pipx_packages
	qemu
	qutebrowser
	runtime
	rust_and_cargo
	sent
	slock
	spotify
	st
	taskwarrior
	timewarrior
	vim
)

_minx_usage() {
	printf 'Usage: %s <--build|--install> <app>\n\nApps:\n' "${0##*/}" >&2
	printf '  %s\n' "${APPS[@]}" >&2
}

_minx_is_app() { # <name>
	local app
	for app in "${APPS[@]}"; do
		[[ "$app" == "$1" ]] && return 0
	done
	return 1
}

# Validate the arguments before anything else (APP ends up in a file name).
case "${1:-}" in
--build | --install) ;;
*)
	_minx_usage
	exit 2
	;;
esac

if ! _minx_is_app "${2:-}"; then
	_minx_usage
	exit 2
fi

readonly ACTION="$1"
readonly APP="$2"

source "$SCRIPT_DIR/lib/utils.sh"
minx_test_all_info || exit 1

LOGFILE="$MINX_LOG_DIR/$(minx_get_script_name)_${APP}_$(minx_get_date).log"

readonly LOGFILE

# Helpers
# ----------------------------------------------------------------------

_minx_header() { # {{{
	minx_header L1 "[args: $APP $ACTION] $*"
} #}}}

_minx_is_build() { #{{{
	[[ "$ACTION" == "--build" ]]
} #}}}

# Build runs as the regular user, install runs as root.
_minx_assert_phase_user() { #{{{
	if _minx_is_build; then
		minx_assert_is_non_root
	else
		minx_assert_is_root
	fi
} #}}}

_minx_require_file() { #{{{
	[[ -f "$1" ]] || minx_fail "${2:-File} not found: $1"
} #}}}

_minx_require_dir() { #{{{
	[[ -d "$1" ]] || minx_fail "${2:-Directory} not found: $1"
} #}}}

_minx_require_exec() { #{{{
	[[ -x "$1" ]] || minx_fail "${2:-Executable} not found: $1"
} #}}}

# Trust a repo owned by another user (root builds/installs in user-owned repos).
# Idempotent: git config --add would otherwise append a duplicate on every run.
_minx_git_trust() { # <dir> #{{{
	local existing
	existing="$(git config --global --get-all safe.directory 2>/dev/null || true)"

	if grep -Fxq -- "$1" <<<"$existing"; then
		return 0
	fi

	git config --global --add safe.directory "$1"
} #}}}

# Remove and recreate a directory below the installation dir.
_minx_fresh_dir() { # <dir> #{{{
	minx_safe_rm_dir "$1" && mkdir -p -- "$1"
} #}}}

# Clone a pinned project (url_<name>, commit_<name>) into $MINX_REPOS_DIR/<name>,
# optionally applying a patch.
_minx_checkout() { # <name> [patch_file] #{{{
	local name="$1"
	local patch="${2:-}"

	minx_git_clone_and_patch \
		"$MINX_REPOS_DIR/$name" \
		"${MINX_PINNED_VERSIONS[url_$name]}" \
		"${MINX_PINNED_VERSIONS[commit_$name]}" \
		${patch:+"$patch"}
} #}}}

# nvm is not nounset-safe (it reads unset variables), so this switches nounset
# off for the rest of the calling installer. Only call it inside an installer
# subshell, never from top level.
_minx_load_nvm() { #{{{
	export NVM_DIR="$HOME/.nvm"

	if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
		minx_fail "nvm not found: $NVM_DIR/nvm.sh"
		return 1
	fi

	set +u
	source "$NVM_DIR/nvm.sh"
} #}}}

_minx_load_cargo() { #{{{
	local env_file="$HOME/.cargo/env"

	if [[ ! -f "$env_file" ]]; then
		minx_fail "cargo environment not found: $env_file"
		return 1
	fi

	source "$env_file"
} #}}}

# Run "<bin_dir>/<binary> <args>" as a smoke test, then add bin_dir to PATH.
# --lenient: ignore the exit status of the binary (suckless tools exit 1 on -v).
_minx_verify_bin() { # [--lenient] <bin_dir> <binary> [args...] # {{{
	local lenient=0

	if [[ "${1:-}" == --lenient ]]; then
		lenient=1
		shift
	fi

	local bin_dir="$1" bin="$2"
	shift 2

	minx_log "Verify ..."

	if ! "$bin_dir/$bin" "$@"; then
		((lenient)) || return 1
	fi

	minx_add_to_PATH "$bin_dir"
} #}}}

_minx_cmake_build() { # <repo_dir> <build_dir> <install_dir> #{{{
	cmake -S "$1" -B "$2" \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_INSTALL_PREFIX="$3" || return 1

	cmake --build "$2" --parallel "$(nproc)"
} #}}}

# Install a file with explicit mode, with the usual log lines.
_minx_install_file() { # <mode> <source> <destination> <label> #{{{
	minx_log "Installing $4"
	minx_log "Source:      $2"
	minx_log "Destination: $3"

	install -m "$1" -- "$2" "$3" || minx_fail "Failed to install: $3"
} #}}}

_minx_apt_install() { # <package>... #{{{
	apt-get update || return 1
	apt-get install -y "$@"
} #}}}

# Write a one-line apt source file (overwrites, so re-runs never duplicate it).
_minx_write_apt_source() { # <file> <line> #{{{
	printf '%s\n' "$2" >"$1"
} #}}}

# Installers (each one runs in a subshell: cd, trap and set do not leak)
# ----------------------------------------------------------------------

minx_install_go() ( # {{{
	local version="${MINX_PINNED_VERSIONS[version_go]}"
	local tarball="go${version}.linux-amd64.tar.gz"
	local url="${MINX_PINNED_VERSIONS[url_go]}$tarball"
	local sha256="${MINX_PINNED_VERSIONS[sha256_go]:-}" # optional
	local dst_file="$MINX_DOWNLOADS_DIR/$tarball"

	_minx_header "Install Go $version"

	minx_assert_is_root || return 1

	minx_safe_rm_dir "$MINX_INSTALLATION_DIR/go" || return 1

	minx_download_file "$url" "$dst_file" "$sha256" || return 1

	minx_log "Installing ..."

	if ! tar -C "$MINX_INSTALLATION_DIR" -xzf "$dst_file"; then
		rm -f -- "$dst_file" # most likely a corrupt download
		minx_fail "Failed to extract $dst_file"
		return 1
	fi

	_minx_verify_bin "$MINX_INSTALLATION_DIR/go/bin" go version || return 1

	minx_log "Done"
) # }}}

minx_install_jetbrains_mono() ( # {{{
	local version="${MINX_PINNED_VERSIONS[version_jetbrains_mono]}"
	local zip_file="JetBrainsMono.zip"
	local url="${MINX_PINNED_VERSIONS[url_jetbrains_mono]}/download/${version}/${zip_file}"
	local sha256="${MINX_PINNED_VERSIONS[sha256_jetbrains_mono]:-}" # optional
	local dst_file="$MINX_DOWNLOADS_DIR/$zip_file"
	local font_dir="/usr/share/fonts/jetbrains-mono"
	local tmp_dir

	minx_skip_in_server_install "JetBrains Mono" && return 0

	_minx_header "Install JetBrains Mono $version"

	minx_assert_is_root || return 1

	if compgen -G "$font_dir/*.ttf" >/dev/null; then
		minx_log "JetBrains Mono already installed."
		return 0
	fi

	minx_download_file "$url" "$dst_file" "$sha256" || return 1

	tmp_dir="$(mktemp -d -p /tmp)" || return 1
	# shellcheck disable=SC2064 # expand now: the variable is gone at exit
	trap "minx_safe_rm_dir ${tmp_dir@Q}" EXIT

	minx_log "Installing ..."

	unzip -q "$dst_file" -d "$tmp_dir" ||
		{
			minx_fail "Failed to extract $dst_file"
			return 1
		}

	mkdir -p -- "$font_dir" || return 1

	find "$tmp_dir" -type f -iname '*.ttf' -exec cp -t "$font_dir" -- {} + || return 1

	if ! compgen -G "$font_dir/*.ttf" >/dev/null; then
		minx_fail "No .ttf files found in $dst_file"
		return 1
	fi

	fc-cache -f || return 1

	minx_log "Done"
) # }}}

minx_install_qemu() ( # {{{
	local -a packages=(
		qemu-system
		qemu-utils
		qemu-kvm
		libvirt-daemon-system
		libvirt-clients
		virt-manager
	)

	# shellcheck disable=SC2034 # Passed as reference
	local target_user target_home

	minx_skip_in_server_install "QEMU" && return 0

	_minx_header "QEMU"

	minx_assert_is_root || return 1

	minx_log "Installing QEMU and related packages..."
	_minx_apt_install "${packages[@]}" || return 1

	minx_log "Checking virtualization support..."

	if grep -Eq '(vmx|svm)' /proc/cpuinfo; then
		minx_log "CPU virtualization supported."
	else
		minx_warn "CPU virtualization not detected."
	fi

	if [[ -e /dev/kvm ]]; then
		minx_log "/dev/kvm exists."
	else
		minx_warn "/dev/kvm not found."
	fi

	minx_get_target_info target_user target_home || return 1

	minx_log "Adding $target_user to kvm and libvirt groups..."
	usermod -aG kvm,libvirt "$target_user" || return 1

	minx_log "Enabling and starting libvirt service..."
	systemctl enable --now libvirtd || return 1

	minx_log "Verifying installation..."

	if minx_command_exists qemu-system-x86_64; then
		qemu-system-x86_64 --version || return 1
	else
		minx_warn "qemu-system-x86_64 not found in PATH."
	fi

	minx_log "Done"
) # }}}

minx_install_rust_and_cargo() ( # {{{
	_minx_header "Rust and cargo"

	minx_assert_is_non_root || return 1

	if ! minx_command_exists rustup; then
		minx_log "Installing rustup ..."
		curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y || return 1
	fi

	minx_log "Installing toolchain ..."

	_minx_load_cargo || return 1
	rustup toolchain install stable || return 1
	rustup default stable || return 1

	minx_log "Verify ..."

	rustc --version || return 1
	cargo --version || return 1

	minx_log "Done"
) # }}}

minx_install_nvm_and_nodejs() ( # {{{
	local nvm_version="${MINX_PINNED_VERSIONS[version_nvm]}"
	local nodejs_version="${MINX_PINNED_VERSIONS[version_nodejs]}"
	local url="${MINX_PINNED_VERSIONS[url_nvm]}/$nvm_version/install.sh"

	_minx_header "nvm and node.js"

	minx_assert_is_non_root || return 1

	# A clean reinstall is intended.
	rm -rf -- "$HOME/.nvm" || return 1

	minx_log "Installing NVM $nvm_version"

	curl -fsSL "$url" | bash || return 1

	minx_log "Installing ..."

	_minx_load_nvm || return 1

	nvm install "$nodejs_version" || return 1
	nvm alias default "$nodejs_version" || return 1
	nvm use default || return 1

	minx_log "Verify ..."

	node --version || return 1
	npm --version || return 1

	minx_log "Done"
) # }}}

minx_install_nodejs_packages() ( # {{{
	local -a packages=(
		markdownlint-cli
	)

	_minx_header "node.js packages"

	minx_assert_is_non_root || return 1

	_minx_load_nvm || return 1

	npm install -g "${packages[@]}" || return 1

	minx_log "Done"
) # }}}

minx_install_pipx_packages() ( # {{{
	local -a packages=(
		black=="${MINX_PINNED_VERSIONS[version_pipx_black]}"
		flake8=="${MINX_PINNED_VERSIONS[version_pipx_flake8]}"
		isort=="${MINX_PINNED_VERSIONS[version_pipx_isort]}"
		mypy=="${MINX_PINNED_VERSIONS[version_pipx_mypy]}"
		pre-commit=="${MINX_PINNED_VERSIONS[version_pipx_pre_commit]}"
		proselint=="${MINX_PINNED_VERSIONS[version_pipx_proselint]}"
		pycln=="${MINX_PINNED_VERSIONS[version_pipx_pycln]}"
		pylint=="${MINX_PINNED_VERSIONS[version_pipx_pylint]}"
		ranger-fm=="${MINX_PINNED_VERSIONS[version_pipx_ranger_fm]}"
		shellcheck-py=="${MINX_PINNED_VERSIONS[version_pipx_shellcheck_py]}"
		vale=="${MINX_PINNED_VERSIONS[version_pipx_vale]}"
		vdirsyncer=="${MINX_PINNED_VERSIONS[version_pipx_vdirsyncer]}"
		yamllint=="${MINX_PINNED_VERSIONS[version_pipx_yamllint]}"
		yt-dlp=="${MINX_PINNED_VERSIONS[version_pipx_yt_dlp]}"
	)
	local package
	local -a failed=()

	_minx_header "pipx packages"

	minx_assert_is_non_root || return 1

	# One package per call: older pipx versions accept only one spec, and a
	# failure then names the package instead of aborting the whole batch.
	for package in "${packages[@]}"; do
		pipx install --force "$package" || failed+=("$package")
	done

	if ((${#failed[@]} > 0)); then
		minx_fail "pipx failed for: ${failed[*]}"
		return 1
	fi

	minx_log "Done"
) # }}}

minx_install_go_packages() ( # {{{
	local -a packages=(
		mvdan.cc/sh/v3/cmd/shfmt@"${MINX_PINNED_VERSIONS[version_shfmt]}"
	)

	_minx_header "go packages"

	minx_assert_is_non_root || return 1

	# go is installed system-wide, but PATH only picks it up in new login shells.
	if ! minx_command_exists go; then
		PATH="$MINX_INSTALLATION_DIR/go/bin:$PATH"
	fi

	minx_command_exists go || {
		minx_fail "go not found; install it first"
		return 1
	}

	go install "${packages[@]}" || return 1

	minx_log "Make sure PATH contains: $(go env GOPATH)/bin/"
	minx_log "Done"
) # }}}

minx_install_ctags() ( # {{{
	local repo_dir="$MINX_REPOS_DIR/ctags"
	local install_dir="$MINX_INSTALLATION_DIR/ctags"

	_minx_header "$repo_dir"

	_minx_assert_phase_user || return 1

	if _minx_is_build; then
		_minx_checkout ctags || return 1

		cd -- "$repo_dir" || return 1

		./autogen.sh || return 1
		./configure --prefix="$install_dir" || return 1
		make -j"$(nproc)" || return 1
	else
		cd -- "$repo_dir" || return 1

		_minx_git_trust "$repo_dir" || return 1
		_minx_fresh_dir "$install_dir" || return 1

		make install || return 1

		_minx_verify_bin "$install_dir/bin" ctags --version || return 1
	fi

	minx_log "Done"
) # }}}

minx_install_taskwarrior() ( # {{{
	local repo_dir="$MINX_REPOS_DIR/taskwarrior"
	local build_dir="$repo_dir/_build"
	local install_dir="$MINX_INSTALLATION_DIR/taskwarrior"

	if ! minx_is_desktop_install; then
		minx_log_server_skip "Does not include \"taskwarrior\""
		return 0
	fi

	_minx_header "$repo_dir"

	_minx_assert_phase_user || return 1

	if _minx_is_build; then
		_minx_load_cargo || return 1

		# Also updates submodules.
		_minx_checkout taskwarrior || return 1

		cd -- "$repo_dir" || return 1

		rustup update stable || return 1

		minx_safe_rm_dir "$build_dir" || return 1

		minx_log "Building ..."
		_minx_cmake_build "$repo_dir" "$build_dir" "$install_dir" || return 1
	else
		_minx_fresh_dir "$install_dir" || return 1

		cmake --install "$build_dir" || return 1

		_minx_verify_bin "$install_dir/bin" task --version || return 1
	fi

	minx_log "Done"
) # }}}

minx_install_timewarrior() ( # {{{
	local repo_dir="$MINX_REPOS_DIR/timewarrior"
	local build_dir="$repo_dir/_build"
	local install_dir="$MINX_INSTALLATION_DIR/timewarrior"

	if ! minx_is_desktop_install; then
		minx_log_server_skip "Does not include \"timewarrior\""
		return 0
	fi

	_minx_header "$repo_dir"

	_minx_assert_phase_user || return 1

	if _minx_is_build; then
		# Also updates submodules.
		_minx_checkout timewarrior || return 1

		cd -- "$repo_dir" || return 1

		minx_log "Building ..."
		_minx_cmake_build "$repo_dir" "$build_dir" "$install_dir" || return 1
	else
		_minx_fresh_dir "$install_dir" || return 1

		cmake --install "$build_dir" || return 1

		_minx_verify_bin "$install_dir/bin" timew --version || return 1
	fi

	minx_log "Done"
) # }}}

# Single-phase installer: builds and installs in one go, as root.
minx_install_qutebrowser() ( # {{{
	local repo_dir="$MINX_REPOS_DIR/qutebrowser"
	local install_dir="$MINX_INSTALLATION_DIR/qutebrowser/bin"
	local executable="$install_dir/qutebrowser"
	local python="$repo_dir/.venv/bin/python"
	local script="$repo_dir/qutebrowser.py"

	minx_skip_in_server_install "qutebrowser" && return 0

	_minx_header "$repo_dir"

	minx_assert_is_root || return 1

	_minx_git_trust "$repo_dir" || return 1
	_minx_checkout qutebrowser || return 1

	minx_log "Building ..."

	cd -- "$repo_dir" || return 1

	python3 scripts/mkvenv.py || return 1

	minx_log "Installing ..."

	_minx_fresh_dir "$install_dir" || return 1

	{
		printf '%s\n' '#!/usr/bin/env bash'
		printf 'exec %q %q "$@"\n' "$python" "$script"
	} >"$executable" || return 1

	chmod +x "$executable" || return 1

	minx_log "Verify ..."

	minx_run "$executable" -h || return 1

	minx_log "Done"
) # }}}

minx_install_vim() ( # {{{
	local repo_dir="$MINX_REPOS_DIR/vim"
	local install_dir="$MINX_INSTALLATION_DIR/vim"

	_minx_header "$repo_dir"

	_minx_assert_phase_user || return 1

	if _minx_is_build; then
		minx_command_exists python3 || {
			minx_fail "python3 not found"
			return 1
		}

		_minx_checkout vim || return 1

		cd -- "$repo_dir" || return 1

		make distclean || true

		./configure \
			--with-features=huge \
			--enable-multibyte \
			--enable-terminal \
			--enable-gui=no \
			--enable-cscope \
			--enable-fail-if-missing \
			--enable-python3interp=yes || return 1

		make -j"$(nproc)" || return 1
	else
		cd -- "$repo_dir" || return 1

		_minx_fresh_dir "$install_dir" || return 1

		make DESTDIR="$install_dir" install || return 1

		_minx_verify_bin "$install_dir/usr/local/bin" vim --version || return 1
	fi

	minx_log "Done"
) # }}}

minx_install_languagetool() ( # {{{
	local src_dir="$MINX_REPOS_DIR/languagetool"
	local install_dir="$MINX_INSTALLATION_DIR/languagetool"

	local snapshot="${MINX_PINNED_VERSIONS[snapshot_languagetool]}"
	local zip_file="$src_dir/$snapshot"
	local url="${MINX_PINNED_VERSIONS[url_languagetool]}/$snapshot"
	local zip_sha256="${MINX_PINNED_VERSIONS[sha256_languagetool]:-}" # optional

	local ft_repo_dir="$src_dir/fastText"
	local ft_binary_src="$ft_repo_dir/fasttext"

	# The model is fetched and verified by download_repos.sh (remote server).
	local ft_model_file="$src_dir/lid.176.bin"
	local ft_model_sha256="${MINX_PINNED_VERSIONS[sha256_fasttext_model]:-}"

	if ! minx_is_desktop_install; then
		minx_log_server_skip "Does not include \"languagetool\""
		return 0
	fi

	_minx_header "languagetool with fasttext"

	minx_log "Instructions provided at: https://dev.languagetool.org/http-server"

	# ------------------------------------------------------------------
	# Build
	# ------------------------------------------------------------------

	if _minx_is_build; then
		minx_assert_is_non_root || return 1

		mkdir -p -- "$src_dir" || return 1

		minx_log "Downloading LanguageTool..."
		minx_download_file "$url" "$zip_file" "$zip_sha256" || return 1

		_minx_require_file "$zip_file" "LanguageTool archive" || return 1

		minx_git_clone_at_commit \
			"$ft_repo_dir" \
			"${MINX_PINNED_VERSIONS[url_fasttext]}" \
			"${MINX_PINNED_VERSIONS[commit_fasttext]}" || return 1

		minx_log "Building fastText..."

		make -C "$ft_repo_dir" clean || return 1
		make -C "$ft_repo_dir" -j"$(nproc)" || return 1

		_minx_require_exec "$ft_binary_src" "fastText binary" || return 1

		if [[ ! -f "$ft_model_file" ]]; then
			minx_fail "Language identification model not found: $ft_model_file (run download_repos.sh first, it fetches the model from the remote server)"
			return 1
		fi

		# Never deletes the file on mismatch, so it can be inspected.
		minx_verify_sha256 "$ft_model_file" "$ft_model_sha256" || return 1

		minx_log "Build complete."
		return 0
	fi

	# ------------------------------------------------------------------
	# Install
	# ------------------------------------------------------------------

	local archive_listing lt_dir lt_root
	local ft_binary_dst ft_model_dst server_properties

	minx_assert_is_root || return 1

	_minx_require_file "$zip_file" "LanguageTool archive" || return 1
	_minx_require_exec "$ft_binary_src" "fastText binary" || return 1
	_minx_require_file "$ft_model_file" "fastText model" || return 1

	# The model lives in a user-writable directory and is installed as root:
	# verify it again right before copying it.
	minx_verify_sha256 "$ft_model_file" "$ft_model_sha256" || return 1

	_minx_fresh_dir "$install_dir" ||
		{
			minx_fail "Failed to create: $install_dir"
			return 1
		}

	minx_log "Determining LanguageTool directory"

	# Captured first, and awk below reads ALL of its input (no early "exit"):
	# an early exit makes the writer die with SIGPIPE, which pipefail + set -e
	# turn into a silent abort of the whole script.
	archive_listing="$(unzip -Z1 "$zip_file")" ||
		{
			minx_fail "Failed to inspect archive: $zip_file"
			return 1
		}

	lt_dir="$(
		printf '%s\n' "$archive_listing" |
			awk -F/ 'NF > 1 && $1 != "" && root == "" { root = $1 } END { print root }'
	)"

	if [[ -z "$lt_dir" ]]; then
		minx_fail "Could not determine LanguageTool directory from: $zip_file"
		return 1
	fi

	minx_log "LanguageTool directory: $lt_dir"
	minx_log "Extracting LanguageTool"

	unzip -q "$zip_file" -d "$install_dir" ||
		{
			minx_fail "Failed to extract LanguageTool"
			return 1
		}

	lt_root="$install_dir/$lt_dir"

	_minx_require_dir "$lt_root" "LanguageTool directory" || return 1

	ft_binary_dst="$lt_root/${ft_binary_src##*/}"
	ft_model_dst="$lt_root/${ft_model_file##*/}"

	_minx_install_file 0755 "$ft_binary_src" "$ft_binary_dst" "fastText binary" || return 1
	_minx_install_file 0644 "$ft_model_file" "$ft_model_dst" "language identification model" || return 1

	server_properties="$install_dir/server.properties"

	minx_log "Creating $server_properties"

	{
		printf 'fasttextModel=%s\n' "$ft_model_dst"
		printf 'fasttextBinary=%s\n' "$ft_binary_dst"
	} >"$server_properties" ||
		{
			minx_fail "Failed to create: $server_properties"
			return 1
		}

	_minx_require_file "$lt_root/languagetool-server.jar" "LanguageTool server JAR" || return 1

	minx_log "LanguageTool installation complete."
	minx_log "LanguageTool: $lt_root"
	minx_log "Server JAR:   $lt_root/languagetool-server.jar"
	minx_log "fastText:     $ft_binary_dst"
	minx_log "Model:        $ft_model_dst"
	minx_log "Config:       $server_properties"
	minx_log "Done"
) # }}}

minx_install_pdfjs() ( # {{{
	local repo_dir="$MINX_REPOS_DIR/pdfjs"
	local install_dir="$MINX_INSTALLATION_DIR/pdfjs"
	local build_output="$repo_dir/build/generic"

	if ! minx_is_desktop_install; then
		minx_log_server_skip "Does not include \"pdfjs\""
		return 0
	fi

	minx_skip_unless_built "$ACTION" "pdf.js" "$build_output" && return 0

	_minx_header "$repo_dir"

	_minx_assert_phase_user || return 1

	if _minx_is_build; then
		_minx_load_nvm || return 1

		_minx_checkout pdfjs || return 1

		cd -- "$repo_dir" || return 1

		# Remove stale output so a skipped rebuild can't leave an old build behind.
		minx_safe_rm_dir "$build_output" || return 1

		minx_log "Building ..."

		npm ci || return 1
		npx gulp generic || return 1
	else
		minx_command_exists rsync || {
			minx_fail "rsync not found"
			return 1
		}

		_minx_fresh_dir "$install_dir" || return 1

		minx_log "Installing ..."

		rsync -a "$build_output/" "$install_dir/" || return 1

		mkdir -p /usr/share/pdf.js || return 1
		minx_symlink "$install_dir/web" /usr/share/pdf.js/web || return 1
		minx_symlink "$install_dir/build" /usr/share/pdf.js/build || return 1

		minx_log "Verify"

		_minx_require_dir "$install_dir/web" || return 1
		_minx_require_dir "$install_dir/build" || return 1
		[[ -L /usr/share/pdf.js/web ]] || return 1
		[[ -L /usr/share/pdf.js/build ]] || return 1
	fi

	minx_log "Done"
) # }}}

# Single-phase installer: always runs as root.
minx_install_runtime() ( # {{{
	local runtime_dir="$MINX_INSTALLATION_DIR/runtime"
	local profile_file="/etc/profile.d/minx_profile.sh"
	local version_script="$runtime_dir/system/bin/minx-version"
	local answer=""
	local profile_template

	if minx_is_desktop_install; then
		local profile_template="$MINX_INSTALLER_ROOT/install/config/template_minx_profile_desktop.sh"
	else
		local profile_template="$MINX_INSTALLER_ROOT/install/config/template_minx_profile_server.sh"
	fi

	_minx_header "$runtime_dir"

	minx_assert_is_root || return 1

	if minx_path_exists "$runtime_dir"; then
		printf '=> %s already exists. Override? [y/N] ' "$runtime_dir"
		read -r answer || answer=""

		if [[ ! "$answer" =~ ^[Yy]$ ]]; then
			printf '\n'
			minx_log "Skipping 'runtime' installation."
			return 0
		fi
	fi

	# Rendered first: a missing variable must not leave a half-replaced runtime.
	# @@MINX_<name>@@ is replaced by $MINX_<name> (falling back to $MXC_<name>);
	# unset or empty is an error, as the values end up in /etc/profile.d.
	minx_log "Installing minx_profile.sh ..."
	minx_install_rendered_file "$profile_template" "$profile_file" 0644 || return 1

	minx_safe_rm_dir "$runtime_dir" || return 1

	minx_log "Copying 'runtime' ..."
	minx_copy "$MINX_INSTALLER_ROOT/runtime" "$runtime_dir" || return 1

	if minx_is_server_install; then
		_strip_runtime_for_server
	fi

	minx_log "Creating minx-version ..."

	mkdir -p -- "${version_script%/*}" || return 1

	# Unquoted heredoc: the escaped \$ expressions are evaluated when the script
	# runs, everything else (installation dir, date) is baked in now. The
	# installation dir is a fallback, so the command also works when
	# MINX_INSTALLATION_DIR is not exported.
	cat >"$version_script" <<EOF || return 1
#!/usr/bin/env bash
#
# minx-version - print the installed minx version
# Generated by minx_install_runtime, do not edit.

set -Eeuo pipefail

version_file="\${MINX_INSTALLATION_DIR:-$MINX_INSTALLATION_DIR}/version"

if [[ ! -r "\$version_file" ]]; then
	printf 'minx-version: cannot read %s\n' "\$version_file" >&2
	exit 1
fi

printf "%s\n" "Installed on: $(date)"
printf "%s\n" "commit: \$(cat -- "\$version_file")"
EOF

	chmod 755 -- "$version_script" || return 1

	if minx_command_exists tree; then
		tree "$runtime_dir" || true
	fi

	minx_log "Done"
) # }}}

# dwm, sent, st and slock share the same build/install scripts.
# No DISPLAY guard: they are built and installed on every machine.
_minx_install_suckless() ( # {{{
	# <name> [VAR=value ...]
	local name="$1"
	shift

	local repo_dir="$MINX_REPOS_DIR/$name"
	local install_dir="$MINX_INSTALLATION_DIR/$name"
	local -a build_env=("DESTDIR=$install_dir" "$@")

	_minx_header "$repo_dir"

	_minx_assert_phase_user || return 1

	if _minx_is_build; then
		_minx_checkout "$name" "$MINX_INSTALLER_PATCHES_DIR/suckless/$name.diff" ||
			return 1

		minx_log "Building ..."

		env "${build_env[@]}" "$repo_dir/install.sh" --build || return 1
	else
		_minx_git_trust "$repo_dir" || return 1

		minx_log "Installing ..."

		env "${build_env[@]}" "$repo_dir/install.sh" --install || return 1

		# suckless tools print their version and exit with status 1 on -v.
		_minx_verify_bin --lenient "$install_dir/usr/local/bin" "$name" -v || return 1
	fi

	minx_log "Done"
) # }}}

minx_install_dwm() { _minx_install_suckless dwm "SCRIPTS_DIR=$MINX_INSTALLATION_DIR/runtime/system/bin"; }
minx_install_sent() { _minx_install_suckless sent; }
minx_install_st() { _minx_install_suckless st; }
minx_install_slock() { _minx_install_suckless slock; }

minx_install_invariant_repos() ( # {{{
	local -A file_map=() # [dst]=src

	minx_assert_is_non_root || return 1

	_minx_header "latex snippets"
	_minx_checkout latex_snippets || return 1

	_minx_header "tmpi"
	_minx_checkout tmpi || return 1

	file_map["$HOME/.local/bin/tmpi"]="$MINX_REPOS_DIR/tmpi/tmpi"

	# Desktop-only pieces.
	if ! minx_skip_in_server_install "qb dracula theme and a11y sound theme"; then
		_minx_header "qb dracula theme"
		_minx_checkout qutebrowser_dracula_theme \
			"$MINX_INSTALLER_PATCHES_DIR/qutebrowser_dracula_theme.diff" || return 1

		# shellcheck disable=SC2034 # Passed as reference
		file_map["$HOME/.config/qutebrowser/dracula"]="$MINX_REPOS_DIR/qutebrowser_dracula_theme"

		_minx_header "linux a11y sound theme"
		_minx_checkout linux_a11y_sound_theme || return 1
	fi

	minx_log "Install ..."

	minx_symlink_map file_map || return 1

	minx_log "Done"
) # }}}

minx_install_onlyoffice() ( # {{{
	local keyring="/usr/share/keyrings/onlyoffice.gpg"
	local source_line="deb [signed-by=$keyring] https://download.onlyoffice.com/repo/debian squeeze main"
	local tmp_dir

	minx_skip_in_server_install "Onlyoffice" && return 0

	_minx_header "Onlyoffice"

	minx_assert_is_root || return 1

	minx_log "Installing ..."

	# Throwaway GnuPG home: no predictable file names in /tmp, nothing left
	# behind in root's home.
	tmp_dir="$(mktemp -d -p /tmp)" || return 1
	# shellcheck disable=SC2064 # expand now: the variable is gone at exit
	trap "minx_safe_rm_dir ${tmp_dir@Q}" EXIT

	# NOTE: a short key id is spoofable; pin the full fingerprint if you can.
	GNUPGHOME="$tmp_dir" gpg \
		--no-default-keyring \
		--keyring "gnupg-ring:$tmp_dir/onlyoffice.gpg" \
		--keyserver hkp://keyserver.ubuntu.com:80 \
		--recv-keys CB2DE8E5 || return 1

	gpgconf --homedir "$tmp_dir" --kill all || true

	install -m 0644 -o root -g root -- "$tmp_dir/onlyoffice.gpg" "$keyring" || return 1

	_minx_write_apt_source /etc/apt/sources.list.d/onlyoffice.list "$source_line" || return 1

	_minx_apt_install onlyoffice-desktopeditors || return 1

	minx_log "Done"
) # }}}

minx_install_librewolf() ( # {{{
	minx_skip_in_server_install "LibreWolf" && return 0

	_minx_header "librewolf"

	minx_assert_is_root || return 1

	minx_log "Installing ..."

	_minx_apt_install extrepo || return 1
	extrepo enable librewolf || return 1
	extrepo update librewolf || return 1
	_minx_apt_install librewolf || return 1

	minx_log "Done"
) # }}}

minx_install_spotify() ( # {{{
	local keyring="/usr/share/keyrings/spotify.gpg"
	local source_line="deb [signed-by=$keyring] https://repository.spotify.com stable non-free"

	minx_skip_in_server_install "Spotify" && return 0

	_minx_header "Spotify"

	minx_assert_is_root || return 1

	minx_log "Installing ..."

	curl -fsSL https://download.spotify.com/debian/pubkey_5384CE82BA52C83A.asc |
		gpg --dearmor --yes -o "$keyring" || return 1

	chmod 0644 -- "$keyring" || return 1

	# The key used to be trusted for every repository; it is now scoped to this
	# one by signed-by.
	rm -f -- /etc/apt/trusted.gpg.d/spotify.gpg

	_minx_write_apt_source /etc/apt/sources.list.d/spotify.list "$source_line" || return 1

	_minx_apt_install spotify-client || return 1

	minx_log "Done"
) # }}}

minx_install_calix() ( # {{{
	local version="${MINX_PINNED_VERSIONS[version_calix]}"
	local archive_dir="calix-${version}-linux-x86_64"
	local archive_name="${archive_dir}.tar.gz"
	local url="${MINX_PINNED_VERSIONS[url_calix]}/download/v${version}/${archive_name}"
	local sha256="${MINX_PINNED_VERSIONS[sha256_calix]:-}" # optional
	local dst_file="$MINX_DOWNLOADS_DIR/calix/$archive_name"
	local bin_dir="$HOME/.local/bin"
	local installed tmp_dir

	minx_skip_in_server_install "Calix" && return 0

	_minx_header "Install Calix $version"

	# Calix installs into the user's ~/.local directory.
	minx_assert_is_non_root || return 1

	if [[ -x "$bin_dir/calix" ]]; then
		# Captured first: grep -q exiting early would trip pipefail.
		installed="$("$bin_dir/calix" --version 2>/dev/null || true)"

		if [[ "$installed" == *"$version"* ]]; then
			minx_log "Calix $version already installed."
			return 0
		fi
	fi

	minx_download_file "$url" "$dst_file" "$sha256" || return 1

	tmp_dir="$(mktemp -d -p /tmp)" || return 1
	# shellcheck disable=SC2064 # expand now: the variable is gone at exit
	trap "minx_safe_rm_dir ${tmp_dir@Q}" EXIT

	minx_log "Extracting ..."

	tar -xzf "$dst_file" -C "$tmp_dir" || return 1

	_minx_require_exec "$tmp_dir/$archive_dir/install.sh" "Calix install.sh" || return 1

	minx_log "Installing ..."

	(
		cd -- "$tmp_dir/$archive_dir" || exit 1
		./install.sh
	) || return 1

	minx_log "Verifying installation ..."

	_minx_require_exec "$bin_dir/calix" "Calix executable" || return 1

	"$bin_dir/calix" --version || return 1

	minx_log "Done"
) # }}}

_strip_runtime_for_server() {

	rm "$MINX_INSTALLATION_DIR/runtime/system/bin/{minx-launcher, minx-lockscreen}"
	rm "$MINX_INSTALLATION_DIR/runtime/system/completion/minx-launcher_completion.bash"

	rm "$MINX_INSTALLATION_DIR/runtime/user/bin/mailto.sh"
	rm "$MINX_INSTALLATION_DIR/runtime/user/bin/myservices.sh"
	rm "$MINX_INSTALLATION_DIR/runtime/user/bin/qb.sh"
	rm "$MINX_INSTALLATION_DIR/runtime/user/bin/ssync.sh"

	rm "$MINX_INSTALLATION_DIR/runtime/user/completion/mailto_completion.bash"
	rm "$MINX_INSTALLATION_DIR/runtime/user/completion/myservices_completion.bash"
	rm "$MINX_INSTALLATION_DIR/runtime/user/completion/ssync_completion.bash"

	rm -rf "$MINX_INSTALLATION_DIR/runtime/user/hooks/"
	rm -rf "$MINX_INSTALLATION_DIR/runtime/user/lib/"
	rm -rf "$MINX_INSTALLATION_DIR/runtime/user/scripts/"

}

# Main
# ----------------------------------------------------------------------

# APP was validated against APPS at the top, so the function name is safe.
main() {
	"minx_install_$APP"
}

minx_run_and_log "$LOGFILE" main
exit $?
