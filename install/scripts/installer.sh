#!/usr/bin/env bash

# shellcheck disable=SC1091 # global variables
# shellcheck disable=SC1090
set -euo pipefail
# set -x

# Setup
# ----------------------------------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/utils.sh"
minx_test_all_info || exit 1

readonly ACTION="${1:-variable not set}"

readonly APP="${2:-variable not set}"

LOGFILE="$MINX_LOG_DIR/$(minx_get_script_name)_${APP}_$(minx_get_date).log"

# Helpers
# ----------------------------------------------------------------------

_minx_msg() { printf '=> %s\n' "$*"; }

_minx_fail() {
	printf '=> [FAIL] %s\n' "$*" >&2
	return 1
}

_minx_header() { minx_header "L1" "[args: $APP $ACTION] $*"; }

_minx_is_build() { [[ $ACTION == "--build" ]]; }

# Build runs as the regular user, install runs as root.
_minx_assert_phase_user() {
	if _minx_is_build; then
		minx_assert_is_non_root "$0"
	else
		minx_assert_is_root "$0"
	fi
}

_minx_require_file() { [[ -f $1 ]] || _minx_fail "${2:-File} not found: $1"; }
_minx_require_dir() { [[ -d $1 ]] || _minx_fail "${2:-Directory} not found: $1"; }
_minx_require_exec() { [[ -x $1 ]] || _minx_fail "${2:-Executable} not found: $1"; }

_minx_git_trust() { git config --global --add safe.directory "$1"; }

# Remove and recreate a directory.
_minx_fresh_dir() {
	minx_safe_rm_dir "$1" && mkdir -p -- "$1"
}

# Clone a pinned project (url_<name>, commit_<name>) into $MINX_REPOS_DIR/<name>.
_minx_checkout_pinned() { # <name>
	local name="$1"

	minx_git_clone_at_commit \
		"$MINX_REPOS_DIR/$name" \
		"${MINX_PINNED_VERSIONS[url_$name]}" \
		"${MINX_PINNED_VERSIONS[commit_$name]}"
}

# Same, with an optional patch file.
_minx_checkout_patched() { # <name> [patch-file]
	local name="$1" patch="${2:-}"

	minx_git_clone_and_patch \
		"$MINX_REPOS_DIR/$name" \
		"${MINX_PINNED_VERSIONS[url_$name]}" \
		"${MINX_PINNED_VERSIONS[commit_$name]}" \
		${patch:+"$patch"}
}

_minx_download_or_clean() { # <url> <destination>
	minx_download_file "$1" "$2" || {
		rm -f -- "$2"
		return 1
	}
}

