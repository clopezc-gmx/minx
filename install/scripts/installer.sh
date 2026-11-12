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

minx_install_go() ( # {{{
	local version="${MINX_PINNED_VERSIONS[version_go]}"
	local tarball="go${version}.linux-amd64.tar.gz"
	local url="${MINX_PINNED_VERSIONS[url_go]}$tarball"

	minx_header "L1" "[args: $APP $ACTION] Install Go $version"

	minx_assert_is_root "$0" || return 1

	minx_safe_rm_dir "$MINX_INSTALLATION_DIR/go" || return 1

	local dst_file="$MINX_DOWNLOADS_DIR/$tarball"

	minx_download_file "$url" "$dst_file" || {
		rm "$dst_file"
		return 1
	}

	printf '%s\n' "=> Installing ..."

	tar -C "$MINX_INSTALLATION_DIR" -xzf "$dst_file" || {
		rm "$dst_file"
		return 1
	}

	printf '%s\n' "=> Verifying installation ..."

	local bin_dir
	bin_dir="$MINX_INSTALLATION_DIR/go/bin"

	"$bin_dir/go" version || return 1

	minx_add_to_PATH "$bin_dir" || return 1

	printf '%s\n' "=> Done"
) # }}}

minx_install_jetbrains_mono() ( # {{{
	local font_version="${MINX_PINNED_VERSIONS[version_jetbrains_mono]}"
	local font_name="JetBrainsMono"
	local font_dir="/usr/share/fonts/jetbrains-mono"
	local zip_file="${font_name}.zip"
	local download_url="${MINX_PINNED_VERSIONS[url_jetbrains_mono]}/download/${font_version}/${zip_file}"

	local install_dir="$MINX_INSTALLATION_DIR/font_name"

	minx_header "L1" "[args: $APP $ACTION] Install JetBrains Mono $font_version"
	minx_assert_is_root "$0" || return 1

	if [[ -d "$font_dir" ]]; then
		printf '%s\n' "=> JetBrains Mono already installed."
		return 0
	fi

	local dst_file="$MINX_REPOS_DIR/download/$zip_file"

	minx_download_file "$download_url" "$dst_file" || {
		rm "$dst_file"
		return 1
	}

	printf '%s\n' "=> Installing ..."

	unzip -q "$dst_file" -d "$install_dir"

	mkdir -p -- "$font_dir"

	while IFS= read -r -d '' file; do
		cp -- "$file" "$font_dir/"
	done < <(find "$install_dir" -type f -iname '*.ttf' -print0)

	fc-cache -f

	printf '%s\n' "=> Done"
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

	minx_header "L1" "[args: $APP $ACTION] QEMU"
	minx_assert_is_root "$0" || return 1

	printf '%s\n' "=> Updating package index..."
	apt update

	printf '%s\n' "=> Installing QEMU and related packages..."
	apt install -y "${packages[@]}"

	printf '%s\n' "=> Checking virtualization support..."

	if grep -Eq '(vmx|svm)' /proc/cpuinfo; then
		printf '%s\n' "=> CPU virtualization supported."
	else
		printf '%s\n' "=> Warning: CPU virtualization not detected."
	fi

	printf '%s\n' "=> Checking /dev/kvm..."

	if [[ -e /dev/kvm ]]; then
		printf '%s\n' "=> /dev/kvm exists."
	else
		printf '%s\n' "=> Warning: /dev/kvm not found."
	fi

	loguser="$(logname)"

	printf '=> Adding %s to kvm and libvirt groups...\n' "$loguser"
	usermod -aG kvm "$loguser"
	usermod -aG libvirt "$loguser"

	printf '%s\n' "=> Enabling and starting libvirt service..."
	systemctl enable --now libvirtd

	printf '%s\n' "=> Verifying installation..."

	if command -v qemu-system-x86_64 >/dev/null 2>&1; then
		qemu-system-x86_64 --version
	else
		printf '%s\n' "=> Warning: qemu-system-x86_64 not found in PATH."
	fi

	printf '%s\n' "=> Done"
) # }}}

minx_install_rust_and_cargo() ( # {{{
	local rustup_url="https://sh.rustup.rs"

	minx_header "L1" "[args: $APP $ACTION] Rust and cargo"

	minx_assert_is_non_root "$0" || return 1

	if ! minx_command_exists rustup; then
		printf '%s\n' "=> Installing rustup ..."
		curl --proto '=https' --tlsv1.2 -sSf "$rustup_url" | sh -s -- -y
	fi

	printf '%s\n' "=> Installing toolchain ..."

	# shellcheck disable=SC1091
	source "$HOME/.cargo/env" || return 1
	rustup toolchain install stable
	rustup default stable

	printf '%s\n' "=> Verify ..."

	rustc --version
	cargo --version

	printf '%s\n' "=> Done"
) # }}}

