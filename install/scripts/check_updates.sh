#!/usr/bin/env bash
# check_updates.sh - report newer upstream commits/versions for pinned entries.
# Usage: check_updates.sh [file]      (needs: git, curl, jq)

set -uo pipefail

CONF="${1:-../config/pinned_versions.txt}"
TIMEOUT=20
export GIT_TERMINAL_PROMPT=0

if [[ -t 1 ]]; then
	RED=$'\e[31m' GREEN=$'\e[32m' YELLOW=$'\e[33m' DIM=$'\e[2m' RESET=$'\e[0m'
else
	RED='' GREEN='' YELLOW='' DIM='' RESET=''
fi

# Versions without a usable url_<name> entry need their repo given here.
declare -A REPO_OVERRIDE=(
	[shfmt]=https://github.com/mvdan/sh.git
)

declare -A VAL=()
UPDATES=0
ERRORS=0

[[ -r "$CONF" ]] || {
	printf 'Cannot read %s\n' "$CONF" >&2
	exit 1
}

# Parse key=value lines (first '=' splits), ignore comments and blanks.
while IFS='=' read -r key value; do
	[[ "$key" =~ ^[a-z0-9_]+$ ]] || continue
	value="${value%%[[:space:]]*}"
	VAL["$key"]="$value"
done <"$CONF"

# ----------------------------------------------------------------------

report() { # <status> <name> <message>
	local color
	case "$1" in
	OK) color="$GREEN" ;;
	UPDATE)
		color="$YELLOW"
		((UPDATES++))
		;;
	*)
		color="$RED"
		((ERRORS++))
		;;
	esac
	printf '%s%-7s%s %-28s %s\n' "$color" "$1" "$RESET" "$2" "$3"
}

# Newest x.y[.z] tag of a git repo (optional leading v).
latest_tag() { # <repo-url>
	timeout "$TIMEOUT" git ls-remote --tags --refs "$1" 2>/dev/null |
		awk '{sub("refs/tags/", "", $2); print $2}' |
		grep -E '^v?[0-9]+(\.[0-9]+)+$' | sort -V | tail -n1
}

compare_versions() { # <current> <latest> -> OK | UPDATE | AHEAD
	local a="${1#v}" b="${2#v}"
	if [[ "$a" == "$b" ]]; then
		printf 'OK'
	elif [[ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n1)" == "$b" ]]; then
		printf 'UPDATE'
	else
		printf 'AHEAD'
	fi
}

github_compare_url() { # <repo-url> <from> <to>
	if [[ "$1" =~ github\.com/([^/]+)/([^/]+)$ ]]; then
		printf 'https://github.com/%s/%s/compare/%s...%s' \
			"${BASH_REMATCH[1]}" "${BASH_REMATCH[2]%.git}" "$2" "$3"
	fi
}

# ----------------------------------------------------------------------

check_commit() { # <name>
	local name="$1"
	local pinned="${VAL[commit_$name]}"
	local url="${VAL[url_$name]:-}"
	local head tag link

	[[ -n "$url" ]] || {
		report ERROR "$name" "no url_$name entry"
		return
	}

	head="$(timeout "$TIMEOUT" git ls-remote "$url" HEAD 2>/dev/null | cut -f1)"
	[[ -n "$head" ]] || {
		report ERROR "$name" "cannot query $url"
		return
	}

	if [[ "$head" == "$pinned"* ]]; then
		report OK "$name" "$pinned (HEAD)"
		return
	fi

	tag="$(latest_tag "$url")"
	link="$(github_compare_url "$url" "$pinned" "${head:0:9}")"
	report UPDATE "$name" "$pinned -> HEAD ${head:0:9}${tag:+  (latest tag: $tag)}"
	[[ -z "$link" ]] || printf '        %s%s%s\n' "$DIM" "$link" "$RESET"
}

check_version() { # <name>
	local name="$1"
	local current="${VAL[version_$name]}"
	local url="${VAL[url_$name]:-}"
	local latest="" repo="" status extra=""

	case "$name" in
	go)
		latest="$(timeout "$TIMEOUT" curl -fsSL 'https://go.dev/dl/?mode=json' 2>/dev/null |
			jq -r '.[0].version' 2>/dev/null)"
		latest="${latest#go}"
		;;
	nodejs)
		# Stay on the pinned major; also show the newest LTS line.
		local index major="${current%%.*}"
		index="$(timeout "$TIMEOUT" curl -fsSL https://nodejs.org/dist/index.json 2>/dev/null)"
		latest="$(jq -r --arg m "v${major}." \
			'[.[] | select(.version | startswith($m))][0].version // empty' <<<"$index" 2>/dev/null)"
		latest="${latest#v}"
		extra="newest LTS: $(jq -r '[.[] | select(.lts != false)][0] | "\(.version) (\(.lts))"' <<<"$index" 2>/dev/null)"
		;;
	*)
		repo="${REPO_OVERRIDE[$name]:-}"
		if [[ -z "$repo" && "$url" =~ (github\.com|raw\.githubusercontent\.com)/([^/]+)/([^/]+) ]]; then
			repo="https://github.com/${BASH_REMATCH[2]}/${BASH_REMATCH[3]%.git}.git"
		fi
		[[ -n "$repo" ]] || {
			report ERROR "$name" "no repo known (add it to REPO_OVERRIDE)"
			return
		}
		latest="$(latest_tag "$repo")"
		;;
	esac

	[[ -n "$latest" ]] || {
		report ERROR "$name" "could not determine latest version"
		return
	}

	status="$(compare_versions "$current" "$latest")"
	case "$status" in
	OK) report OK "$name" "$current${extra:+  ($extra)}" ;;
	UPDATE) report UPDATE "$name" "$current -> $latest${extra:+  ($extra)}" ;;
	*) report OK "$name" "$current is newer than upstream $latest (pre-release?)" ;;
	esac
}

check_snapshot() { # <name>
	local name="$1"
	local file="${VAL[snapshot_$name]}"
	local url="${VAL[url_$name]:-}"
	local modified

	# Rolling "latest" file: no version to compare, show its date instead.
	modified="$(timeout "$TIMEOUT" curl -fsSI "${url}${file}" 2>/dev/null |
		awk -F': ' 'tolower($1) == "last-modified" {print $2}' | tr -d '\r')"
	if [[ -n "$modified" ]]; then
		report OK "$name" "rolling snapshot, last modified: $modified"
	else
		report ERROR "$name" "cannot query ${url}${file}"
	fi
}

# ----------------------------------------------------------------------

while IFS= read -r key; do
	case "$key" in
	commit_*) check_commit "${key#commit_}" ;;
	version_*) check_version "${key#version_}" ;;
	snapshot_*) check_snapshot "${key#snapshot_}" ;;
	esac
done < <(printf '%s\n' "${!VAL[@]}" | sort)

printf '\n%d update(s) available, %d error(s).\n' "$UPDATES" "$ERRORS"