_minx_load_nvm() {
	NVM_DIR="$HOME/.nvm"
	[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
	[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
	return 0
}

_minx_load_cargo() {
	# shellcheck disable=SC1091
	source "$HOME/.cargo/env"
}

# Run "<bin_dir>/<binary> <args>" as a smoke test, then add bin_dir to PATH.
# --lenient: ignore the exit status of the binary (suckless tools exit 1 on -v).
_minx_verify_bin() { # [--lenient] <bin_dir> <binary> [args...]
	local lenient=0

	if [[ ${1:-} == --lenient ]]; then
		lenient=1
		shift
	fi

	local bin_dir="$1" bin="$2"
	shift 2

	_minx_msg "Verify ..."

	if ! "$bin_dir/$bin" "$@"; then
		((lenient)) || return 1
	fi

	minx_add_to_PATH "$bin_dir"
}

_minx_cmake_build() { # <repo_dir> <build_dir> <install_dir>
	cmake -S "$1" -B "$2" \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_INSTALL_PREFIX="$3" || return 1

	cmake --build "$2" --parallel "$(nproc)"
}

# Install a file with explicit mode, with the usual log lines.
_minx_install_file() { # <mode> <source> <destination> <label>
	_minx_msg "Installing $4"
	_minx_msg "Source:      $2"
	_minx_msg "Destination: $3"

	install -m "$1" -- "$2" "$3" || _minx_fail "Failed to install: $3"
}

# Append an apt source line unless it is already present.
_minx_add_apt_source() { # <file> <line>
	grep -qxF -- "$2" "$1" 2>/dev/null ||
		printf '%s\n' "$2" | sudo tee -a "$1"
}

# Installers
# ----------------------------------------------------------------------

minx_install_go() ( # {{{
	local version="${MINX_PINNED_VERSIONS[version_go]}"
	local tarball="go${version}.linux-amd64.tar.gz"
	local url="${MINX_PINNED_VERSIONS[url_go]}$tarball"
	local dst_file="$MINX_DOWNLOADS_DIR/$tarball"

	_minx_header "Install Go $version"

	minx_assert_is_root "$0" || return 1

	minx_safe_rm_dir "$MINX_INSTALLATION_DIR/go" || return 1

	_minx_download_or_clean "$url" "$dst_file" || return 1

	_minx_msg "Installing ..."

	tar -C "$MINX_INSTALLATION_DIR" -xzf "$dst_file" || {
		rm -f -- "$dst_file"
		return 1
	}

	_minx_msg "Verifying installation ..."

	_minx_verify_bin "$MINX_INSTALLATION_DIR/go/bin" go version || return 1

	_minx_msg "Done"
) # }}}

minx_install_jetbrains_mono() ( # {{{
	local font_version="${MINX_PINNED_VERSIONS[version_jetbrains_mono]}"
	local font_name="JetBrainsMono"
	local font_dir="/usr/share/fonts/jetbrains-mono"
	local zip_file="${font_name}.zip"
	local download_url="${MINX_PINNED_VERSIONS[url_jetbrains_mono]}/download/${font_version}/${zip_file}"
	local dst_file="$MINX_REPOS_DIR/download/$zip_file"

	# NOTE: literal "font_name" (probably meant $font_name); kept as it was.
	local install_dir="$MINX_INSTALLATION_DIR/font_name"

	_minx_header "Install JetBrains Mono $font_version"

	minx_assert_is_root "$0" || return 1

	if [[ -d "$font_dir" ]]; then
		_minx_msg "JetBrains Mono already installed."
		return 0
	fi

	_minx_download_or_clean "$download_url" "$dst_file" || return 1

	_minx_msg "Installing ..."

	unzip -q "$dst_file" -d "$install_dir" || return 1

	mkdir -p -- "$font_dir"

	while IFS= read -r -d '' file; do
		cp -- "$file" "$font_dir/"
	done < <(find "$install_dir" -type f -iname '*.ttf' -print0)

	fc-cache -f

	_minx_msg "Done"
) # }}}

minx_install_qemu() ( # {{{
	local packages=(
		qemu-system
		qemu-utils
		qemu-kvm
		libvirt-daemon-system
		libvirt-clients
		virt-manager
	)
	local loguser

	_minx_header "QEMU"

	minx_assert_is_root "$0" || return 1

	_minx_msg "Updating package index..."
	apt update

	_minx_msg "Installing QEMU and related packages..."
	apt install -y "${packages[@]}"

	_minx_msg "Checking virtualization support..."

	if grep -Eq '(vmx|svm)' /proc/cpuinfo; then
		_minx_msg "CPU virtualization supported."
	else
		_minx_msg "Warning: CPU virtualization not detected."
	fi

	_minx_msg "Checking /dev/kvm..."

	if [[ -e /dev/kvm ]]; then
		_minx_msg "/dev/kvm exists."
	else
		_minx_msg "Warning: /dev/kvm not found."
	fi

	loguser="$(logname)"

	_minx_msg "Adding $loguser to kvm and libvirt groups..."
	usermod -aG kvm "$loguser"
	usermod -aG libvirt "$loguser"

	_minx_msg "Enabling and starting libvirt service..."
	systemctl enable --now libvirtd

	_minx_msg "Verifying installation..."

	if command -v qemu-system-x86_64 >/dev/null 2>&1; then
		qemu-system-x86_64 --version
	else
		_minx_msg "Warning: qemu-system-x86_64 not found in PATH."
	fi

	_minx_msg "Done"
) # }}}

minx_install_rust_and_cargo() ( # {{{
	local rustup_url="https://sh.rustup.rs"

	_minx_header "Rust and cargo"

	minx_assert_is_non_root "$0" || return 1

	if ! minx_command_exists rustup; then
		_minx_msg "Installing rustup ..."
		curl --proto '=https' --tlsv1.2 -sSf "$rustup_url" | sh -s -- -y
	fi

	_minx_msg "Installing toolchain ..."

	_minx_load_cargo || return 1
	rustup toolchain install stable
	rustup default stable

	_minx_msg "Verify ..."

	rustc --version
	cargo --version

	_minx_msg "Done"
) # }}}

minx_install_nvm_and_nodejs() ( # {{{
	local nvm_version="${MINX_PINNED_VERSIONS[version_nvm]}"
	local nodejs_version="${MINX_PINNED_VERSIONS[version_nodejs]}"
	local url="${MINX_PINNED_VERSIONS[url_nvm]}/$nvm_version/install.sh"

	_minx_header "nvm and node.js"

	minx_assert_is_non_root "$0" || return 1

	rm -rf -- "$HOME/.nvm"

	_minx_msg "Installing NVM $nvm_version"

	curl -o- "$url" | bash

	_minx_msg "Installing ..."

	_minx_load_nvm

	nvm install "$nodejs_version"
	nvm alias default "$nodejs_version"
	nvm use default

	_minx_msg "Verify ..."

	node --version
	npm --version

	_minx_msg "Done"
) # }}}

minx_install_nodejs_packages() { # {{{
	local nodejs_packages=(
		markdownlint-cli
	)

	_minx_header "node.js packages"

	minx_assert_is_non_root "$0" || return 1

	_minx_load_nvm

	npm install -g "${nodejs_packages[@]}"

	_minx_msg "Done"
} # }}}

minx_install_pipx_packages() { # {{{
	local pipx_packages=(
		black
		flake8
		isort
		khal
		mypy
		pre-commit
		proselint
		pycln
		pylint
		vdirsyncer
		yamllint
		yt-dlp
	)
	local pkg

	_minx_header "pipx packages"

	minx_assert_is_non_root "$0" || return 1

	for pkg in "${pipx_packages[@]}"; do
		pipx install --force "$pkg"
	done

	_minx_msg "Done"
} # }}}

minx_install_go_packages() { # {{{
	local go_packages=(
		mvdan.cc/sh/v3/cmd/shfmt@"${MINX_PINNED_VERSIONS[version_shfmt]}"
	)

	_minx_header "go_packages"

	minx_assert_is_non_root "$0" || return 1

	go install "${go_packages[@]}"

	_minx_msg "Make sure PATH contains: $(go env GOPATH)/bin/"
	_minx_msg "Done"
} # }}}

minx_install_ctags() ( # {{{
	local repo_dir="$MINX_REPOS_DIR/ctags"
	local install_dir="$MINX_INSTALLATION_DIR/ctags"

	_minx_header "$install_dir"

	_minx_assert_phase_user || return 1

	if _minx_is_build; then
		_minx_checkout_pinned ctags || return 1

		cd -- "$repo_dir" || return 1

		./autogen.sh || return 1
		./configure --prefix="$install_dir" || return 1
		make -j"$(nproc)" || return 1
	else
		cd -- "$repo_dir" || return 1

		_minx_git_trust "$repo_dir"

		_minx_fresh_dir "$install_dir" || return 1

		make install || return 1

		_minx_verify_bin "$install_dir/bin" ctags --version || return 1
	fi

	_minx_msg "Done"
) # }}}

minx_install_taskwarrior() ( # {{{
	local repo_dir="$MINX_REPOS_DIR/taskwarrior"
	local build_dir="$repo_dir/_build"
	local install_dir="$MINX_INSTALLATION_DIR/taskwarrior"

	_minx_header "$repo_dir"

	_minx_assert_phase_user || return 1

	if _minx_is_build; then
		_minx_load_cargo || return 1

		_minx_checkout_pinned taskwarrior || return 1

		cd -- "$repo_dir" || return 1

		git submodule update --init --recursive
		rustup update stable

		rm -rf -- "$build_dir"

		_minx_cmake_build "$repo_dir" "$build_dir" "$install_dir" || return 1
	else
		_minx_fresh_dir "$install_dir" || return 1

		cmake --install "$build_dir" || return 1

		_minx_verify_bin "$install_dir/bin" task --version || return 1
	fi

	_minx_msg "Done"
) # }}}

minx_install_timewarrior() ( # {{{
	local repo_dir="$MINX_REPOS_DIR/timewarrior"
	local build_dir="$repo_dir/_build"
	local install_dir="$MINX_INSTALLATION_DIR/timewarrior"

	_minx_header "$repo_dir"

	_minx_assert_phase_user || return 1

	if _minx_is_build; then
		_minx_checkout_pinned timewarrior || return 1

		cd -- "$repo_dir" || return 1

		git submodule update --init --recursive

		_minx_msg "Building ... "

		_minx_cmake_build "$repo_dir" "$build_dir" "$install_dir" || return 1
	else
		_minx_fresh_dir "$install_dir" || return 1

		cmake --install "$build_dir" || return 1

		_minx_verify_bin "$install_dir/bin" timew --version || return 1
	fi

	_minx_msg "Done"
) # }}}

minx_install_qutebrowser() ( # {{{
	local repo_dir="$MINX_REPOS_DIR/qutebrowser"
	local install_dir="$MINX_INSTALLATION_DIR/qutebrowser/bin"
	local executable="$install_dir/qutebrowser"
	local python="$repo_dir/.venv/bin/python"
	local script="$repo_dir/qutebrowser.py"

	minx_assert_has_display || return 1

	_minx_header "$repo_dir"

	minx_assert_is_root "$0" || return 1

	_minx_git_trust "$repo_dir"

	_minx_checkout_pinned qutebrowser || return 1

	_minx_msg "Building ... "

	cd -- "$repo_dir" || return 1

	_minx_git_trust .

	python3 scripts/mkvenv.py || return 1

	_minx_msg "Installing ... "

	_minx_fresh_dir "$install_dir" || return 1

	{
		printf '%s\n' '#!/usr/bin/env bash'
		printf 'exec %q %q "$@"\n' "$python" "$script"
	} >"$executable" || return 1

	chmod +x "$executable" || return 1

	_minx_msg "Verify ..."

	minx_run "$executable" -h || return 1

	_minx_msg "Done"
) # }}}

minx_install_vim() ( # {{{
	local repo_dir="$MINX_REPOS_DIR/vim"
	local install_dir="$MINX_INSTALLATION_DIR/vim"

	_minx_header "$repo_dir"

	_minx_assert_phase_user || return 1

	if _minx_is_build; then
		_minx_checkout_pinned vim || return 1

		cd -- "$repo_dir" || return 1

		make distclean || true

		minx_command_exists python3 || return 1

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

	_minx_msg "Done"
) # }}}

minx_install_languagetool() { # {{{
	local lt_src_dir="$MINX_REPOS_DIR/languagetool"
	local lt_install_dir="$MINX_INSTALLATION_DIR/languagetool"

	local lt_snapshot="${MINX_PINNED_VERSIONS[snapshot_languagetool]}"
	local lt_zip_file="$lt_src_dir/$lt_snapshot"
	local lt_url="${MINX_PINNED_VERSIONS[url_languagetool]}/$lt_snapshot"

	local ft_repo_dir="$lt_src_dir/fastText"
	local ft_binary_src="$ft_repo_dir/fasttext"

	# The model is fetched and verified by download_repos.sh (remote server).
	local ft_model_file="$lt_src_dir/lid.176.bin"
	local ft_model_sha256="${MINX_PINNED_VERSIONS[sha256_fasttext_model]:-}"

	_minx_header "languagetool with fasttext"

	# ------------------------------------------------------------------
	# Build
	# ------------------------------------------------------------------

	if _minx_is_build; then
		minx_assert_is_non_root "$0" || return 1

		mkdir -p -- "$lt_src_dir" || return 1

		if minx_path_exists "$lt_zip_file"; then
			_minx_msg "LanguageTool already downloaded."
		else
			_minx_msg "Downloading LanguageTool..."
			minx_download_file "$lt_url" "$lt_zip_file" || return 1
		fi

		_minx_require_file "$lt_zip_file" "LanguageTool archive" || return 1

		minx_git_clone_at_commit \
			"$ft_repo_dir" \
			"${MINX_PINNED_VERSIONS[url_fasttext]}" \
			"${MINX_PINNED_VERSIONS[commit_fasttext]}" || return 1

		_minx_msg "Building fastText..."

		make -C "$ft_repo_dir" clean || return 1
		make -C "$ft_repo_dir" -j"$(nproc)" || return 1

		_minx_require_exec "$ft_binary_src" "fastText binary" || return 1

		if [[ ! -f "$ft_model_file" ]]; then
			_minx_fail "Language identification model not found: $ft_model_file"
			_minx_msg "Run download_repos.sh first (fetches it from the remote server)." >&2
			return 1
		fi

		# Never deletes the file on mismatch, so it can be inspected.
		minx_verify_sha256 "$ft_model_file" "$ft_model_sha256" || return 1

		_minx_msg "Build complete."
		return 0
	fi

	# ------------------------------------------------------------------
	# Install
	# ------------------------------------------------------------------

	minx_assert_is_root "$0" || return 1

	_minx_require_file "$lt_zip_file" "LanguageTool archive" || return 1
	_minx_require_exec "$ft_binary_src" "fastText binary" || return 1
	_minx_require_file "$ft_model_file" "fastText model" || return 1

	# The model lives in a user-writable directory and is installed as root:
	# verify it again right before copying it.
	minx_verify_sha256 "$ft_model_file" "$ft_model_sha256" || return 1

	_minx_fresh_dir "$lt_install_dir" || _minx_fail "Failed to create: $lt_install_dir" || return 1

	_minx_msg "Determining LanguageTool directory"

	local archive_listing lt_dir

	# Captured first: piping unzip into awk's early exit would fail under pipefail.
	archive_listing="$(unzip -Z1 "$lt_zip_file" 2>/dev/null)" ||
		_minx_fail "Failed to inspect archive: $lt_zip_file" || return 1

	lt_dir="$(
		printf '%s\n' "$archive_listing" |
			awk -F/ 'NF > 1 && $1 != "" { print $1; exit }'
	)"

	[[ -n $lt_dir ]] ||
		_minx_fail "Could not determine LanguageTool directory from: $lt_zip_file" || return 1

	_minx_msg "LanguageTool directory: $lt_dir"
	_minx_msg "Extracting LanguageTool"

	unzip -q "$lt_zip_file" -d "$lt_install_dir" ||
		_minx_fail "Failed to extract LanguageTool" || return 1

	local lt_root="$lt_install_dir/$lt_dir"

	_minx_require_dir "$lt_root" "LanguageTool directory" || return 1
	_minx_msg "LanguageTool installed: $lt_root"

	local ft_binary_dst="$lt_root/${ft_binary_src##*/}"
	local ft_model_dst="$lt_root/${ft_model_file##*/}"

	_minx_install_file 0755 "$ft_binary_src" "$ft_binary_dst" "fastText binary" || return 1
	_minx_install_file 0644 "$ft_model_file" "$ft_model_dst" "language identification model" || return 1

	local server_properties="$lt_install_dir/server.properties"

	_minx_msg "Creating server.properties"
	_minx_msg "Config: $server_properties"

	{
		printf 'fasttextModel=%s\n' "$ft_model_dst"
		printf 'fasttextBinary=%s\n' "$ft_binary_dst"
	} >"$server_properties" ||
		_minx_fail "Failed to create: $server_properties" || return 1

	[[ -s "$server_properties" ]] ||
		_minx_fail "server.properties is empty: $server_properties" || return 1

	_minx_msg "Validating LanguageTool installation"

	_minx_require_file "$lt_root/languagetool-server.jar" "LanguageTool server JAR" || return 1

	_minx_msg "LanguageTool installation complete."
	_minx_msg "LanguageTool: $lt_root"
	_minx_msg "Server JAR:   $lt_root/languagetool-server.jar"
	_minx_msg "fastText:     $ft_binary_dst"
	_minx_msg "Model:        $ft_model_dst"
	_minx_msg "Config:       $server_properties"
	_minx_msg "Done"
} # }}}

minx_install_pdfjs() ( # {{{
	local repo_dir="$MINX_REPOS_DIR/pdfjs"
	local install_dir="$MINX_INSTALLATION_DIR/pdfjs"

	_minx_header "$install_dir"

	_minx_load_nvm

	_minx_assert_phase_user || return 1

	if _minx_is_build; then
		_minx_checkout_pinned pdfjs || return 1

		cd -- "$repo_dir" || return 1

		_minx_msg "Building ..."

		npm ci || return 1
		npx gulp generic || return 1
	else
		_minx_fresh_dir "$install_dir" || return 1

		_minx_msg "Installing ..."

		rsync -a "$repo_dir/build/generic/" "$install_dir/" || return 1

		mkdir -p /usr/share/pdf.js
		minx_symlink "$install_dir/web" /usr/share/pdf.js/web
		minx_symlink "$install_dir/build" /usr/share/pdf.js/build

		_minx_msg "Verify"

		_minx_require_dir "$install_dir/web" || return 1
		_minx_require_dir "$install_dir/build" || return 1
		[[ -L /usr/share/pdf.js/web ]] || return 1
		[[ -L /usr/share/pdf.js/build ]] || return 1
	fi

	_minx_msg "Done"
) # }}}

minx_install_runtime() { # {{{
	minx_header "L1" "[args: $APP $ACTION] $MINX_REPOS_DIR/$APP"

	minx_assert_is_root "$0" || exit 1

	local runtime_dir="$MINX_INSTALLATION_DIR/runtime"
	local profile_file="/etc/profile.d/minx_profile.sh"
	local profile_template="$MINX_INSTALLER_ROOT/install/config/template_minx_profile.sh"
	local version_script="$runtime_dir/system/bin/minx-version"

	# Variable names are read from the template: @@MINX_<name>@@ is replaced
	# by the value of MINX_<name>. Nothing to keep in sync by hand.
	local -a profile_vars
	mapfile -t profile_vars < <(
		grep -o '@@MINX_[A-Z_]*@@' "$profile_template" |
			sort -u | sed -e 's/^@@MINX_//' -e 's/@@$//'
	)
	local -a sed_args=()
	local name ref escaped answer

	if [[ -e "$runtime_dir" ]]; then
		printf '=> %s already exists. Override? [y/N] ' "$runtime_dir"
		read -r answer

		if [[ "$answer" =~ ^[Yy]$ ]]; then
			rm -rf -- "$runtime_dir" || exit 1
		else
			printf '\n%s\n' "=> Skipping 'runtime' installation."
			return 0
		fi
	fi

	_minx_msg "Copying 'runtime' ..."

	cp -rf -- "$MINX_INSTALLER_ROOT/runtime" "$runtime_dir" || exit 1

	_minx_msg "Creating minx-version ..."

	mkdir -p -- "${version_script%/*}" || exit 1

	# Unquoted heredoc: only the escaped \$ expressions are evaluated when the
	# script runs. The installation directory is baked in as a fallback, so the
	# command also works when MINX_INSTALLATION_DIR is not exported.
	cat >"$version_script" <<EOF || exit 1
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

	chmod 755 -- "$version_script" || exit 1

	tree "$runtime_dir"

	_minx_msg "Installing minx_profile.sh ..."

	# Build one sed expression per variable. Escape characters that are special
	# in a sed replacement: \ & and the delimiter |
	for name in "${profile_vars[@]}"; do
		ref="MINX_$name"

		if [[ ! -v $ref ]]; then
			printf '%s\n' "=> ERROR: $ref is not set" >&2
			exit 1
		fi

		escaped=$(printf '%s' "${!ref}" | sed -e 's/[\\&|]/\\&/g') || exit 1
		sed_args+=(-e "s|@@MINX_${name}@@|${escaped}|g")
	done

	# Substitute while copying, so placeholders never land in /etc/profile.d
	sed "${sed_args[@]}" "$profile_template" >"$profile_file" || exit 1

	chmod 644 -- "$profile_file" || exit 1

	# Catch placeholders that were not substituted (e.g. a leftover @@MXC_...@@)
	if grep -q '@@[A-Z_]*@@' "$profile_file"; then
		printf '%s\n' "=> ERROR: unresolved placeholder in $profile_file" >&2
		exit 1
	fi

	_minx_msg "Done"
} # }}}

# dwm, sent, st and slock share the same build/install scripts.
_minx_install_suckless() { # <name> [VAR=value ...]
	local name="$1"
	shift

	local repo_dir="$MINX_REPOS_DIR/$name"
	local install_dir="$MINX_INSTALLATION_DIR/$name"
	local -a build_env=("DESTDIR=$install_dir" "$@")

	_minx_header "$repo_dir"

	_minx_assert_phase_user || return 1

	if _minx_is_build; then
		_minx_checkout_patched "$name" "$MINX_INSTALLER_PATCHES_DIR/suckless/$name.diff" ||
			return 1

		_minx_msg "Building ..."

		env "${build_env[@]}" "$repo_dir/install.sh" --build || return 1
	else
		_minx_git_trust "$repo_dir"

		_minx_msg "Installing ..."

		env "${build_env[@]}" "$repo_dir/install.sh" --install || return 1

		# suckless tools print their version and exit with status 1 on -v.
		_minx_verify_bin --lenient "$install_dir/usr/local/bin" "$name" -v || return 1
	fi

	_minx_msg "Done"
}

minx_install_dwm() {
	_minx_install_suckless dwm \
		"SCRIPTS_DIR=$MINX_INSTALLATION_DIR/runtime/system/bin"
}

minx_install_sent() { _minx_install_suckless sent; }
minx_install_st() { _minx_install_suckless st; }
minx_install_slock() { _minx_install_suckless slock; }

minx_install_invariant_repos() {

	minx_assert_is_non_root "$0" || return 1

	_minx_header "qb dracula theme"

	_minx_checkout_patched qutebrowser_dracula_theme \
		"$MINX_INSTALLER_PATCHES_DIR/qutebrowser_dracula_theme.diff" || return 1
	_minx_msg "Done"

	_minx_header "latex snippets"
	_minx_checkout_patched latex_snippets || return 1

	_minx_header "linux a11y sound theme"
	_minx_checkout_patched linux_a11y_sound_theme || return 1

	_minx_header "tmpi"
	_minx_checkout_patched tmpi || return 1

	_minx_msg "Install ..."

	cd "$MINX_REPOS_DIR/tmpi" || return 1

	local -A file_map
	file_map+=(
		# [dst]=src
		["$HOME/.local/bin/tmpi"]="$MINX_REPOS_DIR/tmpi/tmpi"
		["$HOME/.config/qutebrowser/dracula"]="$MINX_REPOS_DIR/qutebrowser_dracula_theme/"
	)

	minx_symlink_map file_map

	_minx_msg "Done"
}

_parse_arguments() { # {{{

	for arg in "$@"; do
		case "$arg" in
		--build) ACTION="--build" ;;
		--install) ACTION="--install" ;;
		*)
			[[ -z "$arg" ]] && continue
			printf '%s\n' "Invalid argument: $arg"
			return 1
			;;
		esac
	done

	readonly APP
	readonly ACTION
} # }}}

