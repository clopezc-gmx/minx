#!/usr/bin/env bash
# shellcheck disable=SC1091 # source files
#
# MINX user environment

[[ -n "${__MINX_PROFILE_LOADED:-}" ]] && return
__MINX_PROFILE_LOADED=1

pythonpath_prepend() {
	local dir

	for dir in "$@"; do
		[[ -d "$dir" ]] || continue

		case ":$PYTHONPATH:" in
		*":$dir:"*) ;;
		*) PYTHONPATH="$dir${PYTHONPATH:+:$PYTHONPATH}" ;;
		esac
	done
}

path_prepend() {
	local dir

	for dir in "$@"; do
		[[ -d "$dir" ]] || continue

		case ":$PATH:" in
		*":$dir:"*) ;;
		*) PATH="$dir${PATH:+:$PATH}" ;;
		esac
	done
}

manpath_prepend() {
	local dir

	for dir in "$@"; do
		[[ -d "$dir" ]] || continue

		case ":${MANPATH:-}:" in
		*":$dir:"*) ;;
		*) MANPATH="$dir${MANPATH:+:$MANPATH}" ;;
		esac
	done
}

export MINX_USER_ASSETS_DIR=@@MINX_USER_ASSETS_DIR@@
export MINX_USER_REPOS_DIR=@@MINX_USER_REPOS_DIR@@
export MINX_USER_DOCUMENTS_DIR=@@MINX_USER_DOCUMENTS_DIR@@
export MINX_USER_REFERENCE_FILE=@@MINX_USER_REFERENCE_FILE@@
export MINX_USER_CPP_PROJECT_LIST=@@MINX_USER_CPP_PROJECT_LIST@@

export MINX_REMOTE_SSH_SERVER=@@MINX_REMOTE_SSH_SERVER@@
export MINX_REMOTE_ASSETS_BASEDIR=@@MINX_REMOTE_ASSETS_BASEDIR@@
export MINX_REMOTE_BAREREPOS_DIR=@@MINX_REMOTE_BAREREPOS_DIR@@

export MINX_INSTALLATION_DIR=@@MINX_INSTALLATION_DIR@@
export MINX_REPOS_DIR=@@MINX_REPOS_DIR@@
export MINX_PROFILES_DIR=@@MINX_PROFILES_DIR@@
export MINX_INSTALLATION_TYPE=@@MINX_INSTALLATION_TYPE@@

readonly MINX_USER_ASSETS_DIR
readonly MINX_USER_REPOS_DIR
readonly MINX_USER_DOCUMENTS_DIR
readonly MINX_USER_REFERENCE_FILE
readonly MINX_USER_CPP_PROJECT_LIST
readonly MINX_REMOTE_SSH_SERVER
readonly MINX_REMOTE_ASSETS_BASEDIR
readonly MINX_INSTALLATION_DIR
readonly MINX_REPOS_DIR
readonly MINX_PROFILES_DIR

# go
path_prepend "$MINX_INSTALLATION_DIR/go/bin"

# ctags
path_prepend "$MINX_INSTALLATION_DIR/ctags/bin"

# vim
path_prepend "$MINX_INSTALLATION_DIR/vim/usr/local/bin"
manpath_prepend "$MINX_INSTALLATION_DIR/vim/usr/local/share/man"
export VIMRUNTIME="$MINX_INSTALLATION_DIR/vim/usr/local/share/vim/vim92"

# runtime
path_prepend "$MINX_INSTALLATION_DIR/runtime/system/bin"
path_prepend "$MINX_INSTALLATION_DIR/runtime/user/bin"

# ----------------------------------------------------------------------
# Environment
# ----------------------------------------------------------------------
export PATH
export MANPATH

alias nano=vim
