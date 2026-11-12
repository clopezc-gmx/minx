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

minx_assert_is_non_root "$0" || exit 1

LOGFILE="$MINX_LOG_DIR/$(minx_get_script_name)_$(minx_get_date).log"

_download_file() { # {{{
	local url="$1"
	local destination="$2"

	mkdir -p -- "$(dirname -- "$destination")" || return 1

	if [[ -f "$destination" ]]; then
		printf '=> Already downloaded: %s\n' "$destination"
		return 0
	fi

	printf '=> Downloading %s\n' "$url"

	minx_download_file "$url" "$destination" || return 1

	printf '=> Downloaded to: %s\n' "$destination"
} # }}}

_download_repo() { # {{{
	local name="$1"
	local repo_dir="$MINX_REPOS_DIR/$name"
	local url="${MINX_PINNED_VERSIONS[url_$name]}"
	local commit="${MINX_PINNED_VERSIONS[commit_$name]}"

	minx_git_clone_at_commit \
		"$repo_dir" \
		"$url" \
		"$commit" || return 1

	printf '=> Downloaded to: %s\n' "$repo_dir"
} # }}}

_download_languagetool() { # {{{
	local snapshot="${MINX_PINNED_VERSIONS[snapshot_languagetool]}"
	local url="${MINX_PINNED_VERSIONS[url_languagetool]}/$snapshot"
	local destination="$MINX_REPOS_DIR/languagetool/$snapshot"

	_download_file "$url" "$destination" || return 1
} # }}}

_download_fasttext_model() { # {{{
	local destination="$MINX_REPOS_DIR/languagetool/lid.176.bin"
	local sha256="${MINX_PINNED_VERSIONS[sha256_fasttext_model]:-}"
	local remote="$MINX_REMOTE_SSH_SERVER:$MINX_REMOTE_BINARIES_DIR/lid.176.bin"
	local part="$destination.part"

	if [[ -z "$sha256" ]]; then
		printf '=> [FAIL] No sha256 pinned for lid.176.bin\n' >&2
		return 1
	fi

	if [[ ! -f "$destination" ]]; then
		mkdir -p -- "${destination%/*}" || return 1
		rm -f -- "$part"

		printf '=> Fetching %s\n' "$remote"

		if ! rsync -t --partial -- "$remote" "$part"; then
			rm -f -- "$part"
			printf '=> [FAIL] Could not fetch from remote: %s\n' "$remote" >&2
			return 1
		fi

		if ! minx_verify_sha256 "$part" "$sha256"; then
			rm -f -- "$part"
			return 1
		fi

		mv -- "$part" "$destination" || return 1
	fi

	# Also verifies a manually placed file. Never deletes it on mismatch.
	minx_verify_sha256 "$destination" "$sha256"
} # }}}

_download_jetbrains_mono() { # {{{
	local version="${MINX_PINNED_VERSIONS[version_jetbrains_mono]}"
	local archive="JetBrainsMono.zip"
	local url="${MINX_PINNED_VERSIONS[url_jetbrains_mono]}/download/${version}/${archive}"
	local destination="$MINX_REPOS_DIR/downloads/jetbrains-mono/$archive"

	_download_file "$url" "$destination" || return 1
} # }}}

_download_go() { # {{{
	local version="${MINX_PINNED_VERSIONS[version_go]}"
	local archive="go${version}.linux-amd64.tar.gz"
	local url="${MINX_PINNED_VERSIONS[url_go]}$archive"
	local destination="$MINX_REPOS_DIR/downloads/go/$archive"

	_download_file "$url" "$destination" || return 1
} # }}}

_download_nvm() { # {{{
	local version="${MINX_PINNED_VERSIONS[version_nvm]}"
	local url="${MINX_PINNED_VERSIONS[url_nvm]}/$version/install.sh"
	local destination="$MINX_REPOS_DIR/downloads/nvm/$version-install.sh"

	_download_file "$url" "$destination" || return 1
} # }}}

_download_repositories() { # {{{

	_download_repo ctags
	_download_repo dwm
	_download_repo fasttext
	_download_repo latex_snippets
	_download_repo qutebrowser
	_download_repo qutebrowser_dracula_theme
	_download_repo sent
	_download_repo linux_a11y_sound_theme
	_download_repo st
	_download_repo taskwarrior
	_download_repo timewarrior
	_download_repo vim
	_download_repo pdfjs
	_download_repo slock
	_download_repo tmpi
} # }}}

_download_files() { # {{{

	_download_languagetool
	_download_fasttext_model
	_download_jetbrains_mono
	_download_go
	_download_nvm
} # }}}

main() { # {{{

	local job_dir
	job_dir="$(mktemp -d)" || return 1

	local -a jobs=(
		ctags
		dwm
		fasttext
		latex_snippets
		qutebrowser
		qutebrowser_dracula_theme
		sent
		linux_a11y_sound_theme
		st
		taskwarrior
		timewarrior
		vim
		pdfjs
		slock
		tmpi
		languagetool
		fasttext_model
		jetbrains_mono
		go
		nvm
	)

	local -a pids=()
	local job

	printf '%s\n' "=> Starting downloads..."

	for job in "${jobs[@]}"; do
		(
			case "$job" in
			ctags | dwm | fasttext | latex_snippets | qutebrowser | \
				qutebrowser_dracula_theme | sent | linux_a11y_sound_theme | \
				st | taskwarrior | timewarrior | vim | pdfjs | slock | tmpi)
				_download_repo "$job"
				;;

			languagetool)
				_download_languagetool
				;;

			fasttext_model)
				_download_fasttext_model
				;;

			jetbrains_mono)
				_download_jetbrains_mono
				;;

			go)
				_download_go
				;;

			nvm)
				_download_nvm
				;;
			esac
		) >"$job_dir/$job.log" 2>&1 &

		pids+=("$!")
	done

	printf '=> Waiting for %d downloads...\n' "${#jobs[@]}"

	local i
	local status=0

	for i in "${!jobs[@]}"; do
		if ! wait "${pids[$i]}"; then
			status=1
		fi
	done

	printf '%s\n' "=> Downloads finished."
	printf '\n%s\n' "==================== DOWNLOAD STATUS ===================="

	for job in "${jobs[@]}"; do
		if grep -qE '^=> (Error|\[FAIL\])' "$job_dir/$job.log"; then
			printf '\n%s\n' "[$job] FAILED"
		else
			printf '\n%s\n' "[$job] OK"
		fi

		cat "$job_dir/$job.log"
	done

	printf '\n%s\n' "=========================================================="
	printf '%s\n' "=> Repositories: $MINX_REPOS_DIR"
	printf '%s\n' "=> Archives:     $MINX_REPOS_DIR/downloads"

	rm -rf -- "$job_dir"

	return "$status"
} # }}}

minx_run_and_log "$LOGFILE" main "$@"