minx_install_onlyoffice() {
	minx_assert_is_root
	minx_assert_has_display

	minx_header "L1" "Onlyoffice"

	_minx_msg "Installing ..."

	mkdir -p ~/.gnupg
	chmod 700 ~/.gnupg

	gpg \
		--no-default-keyring \
		--keyring gnupg-ring:/tmp/onlyoffice.gpg \
		--keyserver hkp://keyserver.ubuntu.com:80 \
		--recv-keys CB2DE8E5

	chmod 644 /tmp/onlyoffice.gpg
	sudo chown root:root /tmp/onlyoffice.gpg
	sudo mv /tmp/onlyoffice.gpg /usr/share/keyrings/onlyoffice.gpg

	_minx_add_apt_source /etc/apt/sources.list.d/onlyoffice.list \
		'deb [signed-by=/usr/share/keyrings/onlyoffice.gpg] https://download.onlyoffice.com/repo/debian squeeze main'

	sudo apt-get update
	sudo apt-get install onlyoffice-desktopeditors

	_minx_msg "Done"
}

minx_install_librewolf() {
	minx_assert_is_root
	minx_assert_has_display

	minx_header "L1" "librewolf"

	_minx_msg "Installing ..."

	sudo apt update && sudo apt install extrepo -y
	sudo extrepo enable librewolf && sudo extrepo update librewolf
	sudo apt update && sudo apt install librewolf -y

	_minx_msg "Done"
}

