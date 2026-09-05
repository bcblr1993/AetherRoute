#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PRODUCER="$ROOT/scripts/test_isolated_soak.sh"
for requirement in \
  'SOURCE_MANIFEST_BEFORE="$TEMP/source-before.txt"' \
  'printf '\''git_commit=%s\n'\'' "$GIT_COMMIT"' \
  'printf '\''source_manifest_sha256=%s\n'\'' "$SOURCE_MANIFEST_SHA256"' \
  'cmp -s "$SOURCE_MANIFEST_BEFORE" "$SOURCE_MANIFEST_AFTER"' \
  'Git commit changed during the isolated soak'
do
  grep -F "$requirement" "$PRODUCER" >/dev/null || {
    echo "isolated soak producer is missing source-freeze gate: $requirement" >&2
    exit 1
  }
done
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-release-soak.XXXXXX")
trap 'find "$TEMP" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM
EVIDENCE="$TEMP/release evidence"
mkdir "$EVIDENCE"
CURRENT_SOURCE_MANIFEST_SHA256=$("$ROOT/scripts/source_manifest.sh" \
  | awk '$1 == "MANIFEST_SHA256" {print $2}')
CURRENT_GIT_COMMIT=$(git -C "$ROOT" rev-parse HEAD)

hash_of() {
  shasum -a 256 "$1" | awk '{print $1}'
}

write_hashes() {
  shasum -a 256 \
    "$EVIDENCE/metadata.txt" "$EVIDENCE/rounds.tsv" "$EVIDENCE/result.txt" \
    >"$EVIDENCE/SHA256SUMS"
}

write_metadata() {
  packet_hash=$1
  printf '%s\n' \
    'schema=2' \
    'started_utc=2026-08-01T00:00:00Z' \
    'requested_duration_seconds=86400' \
    'packet_cycles_per_round=1000' \
    'flow_udp_probe_datagrams=3' \
    'round_timeout_seconds=600' \
    'flow_rss_budget_bytes=67108864' \
    'packet_rss_budget_bytes=33554432' \
    'fd_growth_budget=4' \
    'machine=arm64' \
    'os=26.5' \
    "git_commit=$CURRENT_GIT_COMMIT" \
    "source_manifest_sha256=$CURRENT_SOURCE_MANIFEST_SHA256" \
    "runner_sha256=$(hash_of "$ROOT/scripts/test_isolated_soak.sh")" \
    "flow_harness_sha256=$(hash_of "$ROOT/Tests/CoreSmoke/flow_core_smoke.c")" \
    "packet_harness_sha256=$(hash_of "$ROOT/Tests/CoreSmoke/packet_tunnel_core_smoke.c")" \
    "flow_artifact_sha256=$(hash_of "$ROOT/Core/Artifacts/macos-arm64/libclashrs.a")" \
    "packet_artifact_sha256=$packet_hash" \
    'diagnostic_report_scan=exact-process-basename' \
    'orphan_process_scan=exact-binary-path' \
    'network_extension=disabled' \
    'system_network_settings=unchanged' >"$EVIDENCE/metadata.txt"
}

# 960 consecutive 90-second pairs provide 86,400 real recorded seconds.
python3 - "$EVIDENCE/rounds.tsv" <<'PY'
from datetime import datetime, timedelta, timezone
from pathlib import Path
import sys
start=datetime(2026, 8, 1, tzinfo=timezone.utc)
lines=["round\tengine\tcompleted_utc\twall_seconds\tcycles\tmax_rss_bytes\tresult_sha256\tfd_growth"]
for index in range(960):
    for engine, offset, wall, cycles, rss, digest, fd in (
        ("flow", 1, 1, 500, 9000000, "a"*64, 2),
        ("packet", 90, 89, 1000, 12000000, "b"*64, 0),
    ):
        ended=(start+timedelta(seconds=index*90+offset)).strftime("%Y-%m-%dT%H:%M:%SZ")
        lines.append(f"{index+1}\t{engine}\t{ended}\t{wall}\t{cycles}\t{rss}\t{digest}\t{fd}")
Path(sys.argv[1]).write_text("\n".join(lines)+"\n")
PY
printf '%s\n' \
  'completed_utc=2026-08-02T00:00:00Z' \
  'actual_duration_seconds=86400' \
  'rounds=960' \
  'flow_lifecycle_cycles=480000' \
  'packet_lifecycle_cycles=960000' \
  'flow_peak_rss_bytes=9000000' \
  'packet_peak_rss_bytes=12000000' \
  'flow_peak_fd_growth=2' \
  'packet_peak_fd_growth=0' \
  'new_diagnostic_reports=0' \
  'orphan_processes=0' \
  'status=passed' >"$EVIDENCE/result.txt"