minx_install_nvm_and_nodejs() ( # {{{
	local nvm_version="${MINX_PINNED_VERSIONS[version_nvm]}"
	local nodejs_version="${MINX_PINNED_VERSIONS[version_nodejs]}"
	local url="${MINX_PINNED_VERSIONS[url_nvm]}/$nvm_version/install.sh"

	minx_header "L1" "[args: $APP $ACTION] nvm and node.js"

	minx_assert_is_non_root "$0" || return 1

	rm -rf -- "$HOME/.nvm"

	printf '=> Installing NVM %s\n' "$nvm_version"

	curl -o- "$url" | bash

	printf '%s\n' "=> Installing ... "

	NVM_DIR="$HOME/.nvm"
	[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
	[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

	nvm install "$nodejs_version"
	nvm alias default "$nodejs_version"
	nvm use default

	printf '%s\n' "=> Verify ..."

	node --version
	npm --version

	printf '%s\n' "=> Done"
) # }}}

minx_install_nodejs_packages() { # {{{
	minx_header "L1" "[args: $APP $ACTION] node.js packages"

	minx_assert_is_non_root "$0" || return 1

	NVM_DIR="$HOME/.nvm"
	[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
	[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

	local nodejs_packages=(
		markdownlint-cli
	)

	npm install -g "${nodejs_packages[@]}"

	printf '%s\n' "=> Done"
} # }}}

minx_install_pipx_packages() { # {{{
	minx_header "L1" "[args: $APP $ACTION] pipx packages"

	minx_assert_is_non_root "$0" || return 1

	local flags="--force"
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

	for pkg in "${pipx_packages[@]}"; do
		pipx install "$flags" "$pkg"
	done

	printf '%s\n' "=> Done"
} # }}}

minx_install_go_packages() { # {{{
	local hmsg="go_packages"
	minx_header "L1" "[args: $APP $ACTION] $hmsg"

	minx_assert_is_non_root "$0" || return 1

	local go_packages=(
		mvdan.cc/sh/v3/cmd/shfmt@"${MINX_PINNED_VERSIONS[version_shfmt]}"
	)

	go install "${go_packages[@]}"

	printf '%s\n' "=> Make sure PATH contains: $(go env GOPATH)/bin/"
	printf '%s\n' "=> Done"
} # }}}

minx_install_ctags() ( # {{{
	local repo_dir="$MINX_REPOS_DIR/ctags"
	local install_dir="$MINX_INSTALLATION_DIR/ctags"

	local commit="${MINX_PINNED_VERSIONS[commit_ctags]}"
	local url="${MINX_PINNED_VERSIONS[url_ctags]}"

	minx_header "L1" "[args: $APP $ACTION] $install_dir"

	if [[ $ACTION == "--build" ]]; then

		minx_assert_is_non_root "$0" || exit 1

		minx_git_clone_at_commit "$repo_dir" "$url" "$commit" || return 1

		cd "$repo_dir" || return 1

		./autogen.sh
		./configure --prefix="$install_dir"
		make -j"$(nproc)"

	else

		minx_assert_is_root "$0" || exit 1

		cd "$repo_dir" || return 1

		git config --global --add safe.directory "$repo_dir"

		minx_safe_rm_dir "$install_dir" || return 1
		mkdir -p "$install_dir"

		make install

		printf '%s\n' "=> Verify"

		local bin_dir
		bin_dir="$install_dir/bin"

		"$bin_dir/ctags" --version
		minx_add_to_PATH "$bin_dir" || return 1
	fi

	printf '%s\n' "=> Done"
) # }}}

minx_install_taskwarrior() ( # {{{
	local repo_dir="$MINX_REPOS_DIR/taskwarrior"
	local build_dir="$repo_dir/_build"
	local install_dir="$MINX_INSTALLATION_DIR/taskwarrior"

	local commit="${MINX_PINNED_VERSIONS[commit_taskwarrior]}"
	local url="${MINX_PINNED_VERSIONS[url_taskwarrior]}"

	# shellcheck disable=SC1091
	source "$HOME/.cargo/env"

	minx_header "L1" "[args: $APP $ACTION] $repo_dir"

	if [[ $ACTION == "--build" ]]; then

		minx_assert_is_non_root "$0" || return 1

		minx_git_clone_at_commit "$repo_dir" "$url" "$commit" || return 1

		cd -- "$repo_dir" || return 1

		git submodule update --init --recursive
		rustup update stable

		rm -rf -- "$build_dir"
		mkdir -p -- "$build_dir"

		cmake -S . -B "$build_dir" \
			-DCMAKE_BUILD_TYPE=Release \
			-DCMAKE_INSTALL_PREFIX="$install_dir"

		cmake --build "$build_dir" --parallel "$(nproc)"

	else

		minx_assert_is_root "$0" || return 1

		cd -- "$build_dir" || return 1

		minx_safe_rm_dir "$install_dir" || return 1
		mkdir -p "$install_dir"

		cmake --install .

		printf '%s\n' "=> Verify"

		local bin_dir
		bin_dir="$install_dir/bin"

		"$bin_dir/task" --version || return 1
		minx_add_to_PATH "$bin_dir" || return 1
	fi

	printf '%s\n' "=> Done"
) # }}}

minx_install_timewarrior() ( # {{{
	local repo_dir="$MINX_REPOS_DIR/timewarrior"
	local build_dir="$repo_dir/_build"
	local install_dir="$MINX_INSTALLATION_DIR/timewarrior"

	local commit="${MINX_PINNED_VERSIONS[commit_timewarrior]}"
	local url="${MINX_PINNED_VERSIONS[url_timewarrior]}"

	minx_header "L1" "[args: $APP $ACTION] $repo_dir"

	if [[ $ACTION == "--build" ]]; then

		minx_assert_is_non_root "$0" || return 1

		minx_git_clone_at_commit "$repo_dir" "$url" "$commit" || return 1

		cd -- "$repo_dir" || return 1

		git submodule update --init --recursive

		printf '%s\n' "=> Building ... "

		mkdir -p -- "$build_dir"

		cmake -S . -B "$build_dir" \
			-DCMAKE_BUILD_TYPE=Release \
			-DCMAKE_INSTALL_PREFIX="$install_dir"

		cmake --build "$build_dir" --parallel "$(nproc)"

	else

		minx_assert_is_root "$0" || return 1

		cd -- "$build_dir" || return 1

		minx_safe_rm_dir "$install_dir" || return 1
		mkdir -p "$install_dir"

		cmake --install .

		printf '%s\n' "=> Verify"

		local bin_dir
		bin_dir="$install_dir/bin"

		"$bin_dir/timew" --version || return 1
		minx_add_to_PATH "$bin_dir" || return 1
	fi

	printf '%s\n' "=> Done"
) # }}}

minx_install_qutebrowser() ( # {{{

	local repo_dir="$MINX_REPOS_DIR/qutebrowser"
	local install_dir="$MINX_INSTALLATION_DIR/qutebrowser/bin"

	local commit="${MINX_PINNED_VERSIONS[commit_qutebrowser]}"
	local url="${MINX_PINNED_VERSIONS[url_qutebrowser]}"

	minx_assert_has_display || return 1

	minx_header "L1" "[args: $APP $ACTION] $repo_dir"

	minx_assert_is_root "$0" || return 1

	git config --global --add safe.directory "$repo_dir"

	minx_git_clone_at_commit "$repo_dir" "$url" "$commit" || return 1

	printf '%s\n' "=> Building ... "

	cd -- "$repo_dir" || return 1

	git config --global --add safe.directory .

	python3 scripts/mkvenv.py || return 1

	printf '%s\n' "=> Installing ... "

	minx_safe_rm_dir "$install_dir" || return 1
	mkdir -p -- "$install_dir" || return 1

	local executable="$install_dir/qutebrowser"
	local python="$repo_dir/.venv/bin/python"
	local script="$repo_dir/qutebrowser.py"

	{
		printf '%s\n' '#!/usr/bin/env bash'
		printf 'exec %q %q "$@"\n' "$python" "$script"
	} >"$executable" || return 1

	chmod +x "$executable" || return 1

	printf '%s\n' "=> Verify ..."

	minx_run "$executable" -h || return 1

	printf '%s\n' "=> Done"
) # }}}

minx_install_vim() ( # {{{
	local repo_dir="$MINX_REPOS_DIR/vim"
	local install_dir="$MINX_INSTALLATION_DIR/vim"

	local commit="${MINX_PINNED_VERSIONS[commit_vim]}"
	local url="${MINX_PINNED_VERSIONS[url_vim]}"

	minx_header "L1" "[args: $APP $ACTION] $repo_dir"

	if [[ $ACTION == "--build" ]]; then

		minx_assert_is_non_root "$0" || exit 1

		minx_git_clone_at_commit "$repo_dir" "$url" "$commit" || return 1

		cd -- "$repo_dir" || return 1

		make distclean || true

		local python_config=""

		minx_command_exists python3 || return 1
		python_config="--enable-python3interp=yes"

		./configure \
			--with-features=huge \
			--enable-multibyte \
			--enable-terminal \
			--enable-gui=no \
			--enable-cscope \
			--enable-fail-if-missing \
			$python_config

		make -j"$(nproc)"

	else

		minx_assert_is_root "$0" || exit 1

		cd "$repo_dir" || return 1

		minx_safe_rm_dir "$install_dir" || return 1
		mkdir -p "$install_dir"

		make DESTDIR="$install_dir" install

		printf '%s\n' "=> Verify"

		local bin_dir
		bin_dir="$install_dir/usr/local/bin"

		"$bin_dir/vim" --version || return 1
		minx_add_to_PATH "$bin_dir" || return 1
	fi

	printf '%s\n' "=> Done"
) # }}}

_minx_install_languagetool() { # {{{

	local lt_src_dir="$MINX_REPOS_DIR/languagetool"
	local ltminx_install_dir="$MINX_INSTALLATION_DIR/languagetool"

	local lt_snapshot="${MINX_PINNED_VERSIONS[snapshot_languagetool]}"
	local lt_zip_file="$lt_src_dir/$lt_snapshot"
	local lt_url="${MINX_PINNED_VERSIONS[url_languagetool]}/$lt_snapshot"

	local ft_repo_dir="$MINX_REPOS_DIR/languagetool/fastText"

	local ft_commit="${MINX_PINNED_VERSIONS[commit_fasttext]}"
	local ft_url="${MINX_PINNED_VERSIONS[url_fasttext]}"

	# The model is fetched and verified by download_repos.sh (remote server).
	local ft_model_file="$MINX_REPOS_DIR/languagetool/lid.176.bin"
	local ft_model_sha256="${MINX_PINNED_VERSIONS[sha256_fasttext_model]:-}"

	local fasttextModel_src="$ft_model_file"
	local fasttextBinary_src="$ft_repo_dir/fasttext"

	minx_header "L1" "[args: $APP $ACTION] languagetool with fasttext"

	# ----------------------------------------------------------------------
	# Build/download
	# ----------------------------------------------------------------------

	if [[ $ACTION == "--build" ]]; then

		minx_assert_is_non_root "$0" || return 1

		mkdir -p -- "$lt_src_dir" || return 1

		# ------------------------------------------------------------------
		# LanguageTool archive
		# ------------------------------------------------------------------

		if minx_path_exists "$lt_zip_file"; then
			printf '%s\n' "=> LanguageTool already downloaded."
		else
			printf '%s\n' "=> Downloading LanguageTool..."
			minx_download_file "$lt_url" "$lt_zip_file" || return 1
		fi

		if [[ ! -f "$lt_zip_file" ]]; then
			printf '%s\n' \
				"=> [FAIL] LanguageTool archive not found: $lt_zip_file" >&2
			return 1
		fi

		# ------------------------------------------------------------------
		# fastText source
		# ------------------------------------------------------------------

		minx_git_clone_at_commit \
			"$ft_repo_dir" \
			"$ft_url" \
			"$ft_commit" || return 1

		# ------------------------------------------------------------------
		# Build fastText
		# ------------------------------------------------------------------

		printf '%s\n' "=> Building fastText..."

		make -C "$ft_repo_dir" clean || return 1
		make -C "$ft_repo_dir" -j"$(nproc)" || return 1

		if [[ ! -x "$fasttextBinary_src" ]]; then
			printf '%s\n' \
				"=> [FAIL] fastText binary not found: $fasttextBinary_src" >&2
			return 1
		fi

		# ------------------------------------------------------------------
		# Language identification model (downloaded by download_repos.sh)
		# ------------------------------------------------------------------

		if [[ ! -f "$ft_model_file" ]]; then
			printf '%s\n' \
				"=> [FAIL] Language identification model not found: $ft_model_file" >&2
			printf '%s\n' \
				"=> Run download_repos.sh first (fetches it from MINX_REMOTE_BINARIES)." >&2
			return 1
		fi

		# Never deletes the file on mismatch, so it can be inspected.
		minx_verify_sha256 "$ft_model_file" "$ft_model_sha256" || return 1

		printf '%s\n' "=> Build complete."

		return 0
	fi

	# ----------------------------------------------------------------------
	# Installation
	# ----------------------------------------------------------------------

	minx_assert_is_root "$0" || return 1

	# ----------------------------------------------------------------------
	# Validate build artifacts
	# ----------------------------------------------------------------------

	if [[ ! -f "$lt_zip_file" ]]; then
		printf '%s\n' \
			"=> [FAIL] LanguageTool archive does not exist: $lt_zip_file" >&2
		return 1
	fi

	if [[ ! -x "$fasttextBinary_src" ]]; then
		printf '%s\n' \
			"=> [FAIL] fastText binary does not exist: $fasttextBinary_src" >&2
		return 1
	fi

	if [[ ! -f "$fasttextModel_src" ]]; then
		printf '%s\n' \
			"=> [FAIL] fastText model does not exist: $fasttextModel_src" >&2
		return 1
	fi

	# The file lives in a user-writable directory and is installed as root:
	# verify it again right before copying it.
	minx_verify_sha256 "$fasttextModel_src" "$ft_model_sha256" || return 1

	# ----------------------------------------------------------------------
	# Prepare installation directory
	# ----------------------------------------------------------------------

	minx_safe_rm_dir "$ltminx_install_dir" || return 1

	mkdir -p -- "$ltminx_install_dir" || {
		printf '%s\n' \
			"=> [FAIL] Failed to create: $ltminx_install_dir" >&2
		return 1
	}

	# ----------------------------------------------------------------------
	# Determine LanguageTool directory inside archive
	# ----------------------------------------------------------------------

	printf '%s\n' "=> Determining LanguageTool directory"

	local archive_listing
	local lt_dir

	archive_listing="$(
		unzip -Z1 "$lt_zip_file" 2>/dev/null
	)" || {
		printf '%s\n' \
			"=> [FAIL] Failed to inspect archive: $lt_zip_file" >&2
		return 1
	}

	lt_dir="$(
		printf '%s\n' "$archive_listing" |
			awk -F/ 'NF > 1 && $1 != "" { print $1; exit }'
	)"

	if [[ -z $lt_dir ]]; then
		printf '%s\n' \
			"=> [FAIL] Could not determine LanguageTool directory from: $lt_zip_file" >&2
		return 1
	fi

	printf '%s\n' "=> LanguageTool directory: $lt_dir"

	# ----------------------------------------------------------------------
	# Extract LanguageTool
	# ----------------------------------------------------------------------

	printf '%s\n' "=> Extracting LanguageTool"

	unzip -q "$lt_zip_file" -d "$ltminx_install_dir" || {
		printf '%s\n' \
			"=> [FAIL] Failed to extract LanguageTool" >&2
		return 1
	}

	local lt_root="$ltminx_install_dir/$lt_dir"

	if [[ ! -d "$lt_root" ]]; then
		printf '%s\n' \
			"=> [FAIL] LanguageTool directory not found: $lt_root" >&2
		return 1
	fi

	printf '%s\n' \
		"=> LanguageTool installed: $lt_root"

	# ----------------------------------------------------------------------
	# Destination paths
	# ----------------------------------------------------------------------
	local fasttextBinary_dst
	local fasttextModel_dst
	fasttextBinary_dst="$lt_root/$(basename -- "$fasttextBinary_src")"
	fasttextModel_dst="$lt_root/$(basename -- "$fasttextModel_src")"

	# ----------------------------------------------------------------------
	# Install fastText binary
	# ----------------------------------------------------------------------

	printf '%s\n' "=> Installing fastText binary"
	printf '%s\n' "=> Source:      $fasttextBinary_src"
	printf '%s\n' "=> Destination: $fasttextBinary_dst"

	cp -- "$fasttextBinary_src" "$fasttextBinary_dst" || {
		printf '%s\n' \
			"=> [FAIL] Failed to install: $fasttextBinary_dst" >&2
		return 1
	}

	chmod 0755 -- "$fasttextBinary_dst" || {
		printf '%s\n' \
			"=> [FAIL] Failed to make executable: $fasttextBinary_dst" >&2
		return 1
	}

	if [[ ! -x "$fasttextBinary_dst" ]]; then
		printf '%s\n' \
			"=> [FAIL] fastText binary was not installed correctly: $fasttextBinary_dst" >&2
		return 1
	fi

	# ----------------------------------------------------------------------
	# Install language identification model
	# ----------------------------------------------------------------------

	printf '%s\n' "=> Installing language identification model"
	printf '%s\n' "=> Source:      $fasttextModel_src"
	printf '%s\n' "=> Destination: $fasttextModel_dst"

	cp -- "$fasttextModel_src" "$fasttextModel_dst" || {
		printf '%s\n' \
			"=> [FAIL] Failed to install: $fasttextModel_dst" >&2
		return 1
	}

	if [[ ! -f "$fasttextModel_dst" ]]; then
		printf '%s\n' \
			"=> [FAIL] Language identification model was not installed correctly: $fasttextModel_dst" >&2
		return 1
	fi

	# ----------------------------------------------------------------------
	# Create server.properties
	# ----------------------------------------------------------------------

	local server_properties="$ltminx_install_dir/server.properties"

	printf '%s\n' "=> Creating server.properties"
	printf '%s\n' "=> Config: $server_properties"

	{
		printf 'fasttextModel=%s\n' "$fasttextModel_dst"
		printf 'fasttextBinary=%s\n' "$fasttextBinary_dst"
	} >"$server_properties" || {
		printf '%s\n' \
			"=> [FAIL] Failed to create: $server_properties" >&2
		return 1
	}

	if [[ ! -s "$server_properties" ]]; then
		printf '%s\n' \
			"=> [FAIL] server.properties is empty: $server_properties" >&2
		return 1
	fi

	# ----------------------------------------------------------------------
	# Final validation
	# ----------------------------------------------------------------------

	printf '%s\n' "=> Validating LanguageTool installation"

	local failed=0

	if [[ ! -f "$lt_root/languagetool-server.jar" ]]; then
		printf '%s\n' \
			"=> [FAIL] LanguageTool server JAR not found: $lt_root/languagetool-server.jar" >&2
		failed=1
	fi

	if [[ ! -x "$fasttextBinary_dst" ]]; then
		printf '%s\n' \
			"=> [FAIL] fastText binary not found: $fasttextBinary_dst" >&2
		failed=1
	fi

	if [[ ! -f "$fasttextModel_dst" ]]; then
		printf '%s\n' \
			"=> [FAIL] Language identification model not found: $fasttextModel_dst" >&2
		failed=1
	fi

	if [[ ! -f "$server_properties" ]]; then
		printf '%s\n' \
			"=> [FAIL] server.properties not found: $server_properties" >&2
		failed=1
	fi

	if ((failed != 0)); then
		return 1
	fi

	# ----------------------------------------------------------------------
	# Summary
	# ----------------------------------------------------------------------

	printf '%s\n' "=> LanguageTool installation complete."
	printf '%s\n' "=> LanguageTool: $lt_root"
	printf '%s\n' "=> Server JAR:   $lt_root/languagetool-server.jar"
	printf '%s\n' "=> fastText:     $fasttextBinary_dst"
	printf '%s\n' "=> Model:        $fasttextModel_dst"
	printf '%s\n' "=> Config:       $server_properties"
	printf '%s\n' "=> Done"

} # }}}

minx_install_pdfjs() ( # {{{

	local repo_dir="$MINX_REPOS_DIR/pdfjs"
	local install_dir="$MINX_INSTALLATION_DIR/pdfjs"

	local commit="${MINX_PINNED_VERSIONS[commit_pdfjs]}"
	local url="${MINX_PINNED_VERSIONS[url_pdfjs]}"

	minx_header "L1" "[args: $APP $ACTION] $install_dir"

	NVM_DIR="$HOME/.nvm"
	[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
	[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

	if [[ $ACTION == "--build" ]]; then

		minx_assert_is_non_root "$0" || exit 1

		minx_git_clone_at_commit "$repo_dir" "$url" "$commit" || return 1

		cd "$repo_dir" || return 1

		printf '%s\n' "=> Building ..."

		npm ci || return 1
		npx gulp generic || return 1

	else

		minx_assert_is_root "$0" || exit 1

		cd "$repo_dir" || return 1

		minx_safe_rm_dir "$install_dir" || return 1
		mkdir -p "$install_dir"

		printf '%s\n' "=> Installing ..."

		rsync -a "$repo_dir/build/generic/" "$install_dir/" || return 1

		mkdir -p /usr/share/pdf.js
		minx_symlink "$install_dir/web" /usr/share/pdf.js/web
		minx_symlink "$install_dir/build" /usr/share/pdf.js/build

		printf '%s\n' "=> Verify"

		[[ -d "$install_dir/web" ]] || return 1
		[[ -d "$install_dir/build" ]] || return 1
		[[ -L /usr/share/pdf.js/web ]] || return 1
		[[ -L /usr/share/pdf.js/build ]] || return 1
	fi

	printf '%s\n' "=> Done"

) # }}}

minx_install_runtime() { # {{{
	minx_header "L1" "[args: $APP $ACTION] $MINX_REPOS_DIR/$APP"

	minx_assert_is_root "$0" || exit 1

	local runtime_dir="$MINX_INSTALLATION_DIR/runtime"
	local profile_file="/etc/profile.d/minx_profile.sh"
	local profile_template="$MINX_INSTALLER_ROOT/install/config/template_minx_profile.sh"
	local version_script="$runtime_dir/system/bin/minx-version"

	# Names without prefix: @@MINX_<name>@@ is replaced by the value of MINX_<name>
	local -a profile_vars=(
		USER_FILES_DIR
		USER_REPOS_DIR
		USER_NOTES_DIR
		USER_REFERENCE_FILE
		USER_CPP_PROJECT_LIST
		REMOTE_SSH_SERVER
		REMOTE_BAREREPOS_DIR
		REMOTE_FILES_DIR
		REMOTE_BINARIES_DIR
		INSTALLATION_DIR
		REPOS_DIR
		PROFILES_DIR
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

	printf '%s\n' "=> Copying 'runtime' ..."

	cp -rf -- "$MINX_INSTALLER_ROOT/runtime" "$runtime_dir" || exit 1

	printf '%s\n' "=> Creating minx-version ..."

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

	printf '%s\n' "=> Installing minx_profile.sh ..."

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

	# Catch typos in the template or a missing entry in profile_vars
	if grep -q '@@[A-Z_]*@@' "$profile_file"; then
		printf '%s\n' "=> ERROR: unresolved placeholder in $profile_file" >&2
		exit 1
	fi

	printf '%s\n' "=> Done"
} # }}}

minx_install_dwm() { # {{{
	minx_header "L1" "[args: $APP $ACTION] $MINX_REPOS_DIR/$APP"

	local install_dir="$MINX_INSTALLATION_DIR/dwm"

	if [[ $ACTION == "--build" ]]; then
		minx_assert_is_non_root "$0" || exit 1

		minx_git_clone_and_patch \
			"$MINX_REPOS_DIR/dwm" \
			"${MINX_PINNED_VERSIONS[url_dwm]}" \
			"${MINX_PINNED_VERSIONS[commit_dwm]}" \
			"$MINX_INSTALLER_PATCHES_DIR/suckless/dwm.diff" ||
			return 1

		printf '%s\n' "=> Building ..."

		DESTDIR="$install_dir" \
			SCRIPTS_DIR="$MINX_INSTALLATION_DIR/runtime/system/bin" \
			"$MINX_REPOS_DIR/dwm/install.sh" --build || return 1

	else
		minx_assert_is_root "$0" || exit 1

		git config --global --add safe.directory "$MINX_REPOS_DIR/dwm"

		printf '%s\n' "=> Installing ..."

		DESTDIR="$install_dir" \
			SCRIPTS_DIR="$MINX_INSTALLATION_DIR/runtime/system/bin" \
			"$MINX_REPOS_DIR/dwm/install.sh" --install || return 1

		printf '%s\n' "=> Verify ..."

		local bin_dir
		bin_dir="$install_dir/usr/local/bin"

		"$bin_dir/dwm" -v
		minx_add_to_PATH "$bin_dir" || return 1
	fi

	printf '%s\n' "=> Done"
} # }}}

minx_install_sent() { # {{{
	minx_header "L1" "[args: $APP $ACTION] $MINX_REPOS_DIR/$APP"

	local install_dir="$MINX_INSTALLATION_DIR/sent"

	if [[ $ACTION == "--build" ]]; then
		minx_assert_is_non_root "$0" || exit 1

		minx_git_clone_and_patch \
			"$MINX_REPOS_DIR/sent" \
			"${MINX_PINNED_VERSIONS[url_sent]}" \
			"${MINX_PINNED_VERSIONS[commit_sent]}" \
			"$MINX_INSTALLER_PATCHES_DIR/suckless/sent.diff" ||
			return 1

		printf '%s\n' "=> Building ..."

		DESTDIR="$install_dir" \
			"$MINX_REPOS_DIR/sent/install.sh" --build || return 1

	else
		minx_assert_is_root "$0" || exit 1

		git config --global --add safe.directory "$MINX_REPOS_DIR/sent"

		printf '%s\n' "=> Installing ..."

		DESTDIR="$install_dir" \
			"$MINX_REPOS_DIR/sent/install.sh" --install || return 1

		printf '%s\n' "=> Verify ..."

		local bin_dir
		bin_dir="$install_dir/usr/local/bin"

		"$bin_dir/sent" -v
		minx_add_to_PATH "$bin_dir" || return 1
	fi

	printf '%s\n' "=> Done"
} # }}}

minx_install_st() { # {{{
	minx_header "L1" "[args: $APP $ACTION] $MINX_REPOS_DIR/$APP"

	local install_dir="$MINX_INSTALLATION_DIR/st"

	if [[ $ACTION == "--build" ]]; then
		minx_assert_is_non_root "$0" || exit 1

		minx_git_clone_and_patch \
			"$MINX_REPOS_DIR/st" \
			"${MINX_PINNED_VERSIONS[url_st]}" \
			"${MINX_PINNED_VERSIONS[commit_st]}" \
			"$MINX_INSTALLER_PATCHES_DIR/suckless/st.diff" ||
			return 1

		printf '%s\n' "=> Building ..."

		DESTDIR="$install_dir" \
			"$MINX_REPOS_DIR/st/install.sh" --build || return 1

	else
		minx_assert_is_root "$0" || exit 1

		git config --global --add safe.directory "$MINX_REPOS_DIR/st"

		printf '%s\n' "=> Installing ..."

		DESTDIR="$install_dir" \
			"$MINX_REPOS_DIR/st/install.sh" --install || return 1

		printf '%s\n' "=> Verify ..."

		local bin_dir
		bin_dir="$install_dir/usr/local/bin"

		"$bin_dir/st" -v
		minx_add_to_PATH "$bin_dir" || return 1
	fi

	printf '%s\n' "=> Done"
} # }}}

minx_install_slock() { # {{{
	minx_header "L1" "[args: $APP $ACTION] $MINX_REPOS_DIR/$APP"

	local install_dir="$MINX_INSTALLATION_DIR/slock"

	if [[ $ACTION == "--build" ]]; then
		minx_assert_is_non_root "$0" || exit 1

		minx_git_clone_and_patch \
			"$MINX_REPOS_DIR/slock" \
			"${MINX_PINNED_VERSIONS[url_slock]}" \
			"${MINX_PINNED_VERSIONS[commit_slock]}" \
			"$MINX_INSTALLER_PATCHES_DIR/suckless/slock.diff" ||
			return 1

		printf '%s\n' "=> Building ..."

		DESTDIR="$install_dir" \
			"$MINX_REPOS_DIR/slock/install.sh" --build || return 1

	else
		minx_assert_is_root "$0" || exit 1

		git config --global --add safe.directory "$MINX_REPOS_DIR/slock"

		printf '%s\n' "=> Installing ..."

		DESTDIR="$install_dir" \
			"$MINX_REPOS_DIR/slock/install.sh" --install || return 1

		printf '%s\n' "=> Verify ..."

		local bin_dir
		bin_dir="$install_dir/usr/local/bin"

		"$bin_dir/slock" -v
		minx_add_to_PATH "$bin_dir" || return 1
	fi

	printf '%s\n' "=> Done"
} # }}}

minx_install_invariant_repos() {

	minx_assert_is_non_root "$0" || return 1

	minx_header "L1" "[args: $APP $ACTION] qb dracula theme"

	minx_git_clone_and_patch \
		"$MINX_REPOS_DIR/qutebrowser_dracula_theme" \
		"${MINX_PINNED_VERSIONS[url_qutebrowser_dracula_theme]}" \
		"${MINX_PINNED_VERSIONS[commit_qutebrowser_dracula_theme]}" \
		"$MINX_INSTALLER_PATCHES_DIR/qutebrowser_dracula_theme.diff" ||
		return 1
	printf '%s\n' "=> Done"

	minx_header "L1" "[args: $APP $ACTION] latex snippets"

	minx_git_clone_and_patch \
		"$MINX_REPOS_DIR/latex_snippets" \
		"${MINX_PINNED_VERSIONS[url_latex_snippets]}" \
		"${MINX_PINNED_VERSIONS[commit_latex_snippets]}" ||
		return 1

	minx_header "L1" "[args: $APP $ACTION] linux a11y sound theme"

	minx_git_clone_and_patch \
		"$MINX_REPOS_DIR/linux_a11y_sound_theme" \
		"${MINX_PINNED_VERSIONS[url_linux_a11y_sound_theme]}" \
		"${MINX_PINNED_VERSIONS[commit_linux_a11y_sound_theme]}" ||
		return 1

	minx_header "L1" "[args: $APP $ACTION] tmpi"

	minx_git_clone_and_patch \
		"$MINX_REPOS_DIR/tmpi" \
		"${MINX_PINNED_VERSIONS[url_tmpi]}" \
		"${MINX_PINNED_VERSIONS[commit_tmpi]}" ||
		return 1

	printf "=> Install ...\n"

	cd "$MINX_REPOS_DIR/tmpi" || return 1

	local -A file_map
	file_map+=(
		# [dst]=src
		["$HOME/.local/bin/tmpi"]="$MINX_REPOS_DIR/tmpi/tmpi"
		["$HOME/.config/qutebrowser/dracula"]="$MINX_REPOS_DIR/qutebrowser_dracula_theme/"
	)

	minx_symlink_map file_map

	printf '%s\n' "=> Done"
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

minx_install_languagetool() { # {{{
	_minx_install_languagetool || return 1
} # }}}

minx_install_onlyoffice() {
	minx_assert_is_root
	minx_assert_has_display

	minx_header "L1" "Onlyoffice"

	printf "=> Installing ..."

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

	grep -qxF \
		'deb [signed-by=/usr/share/keyrings/onlyoffice.gpg] https://download.onlyoffice.com/repo/debian squeeze main' \
		/etc/apt/sources.list.d/onlyoffice.list 2>/dev/null ||
		echo 'deb [signed-by=/usr/share/keyrings/onlyoffice.gpg] https://download.onlyoffice.com/repo/debian squeeze main' |
		sudo tee -a /etc/apt/sources.list.d/onlyoffice.list

	sudo apt-get update
	sudo apt-get install onlyoffice-desktopeditors

	printf '%s\n' "=> Done"
}

minx_install_librewolf() {
	minx_assert_is_root
	minx_assert_has_display

	minx_header "L1" "librewolf"

	printf "=> Installing ..."

	sudo apt update && sudo apt install extrepo -y
	sudo extrepo enable librewolf && sudo extrepo update librewolf
	sudo apt update && sudo apt install librewolf -y

	printf '%s\n' "=> Done"
}

minx_install_spotify() {
	minx_assert_is_root
	minx_assert_has_display

	minx_header "L1" "Spotify"

	printf "=> Installing ..."

	curl -sS \
		https://download.spotify.com/debian/pubkey_5384CE82BA52C83A.asc |
		sudo gpg --dearmor --yes -o /etc/apt/trusted.gpg.d/spotify.gpg

	grep -qxF \
		'deb https://repository.spotify.com stable non-free' \
		/etc/apt/sources.list.d/spotify.list 2>/dev/null ||
		echo 'deb https://repository.spotify.com stable non-free' |
		sudo tee -a /etc/apt/sources.list.d/spotify.list

	sudo apt-get update
	sudo apt-get install spotify-client

	printf '%s\n' "=> Done"
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

	minx_header "L1" "[args: $APP $ACTION] Install Calix $version"

	# Calix installs into the user's ~/.local directory.
	minx_assert_is_non_root "$0" || return 1

	if [[ -x "$bin_dir/calix" ]]; then
		if "$bin_dir/calix" --version 2>/dev/null | grep -q "$version"; then
			printf '%s\n' "=> Calix $version already installed."
			return 0
		fi
	fi

	mkdir -p -- "$download_dir" || return 1

	tmp_dir="$(mktemp -d)" || return 1
	trap 'rm -rf -- "$tmp_dir"' EXIT

	if [[ -f "$dst_file" ]]; then
		printf '=> Using existing archive: %s\n' "$dst_file"
	else
		minx_download_file "$download_url" "$dst_file" || {
			rm -f -- "$dst_file"
			return 1
		}
	fi

	printf '%s\n' "=> Extracting ..."

	tar -xzf "$dst_file" -C "$tmp_dir" || return 1

	local install_dir="$tmp_dir/$archive_dir"

	[[ -x "$install_dir/install.sh" ]] || {
		printf '%s\n' "ERROR: Calix install.sh not found." >&2
		return 1
	}

	printf '%s\n' "=> Installing ..."

	(
		cd "$install_dir"
		./install.sh
	) || return 1

	printf '%s\n' "=> Verifying installation ..."

	[[ -x "$bin_dir/calix" ]] || {
		printf '%s\n' "ERROR: Calix executable not found." >&2
		return 1
	}

	"$bin_dir/calix" --version || return 1

	printf '%s\n' "=> Done"
) # }}}

main() {

	# ACTION case
	case "$ACTION" in
	--build) ;;
	--install) ;;
	*)
		printf '%s\n' "=> Invalid action: $ACTION"
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
		printf '%s\n' "=> Invalid app: $APP"
		return 1
		;;
	esac
}

minx_run_and_log "$LOGFILE" main "$@"
