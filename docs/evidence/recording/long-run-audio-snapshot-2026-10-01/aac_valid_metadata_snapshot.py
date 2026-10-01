#!/usr/bin/env python3
"""Read-only iTunSMPB valid-sample audit for finalized synthetic AAC segments."""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections import defaultdict
from pathlib import Path


FFPROBE_DEFAULT = "/opt/homebrew/bin/ffprobe"


def parse_itunsmpb(value):
    """Return reserved, encoder priming, trailing padding, and valid sample count."""
    fields = value.split()
    if len(fields) < 4 or any(not re.fullmatch(r"[0-9a-fA-F]+", field) for field in fields[:4]):
        raise ValueError("iTunSMPB must begin with four hexadecimal fields")
    return {
        "reserved": int(fields[0], 16),
        "encoderPrimingSamples": int(fields[1], 16),
        "trailingPaddingSamples": int(fields[2], 16),
        "validSampleCount": int(fields[3], 16),
    }


def compare_duration(valid_samples, duration_us, sample_rate):
    expected = duration_us * sample_rate / 1_000_000
    return {"expectedSamplesFromDeclaredDuration": expected,
            "differenceSamples": valid_samples - expected,
            "withinRoundingTolerance": abs(valid_samples - expected) <= 1.0}


def safe_media(root, relative):
    candidate = Path(relative)
    if not relative or candidate.is_absolute() or ".." in candidate.parts:
        raise ValueError(f"unsafe relative media path: {relative!r}")
    root_real = root.resolve(strict=True)
    path = (root_real / candidate).resolve(strict=True)
    try:
        path.relative_to(root_real)
    except ValueError as exc:
        raise ValueError(f"media path escapes root: {relative!r}") from exc
    if not path.is_file():
        raise ValueError(f"media path is not a file: {relative!r}")
    return path


def ffprobe(path, executable, timeout):
    command = [executable, "-v", "error", "-show_entries",
               "format=duration:format_tags:stream=codec_name,sample_rate,channels,duration,duration_ts,time_base",
               "-of", "json", str(path)]
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=timeout, check=False)
    except subprocess.TimeoutExpired as exc:
        raise ValueError(f"ffprobe timed out after {timeout:g}s") from exc
    if result.returncode:
        raise ValueError(f"ffprobe exited {result.returncode}: {result.stderr[-4000:]}")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise ValueError(f"ffprobe returned invalid JSON: {exc}") from exc


def inspect_segment(root, segment, ffprobe_path, timeout):
    row = {"id": segment.get("id"), "sourceID": segment.get("sourceID"),
           "path": segment.get("relativePath"), "declaredDurationMicroseconds": segment.get("durationMicroseconds"),
           "status": "failed", "errors": []}
    try:
        path = safe_media(root, segment.get("relativePath"))
        data = ffprobe(path, ffprobe_path, timeout)
        streams = [stream for stream in data.get("streams", []) if stream.get("codec_name") == "aac"]
        if len(streams) != 1:
            raise ValueError(f"expected exactly one AAC audio stream, found {len(streams)}")
        stream = streams[0]
        sample_rate = int(stream["sample_rate"])
        channels = int(stream["channels"])
        row.update({"actualSampleRate": sample_rate, "actualChannels": channels,
                    "containerDurationSeconds": (data.get("format") or {}).get("duration"),
                    "streamDurationSeconds": stream.get("duration")})
        for field, actual in (("sampleRate", sample_rate), ("channelCount", channels)):
            declared = segment.get(field)
            if declared is not None and int(declared) != actual:
                row["errors"].append(f"manifest {field}={declared} differs from actual {actual}")
        tags = (data.get("format") or {}).get("tags") or {}
        tag = next((value for key, value in tags.items() if key.lower() == "itunsmpb"), None)
        if tag is None:
            raise ValueError("missing iTunSMPB format tag")
        parsed = parse_itunsmpb(str(tag))
        row["iTunSMPB"] = parsed
        duration_us = int(segment["durationMicroseconds"])
        duration_check = compare_duration(parsed["validSampleCount"], duration_us, sample_rate)
        row["durationCheck"] = duration_check
        if not duration_check["withinRoundingTolerance"]:
            row["errors"].append("iTunSMPB valid sample count differs from declared duration by more than one sample")
        row["status"] = "passed" if not row["errors"] else "failed"
    except (OSError, KeyError, TypeError, ValueError) as exc:
        row["errors"].append(str(exc))
    return row


def summarize_sources(rows):
    groups = defaultdict(list)
    for row in rows:
        groups[row.get("sourceID") or "unknown"].append(row)
    result = {}
    for source_id, group in sorted(groups.items()):
        valid = [row for row in group if "iTunSMPB" in row]
        frames = sum(row["iTunSMPB"]["validSampleCount"] for row in valid)
        result[source_id] = {
            "finalizedSegmentCount": len(group),
            "passedCount": sum(row["status"] == "passed" for row in group),
            "failedCount": sum(row["status"] == "failed" for row in group),
            "validSampleCountSum": frames,
            "validSeconds": sum(row["iTunSMPB"]["validSampleCount"] / row["actualSampleRate"]
                                 for row in valid if row.get("actualSampleRate")),
            "finalizedDurationSeconds": sum((row.get("declaredDurationMicroseconds") or 0) for row in group) / 1_000_000,
        }
    return result