current_packet_hash=$(hash_of \
  "$ROOT/Core/Artifacts/macos-arm64/libclashrs-direct.a")
write_metadata "$current_packet_hash"
write_hashes
"$ROOT/scripts/verify_release_soak_evidence.sh" "$EVIDENCE" >/dev/null
cp "$EVIDENCE/metadata.txt" "$TEMP/valid-metadata.txt"
cp "$EVIDENCE/rounds.tsv" "$TEMP/continuity-rounds.tsv"
cp "$EVIDENCE/result.txt" "$TEMP/continuity-result.txt"
# Execute the actual production verifier against independent timing mutations.
# Synthetic fixtures are removed by this test and never serve as release evidence.
python3 - "$ROOT" "$EVIDENCE" <<'PY'
from datetime import datetime, timedelta, timezone
import hashlib
from pathlib import Path
import subprocess
import sys
root, evidence=map(Path, sys.argv[1:])
original={name:(evidence/name).read_text() for name in ("metadata.txt", "rounds.tsv", "result.txt")}
base_rows=[line.split("\t") for line in original["rounds.tsv"].splitlines()]
def date(value):
    return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
def shift(value, seconds):
    return (date(value)+timedelta(seconds=seconds)).strftime("%Y-%m-%dT%H:%M:%SZ")
def move_ends(rows, first, seconds):
    for row in rows[first:]: row[2]=shift(row[2], seconds)
def field(text, key, value):
    return "\n".join(key+"="+str(value) if line.startswith(key+"=") else line for line in text.splitlines())+"\n"
def check(name, mutate, expected, reason=None):
    rows=[list(row) for row in base_rows]
    metadata, result=original["metadata.txt"], original["result.txt"]
    metadata, result=mutate(rows, metadata, result)
    values={"metadata.txt":metadata, "result.txt":result, "rounds.tsv":"\n".join("\t".join(row) for row in rows)+"\n"}
    hashes=[]
    for path, value in values.items():
        (evidence/path).write_text(value)
        hashes.append(hashlib.sha256(value.encode()).hexdigest()+"  "+path)
    (evidence/"SHA256SUMS").write_text("\n".join(hashes)+"\n")
    command=subprocess.run([str(root/"scripts/verify_release_soak_evidence.sh"),str(evidence)],text=True,capture_output=True)
    assert (command.returncode == 0) == expected, (name,command.stdout,command.stderr)
    if reason: assert reason in command.stderr, (name,command.stderr)
    print("Soak continuity control: "+name+" passed",flush=True)
def duration(result, delta):
    result=field(result,"completed_utc",shift("2026-08-02T00:00:00Z",delta))
    return field(result,"actual_duration_seconds",86400+delta)
def sparse(rows, metadata, result):
    for index,row in enumerate(rows[1:]):
        row[3]="1" if row[1]=="flow" else "2"
        row[2]="2026-08-01T00:01:00Z" if index<2 else "2026-08-02T00:00:00Z" if index>=1918 else "2026-08-01T12:00:00Z"
    return metadata,result
def short_active(rows, metadata, result):
    for row in rows[1:]:
        if row[1]=="packet": row[3]="88"
    return metadata,result
def internal_gap(rows, metadata, result, seconds):
    move_ends(rows,1001,seconds)
    return metadata,duration(result,seconds)
def overlap(rows, metadata, result):
    rows[1002][2]=shift(rows[1002][2],-1)
    return metadata,result
def same_end(rows, metadata, result):
    rows[1002][2]=rows[1001][2]
    return metadata,result
def wrong_order(rows, metadata, result):
    rows[1],rows[2]=rows[2],rows[1]
    return metadata,result
def initial_gap(rows, metadata, result):
    move_ends(rows,1,2)
    return metadata,duration(result,2)
def invalid_utc(rows, metadata, result):
    rows[1000][2]="2026-02-30T12:00:00Z"
    return metadata,result
check("sparse-24h-timestamps",sparse,False,"soak continuity:")
check("one-second-gaps-cannot-replace-24h-work",short_active,False,"accumulated effective runtime")
check("two-second-internal-gap",lambda *values:internal_gap(*values,2),False,"uncovered gap")
check("one-second-recording-gap",lambda *values:internal_gap(*values,1),True)
check("overlapping-intervals",overlap,False,"intervals overlap")
check("reused-positive-duration-endpoint",same_end,False,"intervals overlap")
check("wrong-execution-order",wrong_order,False,"execution order")
check("uncovered-start-boundary",initial_gap,False,"uncovered gap")
check("uncovered-end-boundary",lambda rows,meta,result:(meta,duration(result,2)),False,"completion boundary")
check("utc-duration-disagreement",lambda rows,meta,result:(meta,field(result,"actual_duration_seconds",86401)),False,"UTC timestamps")
check("invalid-calendar-date",invalid_utc,False,"invalid completed UTC")
for name,value in original.items(): (evidence/name).write_text(value)
PY
write_hashes

