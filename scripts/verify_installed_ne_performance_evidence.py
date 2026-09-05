#!/usr/bin/env python3
"""Validate measured installed-NE performance; never borrow isolated-core rates."""
import hashlib
import json
import re
import statistics
import sys
from datetime import datetime
from fractions import Fraction
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ENGINES = ("tun", "transparent")
DIRECTIONS = ("upload", "download")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def digest(value, length=64):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{%d}" % length, value) is not None


def integer(value, minimum=1):
    return type(value) is int and value >= minimum


def keys(value, expected, label):
    require(type(value) is dict and set(value) == set(expected.split()), label + " fields differ from schema")


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON field")
        result[key] = value
    return result


def read_json(path):
    require(path.is_file() and not path.is_symlink(), "missing or symlinked JSON evidence")
    require(path.stat().st_size <= 8 * 1024 * 1024, "JSON evidence exceeds size limit")
    return json.loads(path.read_text(), object_pairs_hook=unique_object,
                      parse_constant=lambda value: (_ for _ in ()).throw(ValueError("nonfinite JSON number")))


def p95(values):
    return sorted(values)[(len(values) * 95 + 99) // 100 - 1]


def verify(evidence, candidate_path):
    require(evidence.is_absolute() and candidate_path.is_absolute(), "paths must be absolute")
    require(evidence.is_dir() and not evidence.is_symlink(), "missing or symlinked installed performance evidence")
    require({p.name for p in evidence.iterdir()} == {"performance.json", "SHA256SUMS"},
            "installed performance directory must contain exactly performance.json and SHA256SUMS")
    checksum = evidence / "SHA256SUMS"
    require(checksum.is_file() and not checksum.is_symlink(), "invalid performance checksum file")
    data = read_json(evidence / "performance.json")
    raw = (evidence / "performance.json").read_text()
    require(not re.search(r"https?://|token=|password=|endpoint=", raw, re.I), "private endpoint data in performance evidence")
    require(re.fullmatch(sha(evidence / "performance.json") + r"  performance\.json\n?", checksum.read_text()) is not None,
            "performance checksum differs or names unexpected files")
    require(type(data) is dict and data.get("collectionStatus") == "complete", "installed performance collection is incomplete")
    keys(data, "schemaVersion collectionStatus surface candidate collectorSources budgetSHA256 machine topology providers samples", "performance")
    require(data["schemaVersion"] == 1 and type(data["schemaVersion"]) is int, "unsupported performance schema")
    require(data["collectionStatus"] == "complete", "installed performance collection is incomplete")
    require(data["surface"] == "installed-network-extension", "performance is not an installed Network Extension measurement")

    manifest = read_json(candidate_path)
    require(manifest.get("schemaVersion") == 1 and manifest.get("releaseStatus") == "notarized-candidate",
            "performance requires the production notarized candidate manifest")
    require(manifest.get("architecture") == "arm64", "candidate is not arm64")
    product = manifest.get("productID")
    require(isinstance(product, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]{2,127}", product), "invalid candidate product ID")
    require(integer(manifest.get("build")) and isinstance(manifest.get("version"), str), "invalid candidate build/version")
    expected_candidate = {
        "dmgSHA256": manifest["dmg"]["sha256"], "manifestSHA256": sha(candidate_path),
        "sourceManifestSHA256": manifest["source"]["manifestSHA256"],
        "productID": product, "version": manifest["version"], "build": manifest["build"],
    }
    require(all(digest(expected_candidate[k]) for k in ("dmgSHA256", "manifestSHA256", "sourceManifestSHA256")), "invalid candidate hashes")
    require(type(data["candidate"]) is dict and integer(data["candidate"].get("build")) and
            data["candidate"] == expected_candidate, "performance candidate binding differs")

    policy_path = ROOT / "Config/InstalledNEPerformanceBudget.json"
    policy = read_json(policy_path)
    keys(policy, "schemaVersion status surface collectorSources pairsPerDirection minimumSampleDurationNanoseconds latencySamplesPerMeasurement minimumThroughputRatioBasisPoints maximumAddedP95LatencyMicroseconds maximumBaselineSpreadBasisPoints calibrationEvidenceSHA256", "budget")
    require(data["budgetSHA256"] == sha(policy_path), "performance budget hash differs")
    require(policy["schemaVersion"] == 1 and policy["surface"] == data["surface"], "unsupported installed performance budget")
    require(policy["status"] == "calibrated", "installed performance budget is pending calibration; production remains blocked")
    require(digest(policy["calibrationEvidenceSHA256"]), "missing reviewed calibration evidence hash")
    require(policy["pairsPerDirection"] == 5 and type(policy["pairsPerDirection"]) is int, "invalid paired sample policy")
    require(policy["minimumSampleDurationNanoseconds"] == 10000000000, "invalid sample duration policy")
    require(policy["latencySamplesPerMeasurement"] == 200, "invalid latency sampling policy")
    for name in ("minimumThroughputRatioBasisPoints", "maximumBaselineSpreadBasisPoints"):
        require(integer(policy[name]) and policy[name] <= 10000, "uncalibrated or invalid " + name)
    require(integer(policy["maximumAddedP95LatencyMicroseconds"], 0), "uncalibrated added latency budget")
    sources = policy["collectorSources"]
    require(isinstance(sources, list) and len(sources) == len(set(sources)) and
            "scripts/collect_installed_ne_performance.sh" in sources, "missing canonical collector source policy")
    require(type(data["collectorSources"]) is dict and set(data["collectorSources"]) == set(sources), "collector source manifest differs")
    for name in sources:
        require(isinstance(name, str) and name.startswith("scripts/") and ".." not in Path(name).parts,
                "invalid collector source path")
        path = ROOT / name
        require(path.is_file() and not path.is_symlink(), "real installed performance collector is missing")
        require(data["collectorSources"][name] == sha(path), "collector source hash differs")

    machine = data["machine"]
    keys(machine, "architecture model macOSBuild hostNameSHA256", "machine")
    require(machine["architecture"] == "arm64" and digest(machine["hostNameSHA256"]), "invalid measurement machine")
    for key in ("model", "macOSBuild"):
        require(isinstance(machine[key], str) and re.fullmatch(r"[A-Za-z0-9,._ -]{1,80}", machine[key]), "invalid machine description")
    topology = data["topology"]
    keys(topology, "kind transport baseline peerIdentitySHA256 internetPath", "topology")
    require(topology["kind"] == "controlled-peer" and topology["transport"] == "tcp" and
            topology["baseline"] == "same-peer-provider-disconnected" and topology["internetPath"] is False and
            digest(topology["peerIdentitySHA256"]), "performance topology does not prove a controlled paired baseline")
    providers = data["providers"]
    keys(providers, "tun transparent", "providers")
    for engine in ENGINES:
        p = providers[engine]
        keys(p, "bundleID version build teamID archivedExecutableSHA256 installedExecutableSHA256 archivedCDHash installedCDHash", "provider")
        suffix = ".tunnel" if engine == "tun" else ".transparent-proxy"
        require(p["bundleID"] == product + suffix and p["version"] == manifest["version"] and
                type(p["build"]) is int and p["build"] == manifest["build"], "provider candidate identity differs")
        require(isinstance(p["teamID"], str) and re.fullmatch(r"[A-Z0-9]{10}", p["teamID"]), "invalid provider signing team")
        require(digest(p["archivedExecutableSHA256"]) and p["archivedExecutableSHA256"] == p["installedExecutableSHA256"], "installed provider executable differs from candidate")
        require(digest(p["archivedCDHash"], 40) and p["archivedCDHash"] == p["installedCDHash"], "installed provider signature differs from candidate")
    require(providers["tun"]["teamID"] == providers["transparent"]["teamID"], "provider signing teams differ")

    samples = data["samples"]
    require(type(samples) is list and len(samples) == 20, "missing engine/direction sample pairs")
    grouped = {(e, d): [] for e in ENGINES for d in DIRECTIONS}
    seen = set()
    intervals = []
    common = "bytesSent bytesReceived sentPayloadSHA256 receivedPayloadSHA256 startedMonotonicNanoseconds endedMonotonicNanoseconds transferDurationNanoseconds latencyNanoseconds providerActive peerIdentitySHA256"
    observed = "providerPID providerStartedAt providerBundleID providerCDHash providerObservedBytesBefore providerObservedBytesAfter counterSource pathAttribution providerFlowObservationSHA256"
    for pair in samples:
        keys(pair, "engine direction pairIndex baseline candidate", "sample pair")
        engine, direction, index = pair["engine"], pair["direction"], pair["pairIndex"]
        require(engine in ENGINES and direction in DIRECTIONS and integer(index, 0) and index < 5, "invalid sample pair identity")
        identity = (engine, direction, index)
        require(identity not in seen, "duplicate sample pair")
        seen.add(identity)
        for role in ("baseline", "candidate"):
            m = pair[role]
            keys(m, common + (" " + observed if role == "candidate" else ""), "measurement")
            require(integer(m["bytesSent"]) and type(m["bytesReceived"]) is int and m["bytesSent"] == m["bytesReceived"], "transferred payload byte counts differ")
            require(digest(m["sentPayloadSHA256"]) and m["sentPayloadSHA256"] == m["receivedPayloadSHA256"], "payload integrity differs")
            require(integer(m["startedMonotonicNanoseconds"]) and integer(m["endedMonotonicNanoseconds"]), "invalid transfer clock samples")
            require(integer(m["transferDurationNanoseconds"]) and
                    m["transferDurationNanoseconds"] >= policy["minimumSampleDurationNanoseconds"], "payload transfer duration is too short or invalid")
            require(m["endedMonotonicNanoseconds"] - m["startedMonotonicNanoseconds"] >= m["transferDurationNanoseconds"], "transfer duration exceeds its observation interval")
            intervals.append((m["startedMonotonicNanoseconds"], m["endedMonotonicNanoseconds"]))
            require(m["providerActive"] is (role == "candidate"), "baseline/candidate provider activation differs")
            require(m["peerIdentitySHA256"] == topology["peerIdentitySHA256"], "baseline/candidate peer differs")
            latency = m["latencyNanoseconds"]
            require(type(latency) is list and len(latency) == 200 and all(integer(n) for n in latency), "invalid measured latency samples")
            if role == "candidate":
                p = providers[engine]
                require(integer(m["providerPID"]) and m["providerBundleID"] == p["bundleID"] and m["providerCDHash"] == p["installedCDHash"], "sample provider identity differs")
                require(isinstance(m["providerStartedAt"], str) and re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", m["providerStartedAt"]), "missing provider process lifetime")
                datetime.strptime(m["providerStartedAt"], "%Y-%m-%dT%H:%M:%SZ")
                require(integer(m["providerObservedBytesBefore"], 0) and integer(m["providerObservedBytesAfter"], 0) and
                        m["providerObservedBytesAfter"] - m["providerObservedBytesBefore"] >= m["bytesReceived"], "provider traffic observation does not cover the sample")
                require(m["counterSource"] == "nettop-process" and m["pathAttribution"] == "provider-flow-observed" and
                        digest(m["providerFlowObservationSHA256"]), "missing actual provider flow attribution")
        require(pair["candidate"]["startedMonotonicNanoseconds"] >= pair["baseline"]["endedMonotonicNanoseconds"], "candidate sample must follow its paired baseline")
        grouped[(engine, direction)].append(pair)

    ordered = sorted(intervals)
    require(all(before[1] <= after[0] for before, after in zip(ordered, ordered[1:])), "duplicate or overlapping transfer sample intervals")

    for (engine, direction), pairs in grouped.items():
        require(len(pairs) == 5, "incomplete engine/direction pairs")
        def rate(m):
            return Fraction(m["bytesReceived"] * 1000000000, m["transferDurationNanoseconds"])
        baselines = [rate(pair["baseline"]) for pair in pairs]
        ratios = [rate(pair["candidate"]) / rate(pair["baseline"]) * 10000 for pair in pairs]
        require((max(baselines) - min(baselines)) / statistics.median(baselines) * 10000 <= policy["maximumBaselineSpreadBasisPoints"], "unstable controlled baseline: " + engine + "/" + direction)
        require(statistics.median(ratios) >= policy["minimumThroughputRatioBasisPoints"], "measured throughput ratio below calibrated budget: " + engine + "/" + direction)
        baseline_latency = [n for p in pairs for n in p["baseline"]["latencyNanoseconds"]]
        candidate_latency = [n for p in pairs for n in p["candidate"]["latencyNanoseconds"]]
        require(max(0, p95(candidate_latency) - p95(baseline_latency)) <= policy["maximumAddedP95LatencyMicroseconds"] * 1000,
                "measured added latency above calibrated budget: " + engine + "/" + direction)
    print("Installed NE performance verified: exact candidate/provider/collector, controlled paired samples and calibrated budgets.")


if __name__ == "__main__":
    try:
        require(len(sys.argv) == 3, "usage: verify_installed_ne_performance_evidence.sh /absolute/evidence /absolute/candidate-manifest")
        verify(Path(sys.argv[1]), Path(sys.argv[2]))
    except (OSError, ValueError, TypeError, KeyError, OverflowError) as error:
        print("Installed NE performance evidence failed: " + str(error), file=sys.stderr)
        sys.exit(1)
