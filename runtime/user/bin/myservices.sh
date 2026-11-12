#!/usr/bin/env bash
set -euo pipefail

usage() {
	echo "Usage: $0 {enable|disable|start|stop|restart|status|logs|follow} service"
	exit 1
}

if [[ $# -ne 2 ]]; then
	usage
fi

ACTION="$1"
SERVICE="$2"

case "${ACTION}" in
enable | disable | start | stop | restart | status)
	echo "==> systemctl --user ${ACTION} ${SERVICE}"
	systemctl --user "${ACTION}" "${SERVICE}"
	;;

logs)
	echo "==> journalctl --user -u ${SERVICE}"
	journalctl --user -u "${SERVICE}" --no-pager -n 50
	;;

follow)
	echo "==> journalctl --user -u ${SERVICE} -f"
	journalctl --user -u "${SERVICE}" -f
	;;

*)
	echo "Invalid action: ${ACTION}"
	usage
	;;
esac