sed -i '' \
  's/^source_manifest_sha256=.*/source_manifest_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/' \
  "$EVIDENCE/metadata.txt"
write_hashes
if "$ROOT/scripts/verify_release_soak_evidence.sh" "$EVIDENCE" \
  >/dev/null 2>&1; then
  echo "release soak verifier accepted a stale source manifest" >&2
  exit 1
fi

cp "$TEMP/valid-metadata.txt" "$EVIDENCE/metadata.txt"
sed -i '' \
  's/^git_commit=.*/git_commit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/' \
  "$EVIDENCE/metadata.txt"
write_hashes
if "$ROOT/scripts/verify_release_soak_evidence.sh" "$EVIDENCE" \
  >/dev/null 2>&1; then
  echo "release soak verifier accepted a stale Git commit" >&2
  exit 1
fi

cp "$TEMP/valid-metadata.txt" "$EVIDENCE/metadata.txt"
write_hashes

cp "$EVIDENCE/rounds.tsv" "$TEMP/valid-rounds.tsv"
cp "$EVIDENCE/result.txt" "$TEMP/valid-result.txt"
awk -F '\t' 'NR == 1 || $1 <= 799' "$EVIDENCE/rounds.tsv" >"$EVIDENCE/rounds.short"
mv "$EVIDENCE/rounds.short" "$EVIDENCE/rounds.tsv"
sed -e 's/^rounds=960$/rounds=799/' \
  -e 's/^flow_lifecycle_cycles=480000$/flow_lifecycle_cycles=399500/' \
  -e 's/^packet_lifecycle_cycles=960000$/packet_lifecycle_cycles=799000/' \
  "$EVIDENCE/result.txt" >"$EVIDENCE/result.short"
mv "$EVIDENCE/result.short" "$EVIDENCE/result.txt"
write_hashes
if "$ROOT/scripts/verify_release_soak_evidence.sh" "$EVIDENCE" \
  >/dev/null 2>&1; then
  echo "release soak verifier accepted fewer than 800 rounds" >&2
  exit 1
fi

cp "$TEMP/valid-rounds.tsv" "$EVIDENCE/rounds.tsv"
cp "$TEMP/valid-result.txt" "$EVIDENCE/result.txt"
sed -i '' \
  's/^completed_utc=2026-08-02T00:00:00Z$/completed_utc=2026-08-02T00:00:10Z/' \
  "$EVIDENCE/result.txt"
write_hashes
if "$ROOT/scripts/verify_release_soak_evidence.sh" "$EVIDENCE" \
  >/dev/null 2>&1; then
  echo "release soak verifier accepted inconsistent UTC boundaries" >&2
  exit 1
fi

cp "$TEMP/valid-result.txt" "$EVIDENCE/result.txt"
sed -i '' 's/^new_diagnostic_reports=0$/new_diagnostic_reports=1/' \
  "$EVIDENCE/result.txt"
write_metadata "$current_packet_hash"
write_hashes
if "$ROOT/scripts/verify_release_soak_evidence.sh" "$EVIDENCE" \
  >/dev/null 2>&1; then
  echo "release soak verifier accepted a crash diagnostic report" >&2
  exit 1
fi

cp "$TEMP/valid-result.txt" "$EVIDENCE/result.txt"
write_metadata aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
write_hashes
if "$ROOT/scripts/verify_release_soak_evidence.sh" "$EVIDENCE" \
  >/dev/null 2>&1; then
  echo "release soak verifier accepted a stale PacketFlow artifact" >&2
  exit 1
fi

write_metadata "$current_packet_hash"
sed -i '' 's/^fd_growth_budget=4$/fd_growth_budget=5/' \
  "$EVIDENCE/metadata.txt"
write_hashes
if "$ROOT/scripts/verify_release_soak_evidence.sh" "$EVIDENCE" \
  >/dev/null 2>&1; then
  echo "release soak verifier accepted a weakened FD budget" >&2
  exit 1
fi

python3 - "$ROOT/scripts/test_isolated_soak.sh" <<'PY'
"""Controlled runner clock/command fixtures only; no real core, VM or network."""
from datetime import datetime, timezone
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