minx_install_spotify() {
	minx_assert_is_root
	minx_assert_has_display

	minx_header "L1" "Spotify"

	_minx_msg "Installing ..."

	curl -sS \
		https://download.spotify.com/debian/pubkey_5384CE82BA52C83A.asc |
		sudo gpg --dearmor --yes -o /etc/apt/trusted.gpg.d/spotify.gpg

	_minx_add_apt_source /etc/apt/sources.list.d/spotify.list \
		'deb https://repository.spotify.com stable non-free'

	sudo apt-get update
	sudo apt-get install spotify-client

	_minx_msg "Done"
}

minx_install_calix() ( # {{{
	local version="${MINX_PINNED_VERSIONS[version_calix]}"
	local release_tag="v${version}"
	local archive_name="calix-${version}-linux-x86_64.tar.gz"
	local archive_dir="calix-${version}-linux-x86_64"
	local download_url="${MINX_PINNED_VERSIONS[url_calix]}/download/${release_tag}/${archive_name}"

	local download_dir="$MINX_REPOS_DIR/downloads/calix"
	local dst_file="$download_dir/$archive_name"
	local tmp_dir
	local bin_dir="$HOME/.local/bin"

	_minx_header "Install Calix $version"

	# Calix installs into the user's ~/.local directory.
	minx_assert_is_non_root "$0" || return 1

	if [[ -x "$bin_dir/calix" ]] &&
		"$bin_dir/calix" --version 2>/dev/null | grep -q "$version"; then
		_minx_msg "Calix $version already installed."
		return 0
	fi

	mkdir -p -- "$download_dir" || return 1

	tmp_dir="$(mktemp -d)" || return 1
	trap 'rm -rf -- "$tmp_dir"' EXIT

	if [[ -f "$dst_file" ]]; then
		_minx_msg "Using existing archive: $dst_file"
	else
		_minx_download_or_clean "$download_url" "$dst_file" || return 1
	fi

	_minx_msg "Extracting ..."

	tar -xzf "$dst_file" -C "$tmp_dir" || return 1

	local install_dir="$tmp_dir/$archive_dir"

	_minx_require_exec "$install_dir/install.sh" "Calix install.sh" || return 1

	_minx_msg "Installing ..."

	(
		cd "$install_dir"
		./install.sh
	) || return 1

	_minx_msg "Verifying installation ..."

	_minx_require_exec "$bin_dir/calix" "Calix executable" || return 1

	"$bin_dir/calix" --version || return 1

	_minx_msg "Done"
) # }}}

