#!/bin/bash
# Isolate cloud-bound traffic without blocking site traffic or SSH replies.
set -euo pipefail
action=${1:?Use start, stop, or status}
duration=${2:-90}
state=/run/pipeline-demo-outage
exec 9>/run/pipeline-demo-outage.lock
flock -x 9
case "$action" in
    start)
        [[ "$duration" =~ ^[0-9]+$ ]] && (( duration >= 30 && duration <= 180 )) || {
            echo 'Duration must be 30..180 seconds' >&2; exit 1;
        }
        if nft list table inet pipeline_demo >/dev/null 2>&1; then
            echo 'Outage already active; stop it before starting another' >&2
            exit 1
        fi
        generation=$(cat /proc/sys/kernel/random/uuid)
        printf '%s\n' "$generation" > "$state"
        # A stale timer cannot restore a later outage; both operations hold the lock.
        systemd-run --unit="pipeline-demo-restore-$generation" --on-active="${duration}s" \
            /bin/bash /home/demoadmin/demo/scripts/linux/outage.sh stop "$generation"
        nft -f - <<'RULES'
table inet pipeline_demo {
    chain isolate {
        ip daddr { 127.0.0.0/8, 10.80.0.0/24, 10.42.0.0/16, 10.43.0.0/16 } return
        tcp sport 22 return
        counter reject
    }
    chain output {
        type filter hook output priority -10; policy accept;
        jump isolate
    }
    chain forward {
        type filter hook forward priority -10; policy accept;
        jump isolate
    }
}
RULES
        echo "$generation"
        ;;
    stop)
        if [[ -n "${2:-}" ]] && { [[ ! -f "$state" ]] || [[ "$(cat "$state")" != "$2" ]]; }; then
            echo 'Ignoring stale outage recovery'
            exit 0
        fi
        if nft list table inet pipeline_demo >/dev/null 2>&1; then
            nft delete table inet pipeline_demo
        fi
        if [[ -f "$state" ]]; then
            generation=$(cat "$state")
            systemctl stop "pipeline-demo-restore-$generation.timer"
            rm -f "$state"
        fi
        echo 'Demo outage rules removed'
        ;;
    status)
        [[ -f "$state" ]] || { echo 'No active outage' >&2; exit 1; }
        if [[ -n "${2:-}" && "$(cat "$state")" != "$2" ]]; then
            echo 'Outage generation changed' >&2; exit 1
        fi
        nft list table inet pipeline_demo
        ;;
    *) echo 'Use start, stop, or status' >&2; exit 1 ;;
esac