def attach_decode_rows(rows, path):
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"cannot read decode audit {path}: {exc}") from exc
    decoded = {row.get("path"): row for row in doc.get("segments", []) if isinstance(row, dict)}
    for row in rows:
        decode_row = decoded.get(row.get("path"))
        if decode_row is None:
            row["decodeAudit"] = "notYetDecoded"
        elif decode_row.get("status") != "passed":
            row["decodeAudit"] = "failed"
        else:
            row["decodeAudit"] = "passed"
            raw = decode_row.get("audioSampleFrames")
            if raw is not None and "iTunSMPB" in row:
                valid = row["iTunSMPB"]["validSampleCount"]
                row["decodeAuditRawPcmFrames"] = raw
                row["rawMinusValidFrames"] = raw - valid
                row["decodeAuditNote"] = "Raw decoded PCM may include AAC priming/trailing padding; this comparison is diagnostic only."


def write_atomic(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(data, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp_name, path)
    finally:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass


def self_test():
    parsed = parse_itunsmpb("00000000 00000840 000001C0 00000000002BF200")
    assert parsed["validSampleCount"] == 2_880_000
    assert parsed["encoderPrimingSamples"] == 2112
    assert parsed["trailingPaddingSamples"] == 448
    try:
        parse_itunsmpb("00000000 00000840 nope 00000000002BF200")
        raise AssertionError("malformed tag accepted")
    except ValueError:
        pass
    try:
        parse_itunsmpb("")
        raise AssertionError("missing tag accepted")
    except ValueError:
        pass
    assert compare_duration(2_880_000, 60_000_000, 48_000)["withinRoundingTolerance"]
    assert not compare_duration(2_879_998, 60_000_000, 48_000)["withinRoundingTolerance"]
    print("parser smoke tests passed: valid, missing, malformed tag and duration mismatch")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("media_root", nargs="?", type=Path)
    parser.add_argument("output_json", nargs="?", type=Path)
    parser.add_argument("--ffprobe", default=FFPROBE_DEFAULT)
    parser.add_argument("--timeout", type=float, default=15.0)
    parser.add_argument("--decode-audit", type=Path, help="optional existing live_decode audit JSON to compare by path")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)
    if args.self_test:
        self_test()
        return 0
    if args.media_root is None or args.output_json is None:
        parser.error("media_root and explicit output_json are required")
    ffprobe_path = shutil.which(args.ffprobe)
    if not ffprobe_path:
        print(f"aac-valid-audit: ffprobe executable not found: {args.ffprobe}", file=sys.stderr)
        return 2
    root = args.media_root.resolve(strict=True)
    output = args.output_json.resolve()
    if output in {(root / "progress.json").resolve(), (root / "report.json").resolve()}:
        parser.error("output_json must not overwrite writer progress.json or report.json")
    try:
        output.relative_to((root / "media").resolve())
        parser.error("output_json must be outside the media directory")
    except ValueError:
        pass
    source = root / "report.json" if (root / "report.json").is_file() else root / "progress.json"
    if not source.is_file():
        print(f"aac-valid-audit: no report.json or progress.json in {root}", file=sys.stderr)
        return 2
    try:
        document = json.loads(source.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"aac-valid-audit: cannot read {source}: {exc}", file=sys.stderr)
        return 2
    if not isinstance(document, dict) or not isinstance(document.get("segments"), list):
        print(f"aac-valid-audit: {source} has no segments array", file=sys.stderr)
        return 2
    segments = [segment for segment in document["segments"]
                if isinstance(segment, dict) and str(segment.get("relativePath", "")).lower().endswith(".m4a")]
    rows = [inspect_segment(root, segment, ffprobe_path, args.timeout) for segment in segments]
    if args.decode_audit:
        try:
            attach_decode_rows(rows, args.decode_audit)
        except ValueError as exc:
            print(f"aac-valid-audit: {exc}", file=sys.stderr)
            return 2
    failures = [row for row in rows if row["status"] != "passed"]
    result = {
        "tool": "ProsioRecordingAACValidMetadataAudit/1",
        "input": source.name,
        "writerReportCompleted": document.get("completed") is True and source.name == "report.json",
        "snapshotIsPartial": source.name != "report.json" or document.get("completed") is not True,
        "claim": "iTunSMPB valid-sample metadata compared with manifest durations; container/stream metadata only, not PCM content decoding",
        "finalizedAacSegmentCount": len(segments),
        "passedCount": len(rows) - len(failures),
        "failedCount": len(failures),
        "writerFailures": document.get("failures") or [],
        "writerWarnings": document.get("warnings") or [],
        "sources": summarize_sources(rows),
        "segments": rows,
    }
    try:
        write_atomic(output, result)
    except OSError as exc:
        print(f"aac-valid-audit: cannot write {output}: {exc}", file=sys.stderr)
        return 2
    print(json.dumps({"output": str(output), "input": source.name, "partial": result["snapshotIsPartial"],
                      "finalizedAacSegmentCount": len(rows), "passedCount": result["passedCount"],
                      "failedCount": result["failedCount"], "sourceCount": len(result["sources"])}, sort_keys=True))
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
