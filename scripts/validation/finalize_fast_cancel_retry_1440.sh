#!/bin/sh
set -eu
umask 077

test "$#" -eq 3 || { echo "usage: $0 evidence after.png checkpoint-tools" >&2; exit 64; }
E=$1; UI=$2; TOOLS=$3
case "$E:$UI:$TOOLS" in /*:/*:/*) ;; *) exit 64;; esac
test -d "$E" && test ! -e "$E/result.txt" || exit 1
test -f "$UI" && test "$(sips -g format "$UI" 2>/dev/null | awk '/format:/{print $2;exit}')" = png || exit 1
test -d "$TOOLS" || exit 1

EXPECTED_BUILD=${EXPECTED_BUILD:-2026081440}
APP_CDHASH=${EXPECTED_APP_CDHASH:-63863012b396e5479b67f6535ccbd468e2da30aa}
PROVIDER_CDHASH=${EXPECTED_TRANSPARENT_CDHASH:-42e1c677d04fd10d961d931c3761f369b05b7ab4}
PROVIDER_SHA=${EXPECTED_TRANSPARENT_SHA:-745445730404758d4d95cbf29b010c57037a35a3f449c963d4a6ad55f156653e}
PROXY_SHA=07127fc2dd861e8f49d521909edcb06e899995b7fb17599e753a150718727293
field() { awk -F= -v k="$1" '$1==k{n++;v=substr($0,index($0,"=")+1)}END{if(n!=1)exit 1;print v}' "$2"; }
sha() { shasum -a 256 "$1" | awk '{print $1}'; }

test "$(field candidate_build "$E/metadata.txt")" = "$EXPECTED_BUILD"
test "$(field scenario "$E/metadata.txt")" = fast-cancel-retry
test "$(field engine "$E/metadata.txt")" = transparent
app_pid=$(pgrep -x AetherRoute | awk 'NF{n++;p=$1}END{if(n==1)print p}')
test "$app_pid" = "$(field app_pid "$E/metadata.txt")"
provider_pid=$(pgrep -x com.aetherroute.desktop.transparent-proxy | awk 'NF{n++;p=$1}END{if(n==1)print p}')
test -n "$provider_pid"

H=$TOOLS/aetherroute_https_gate_probe_1433.sh
S=$TOOLS/aetherroute_stun_udp_probe_1433.sh
if test ! -d "$E/after-checkpoint"; then
  "$TOOLS/capture_transparent_connected_checkpoint_1433.sh" "$E/after-checkpoint" \
    "$EXPECTED_BUILD" "$APP_CDHASH" "$PROVIDER_CDHASH" "$PROVIDER_SHA" \
    "$H" "$(sha "$H")" "$S" "$(sha "$S")" "$PROXY_SHA" pass
else
  test "$(field release_gate "$E/after-checkpoint/result.txt")" = passed
fi
ditto "$UI" "$E/ui-after.png"
started_local=$(field started_local "$E/metadata.txt")
/usr/bin/log show --style compact --start "$started_local" \
  --predicate 'process == "AetherRoute" OR process == "com.aetherroute.desktop.transparent-proxy"' \
  >"$E/runtime-log.txt" 2>&1 || true

connect_requests=$(grep -c 'Calling startProxyWithOptions' "$E/runtime-log.txt" || true)
disconnect_requests=$(grep -c 'Calling stopProxyWithReason' "$E/runtime-log.txt" || true)
ordered=$(awk '
  /Calling startProxyWithOptions/ {if(stage==0)stage=1; else if(stage==2)stage=3}
  /Calling stopProxyWithReason/ {if(stage==1)stage=2}
  END{if(stage==3)print "passed"; else print "failed"}
' "$E/runtime-log.txt")
sample_count=$(( $(wc -l < "$E/samples.tsv") - 1 ))
test "$sample_count" -ge 3
test "$connect_requests" -ge 2
test "$disconnect_requests" -ge 1
test "$ordered" = passed
test "$(sha "$E/ui-before.png")" != "$(sha "$E/ui-after.png")"
for key_file in active-profile.v2.json profile-catalog.v1.json; do
  case "$key_file" in
    active-profile.v2.json) meta_key=active_profile_sha256;;
    profile-catalog.v1.json) meta_key=profile_catalog_sha256;;
  esac
  current="$HOME/Library/Group Containers/group.com.aetherroute.desktop/Library/Application Support/AetherRoute/$key_file"
  test "$(field "$meta_key" "$E/metadata.txt")" = "$(sha "$current")"
done
selection_store_changed=no
selection_file="$HOME/Library/Group Containers/group.com.aetherroute.desktop/Library/Application Support/AetherRoute/proxy-selections.v1.json"
test "$(field proxy_selection_sha256 "$E/metadata.txt")" != "$(sha "$selection_file")" && selection_store_changed=yes
{
  printf 'schema=1\ncompleted_utc=%s\ncandidate_build=%s\nscenario=fast-cancel-retry\nengine=transparent\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$EXPECTED_BUILD"
  printf 'app_pid_stable=yes\nfinal_provider_pid=%s\nconnect_requests=%s\ndisconnect_requests=%s\nordered_intents=%s\n' \
    "$provider_pid" "$connect_requests" "$disconnect_requests" "$ordered"
  printf 'sample_count=%s\nselection_store_rewritten=%s\nnetwork_checkpoint=passed\nresult=passed\n' "$sample_count" "$selection_store_changed"
} >"$E/result.txt"
chmod 400 "$E"/ui-after.png "$E"/runtime-log.txt "$E"/result.txt "$E"/samples.tsv "$E"/watcher.*
(cd "$E" && find . -type f ! -name AGGREGATE-SHA256SUMS -print | LC_ALL=C sort | while IFS= read -r f; do shasum -a 256 "${f#./}"; done >AGGREGATE-SHA256SUMS)
chmod 400 "$E/AGGREGATE-SHA256SUMS"
echo "fast cancel retry evidence finalized: samples=$sample_count"
