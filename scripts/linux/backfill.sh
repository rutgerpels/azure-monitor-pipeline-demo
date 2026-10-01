#!/bin/bash
# One local transaction also works when Azure Run Command loses its return path.
set -euo pipefail
run=${1:?Run ID required}
count=${2:?Count required}
endpoint=${3:?DCE endpoint required}
pipeline=${4:?Pipeline name required}
restart=${5:-false}
[[ "$run" =~ ^demo-[a-zA-Z0-9-]+$ && "$count" =~ ^[0-9]+$ ]] || exit 1
(( count <= 3000 )) || { echo 'Backfill is limited to 3000 records to fit the safety timer' >&2; exit 1; }
cd /home/demoadmin/demo
outage=/home/demoadmin/demo/scripts/linux/outage.sh
evidence="$run-backfill.json"
generation=''
cleanup() {
    if [[ -n "$generation" ]]; then bash "$outage" stop "$generation"; fi
}
trap cleanup EXIT
kc() { k3s kubectl "$@"; }
pod=$(kc get pods -n pipeline-demo -l "pipeline=$pipeline" -o json |
    jq -er '[.items[] | select(.status.phase == "Running")] | if length == 1 then .[0].metadata.name else error("Expected one running collector") end')
uid=$(kc get pod "$pod" -n pipeline-demo -o jsonpath='{.metadata.uid}')
pod_json=$(kc get pod "$pod" -n pipeline-demo -o json)
claim=$(jq -er '[.spec.volumes[] | select(.persistentVolumeClaim) | .persistentVolumeClaim.claimName] | if length == 1 then .[0] else error("Expected one persistent volume") end' <<<"$pod_json")
kc get pvc "$claim" -n pipeline-demo -o json |
    jq -e '.status.phase == "Bound" and .spec.volumeName == "pipeline-buffer"' >/dev/null
volume=$(jq -er --arg claim "$claim" '.spec.volumes[] | select(.persistentVolumeClaim.claimName == $claim) | .name' <<<"$pod_json")
jq -e --arg volume "$volume" '[.spec.containers[].volumeMounts[] | select(.name == $volume)] | length > 0' <<<"$pod_json" >/dev/null
sandbox=$(k3s crictl pods --name "^$pod$" -q)
pid=$(k3s crictl inspectp "$sandbox" | jq -er '.info.pid')
host=${endpoint#https://}
host=${host%%/*}
ip=$(getent ahostsv4 "$host" | awk 'NR == 1 {print $1}')
[[ -n "$ip" ]] || { echo 'Cannot resolve DCE' >&2; exit 1; }
probe=(curl --silent --show-error --connect-timeout 3 --max-time 5 --resolve "$host:443:$ip" -o /dev/null "$endpoint")
"${probe[@]}"
nsenter -t "$pid" -n "${probe[@]}"
before=$(find /var/lib/pipeline-buffer -type f -printf '%p %s %T@\n' | sort | sha256sum | cut -d' ' -f1)
generation=$(bash "$outage" start 180)
[[ "$generation" =~ ^[a-f0-9-]{36}$ ]] || { echo 'Invalid outage generation' >&2; exit 1; }
started=$(date -u +%FT%T.%NZ)
for target in host pod; do
    rc=0
    if [[ "$target" == host ]]; then "${probe[@]}" || rc=$?; else nsenter -t "$pid" -n "${probe[@]}" || rc=$?; fi
    [[ "$rc" == 7 ]] || { echo "$target isolation probe returned $rc, expected connection rejection (7)" >&2; exit 1; }
done
python3 -m simulator --host 10.80.0.4 --port 30514 --format syslog --run-id "$run" \
    --count "$count" --rate 100 --manifest "/home/demoadmin/demo/$run.json"
sleep 30
bash "$outage" status "$generation" > "$run-firewall.txt"
after=$(find /var/lib/pipeline-buffer -type f -printf '%p %s %T@\n' | sort | sha256sum | cut -d' ' -f1)
[[ "$before" != "$after" ]] || { echo 'Persistent buffer files did not change during isolation' >&2; exit 1; }
packets=$(nft -j list table inet pipeline_demo | jq '[.. | objects | .counter? | objects | .packets] | add // 0')
(( packets > 0 )) || { echo 'No rejected packets recorded' >&2; exit 1; }
replacement_uid=$uid
if [[ "$restart" == true ]]; then
    kc delete pod "$pod" -n pipeline-demo --wait=true
    for attempt in {1..30}; do
        replacement=$(kc get pods -n pipeline-demo -l "pipeline=$pipeline" -o json)
        replacement_uid=$(jq -r --arg old "$uid" '[.items[] | select(.metadata.uid != $old)] | .[0].metadata.uid // empty' <<<"$replacement")
        if [[ -n "$replacement_uid" ]]; then break; fi
        sleep 1
    done
    [[ -n "$replacement_uid" && "$replacement_uid" != "$uid" ]] || exit 1
    kc wait --for=condition=Ready pod -n pipeline-demo -l "pipeline=$pipeline" --timeout=60s
    jq -e --arg claim "$claim" '[.items[].spec.volumes[] | select(.persistentVolumeClaim.claimName == $claim)] | length > 0' <<<"$replacement" >/dev/null
fi
bash "$outage" status "$generation" >/dev/null
pod=$(kc get pods -n pipeline-demo -l "pipeline=$pipeline" -o jsonpath='{.items[0].metadata.name}')
sandbox=$(k3s crictl pods --name "^$pod$" -q)
pid=$(k3s crictl inspectp "$sandbox" | jq -er '.info.pid')
rc=0
nsenter -t "$pid" -n "${probe[@]}" || rc=$?
[[ "$rc" == 7 ]] || { echo 'Collector regained egress before restoration' >&2; exit 1; }
restored=$(date -u +%FT%T.%NZ)
bash "$outage" stop "$generation"
generation=''
"${probe[@]}"
nsenter -t "$pid" -n "${probe[@]}"
jq -n --arg started "$started" --arg restored "$restored" --arg old "$uid" --arg new "$replacement_uid" \
    --arg claim "$claim" --argjson packets "$packets" --argjson restarted "$restart" \
    '{startedUtc:$started,restoredUtc:$restored,collectorUid:$old,replacementUid:$new,pvc:$claim,rejectedPackets:$packets,restarted:$restarted,persistentFilesChanged:true}' > "$evidence"
cat "$evidence"