main() {

	# ACTION case
	case "$ACTION" in
	--build) ;;
	--install) ;;
	*)
		_minx_msg "Invalid action: $ACTION"
		return 1
		;;
	esac

	# APP case
	case "$APP" in

	ctags)
		minx_install_ctags || return 1
		;;

	dwm)
		minx_install_dwm || return 1
		;;

	runtime)
		minx_install_runtime || return 1
		;;

	go)
		minx_install_go || return 1
		;;

	jetbrains_mono)
		minx_install_jetbrains_mono || return 1
		;;

	languagetool)
		minx_install_languagetool || return 1
		;;

	nvm_and_nodejs)
		minx_install_nvm_and_nodejs || return 1
		;;

	pdfjs)
		minx_install_pdfjs || return 1
		;;

	qb_dracula_theme)
		minx_install_qb_dracula_theme || return 1
		;;

	qemu)
		minx_install_qemu || return 1
		;;

	qutebrowser)
		minx_install_qutebrowser || return 1
		;;

	rust_and_cargo)
		minx_install_rust_and_cargo || return 1
		;;

	sent)
		minx_install_sent || return 1
		;;

	st)
		minx_install_st || return 1
		;;

	slock)
		minx_install_slock || return 1
		;;

	taskwarrior)
		minx_install_taskwarrior || return 1
		;;

	timewarrior)
		minx_install_timewarrior || return 1
		;;

	pipx_packages)
		minx_install_pipx_packages || return 1
		;;

	nodejs_packages)
		minx_install_nodejs_packages || return 1
		;;

	go_packages)
		minx_install_go_packages || return 1
		;;

	vim)
		minx_install_vim || return 1
		;;

	spotify)
		minx_install_spotify || return 1
		;;

	onlyoffice)
		minx_install_onlyoffice || return 1
		;;

	librewolf)
		minx_install_librewolf || return 1
		;;

	calix)
		minx_install_calix || return 1
		;;

	invariant_repos)
		minx_install_invariant_repos || return 1
		;;

	*)
		_minx_msg "Invalid app: $APP"
		return 1
		;;
	esac
}

minx_run_and_log "$LOGFILE" main "$@"