producer=Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="aether-soak-timing-controls-") as temporary:
    base=Path(temporary)
    (base/"scripts").mkdir()
    (base/"bin").mkdir()
    artifact=base/"Core/Artifacts/macos-arm64"
    artifact.mkdir(parents=True)
    for name in ("libclashrs.a","libclashrs-direct.a"):
        (artifact/name).write_text("controlled fixture; not a production archive\n")
    (base/"clock").write_text("1700000000")
    shutil.copy2(producer,base/"scripts/test_isolated_soak.sh")
    def write(path, source):
        path.write_text(source)
        path.chmod(0o755)
    python=sys.executable
    shim_head="#!"+python+"\n"
    clock_code="from pathlib import Path\nimport os, sys\nclock=Path(os.environ['SOAK_FIXTURE_CLOCK'])\n"
    write(base/"bin/date",shim_head+clock_code+"if sys.argv[1:] == ['+%s']: print(clock.read_text().strip())\nelse: os.execv('/bin/date',['/bin/date']+sys.argv[1:])\n")
    write(base/"bin/git","#!/bin/sh\nprintf '%s\\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n")
    write(base/"bin/file","#!/bin/sh\nprintf '%s\\n' 'controlled fixture: Mach-O 64-bit executable arm64'\n")
    write(base/"bin/caffeinate","#!/bin/sh\nexec /bin/sleep 600\n")
    write(base/"bin/shasum",shim_head+clock_code+"if any(Path(value).name in ('latest-flow.log','latest-packet.log') for value in sys.argv[1:]):\n    clock.write_text(str(int(clock.read_text())+int(os.environ['SOAK_FIXTURE_RECORD_GAP'])))\nos.execv('/usr/bin/shasum',['/usr/bin/shasum']+sys.argv[1:])\n")
    write(base/"scripts/source_manifest.sh",shim_head+clock_code+"clock.write_text(str(int(clock.read_text())+600))\nprint('MANIFEST_SHA256  '+'b'*64)\n")
    harness=shim_head+clock_code+"flow=Path(sys.argv[0]).name == 'flow-core-smoke'\nclock.write_text(str(int(clock.read_text())+(2 if flow else 3)))\nprint('flow_cycles=500 fd_growth=0' if flow else 'packet_cycles=1000 fd_growth=0')\n"
    write(base/"bin/clang",shim_head+"from pathlib import Path\nimport sys\np=Path(sys.argv[sys.argv.index('-o')+1])\np.write_text("+repr(harness)+")\np.chmod(0o755)\n")
    environment={**os.environ,"PATH":str(base/"bin")+os.pathsep+os.environ["PATH"],
                 "SOAK_FIXTURE_CLOCK":str(base/"clock"),"SOAK_FIXTURE_RECORD_GAP":"1",
                 "AETHERROUTE_ALLOW_ISOLATED_SOAK":"YES","AETHERROUTE_SOAK_DURATION_SECONDS":"60",
                 "AETHERROUTE_SOAK_PACKET_CYCLES":"1000","AETHERROUTE_SOAK_ROUND_TIMEOUT_SECONDS":"30"}
    def fields(path):
        return dict(line.split("=",1) for line in path.read_text().splitlines())
    def epoch(value):
        return int(datetime.strptime(value,"%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp())
    output=base/"valid"
    command=subprocess.run(["/bin/sh",str(base/"scripts/test_isolated_soak.sh"),str(output)],env=environment,text=True,capture_output=True,timeout=90)
    assert command.returncode == 0,(command.stdout,command.stderr)
    metadata,result=fields(output/"metadata.txt"),fields(output/"result.txt")
    rows=[line.split("\t") for line in (output/"rounds.tsv").read_text().splitlines()[1:]]
    active=sum(int(row[3]) for row in rows)
    assert active == 60,(active,rows)
    assert len(rows) == 24,(len(rows),rows)
    start,end=epoch(metadata["started_utc"]),epoch(result["completed_utc"])
    assert int(result["actual_duration_seconds"]) == end-start == 83,(metadata,result)
    previous=start
    for index,row in enumerate(rows):
        ended=epoch(row[2]);began=ended-int(row[3])
        assert began-previous == (0 if index == 0 else 1),(index,row,previous)
        previous=ended
    assert end == previous
    # Source-after advances the controlled wall clock by 600 seconds but may
    # neither create credited runtime nor move the already recorded endpoints.
    assert int((base/"clock").read_text())-end == 601
    print("Runner timing control: 60 effective seconds + 23 recording seconds; 600-second final source check excluded.",flush=True)
    environment["SOAK_FIXTURE_RECORD_GAP"]="2"
    invalid=base/"invalid-gap"
    command=subprocess.run(["/bin/sh",str(base/"scripts/test_isolated_soak.sh"),str(invalid)],env=environment,text=True,capture_output=True,timeout=20)
    assert command.returncode != 0
    assert not (invalid/"result.txt").exists()
    failures=list(invalid.glob("failure-*.log"))
    assert any("Uncovered interval" in path.read_text() for path in failures),failures
    print("Runner timing control: two-second inter-round gap rejected before another harness runs.",flush=True)
PY

echo "Exact release soak evidence verifier tests passed."
