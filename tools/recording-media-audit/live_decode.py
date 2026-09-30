#!/usr/bin/env python3
"""Incrementally decode finalized synthetic stress media with ffmpeg."""

from __future__ import annotations

import argparse
import json
import os
import selectors
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path


class AuditError(Exception):
    pass


def safe_media(root: Path, relative: str) -> Path:
    candidate = Path(relative)
    if not relative or candidate.is_absolute() or any(part == ".." for part in candidate.parts):
        raise AuditError(f"unsafe media path: {relative!r}")
    root_real = root.resolve(strict=True)
    path = (root_real / candidate).resolve(strict=True)
    try:
        path.relative_to(root_real)
    except ValueError as exc:
        raise AuditError(f"media path escapes root: {relative!r}") from exc
    if not path.is_file():
        raise AuditError(f"media path is not a regular file: {relative!r}")
    return path


def input_document(root: Path) -> tuple[dict, str]:
    report = root / "report.json"
    progress = root / "progress.json"
    source = report if report.is_file() else progress
    if not source.is_file():
        raise AuditError(f"neither {report} nor {progress} exists")
    try:
        doc = json.loads(source.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise AuditError(f"cannot read {source}: {exc}") from exc
    if not isinstance(doc, dict) or not isinstance(doc.get("segments"), list):
        raise AuditError(f"{source} does not contain a segments array")
    return doc, source.name


def media_kind(segment: dict) -> str:
    if segment.get("width") is not None or segment.get("height") is not None:
        return "video"
    source_id = str(segment.get("sourceID", "")).lower()
    suffix = Path(str(segment.get("relativePath", ""))).suffix.lower()
    return "audio" if source_id in {"microphone", "systemaudio", "system-audio"} or suffix in {".m4a", ".aac", ".wav", ".caf"} else "video"


def run_decode(ffmpeg: str, path: Path, segment: dict, timeout: float) -> dict:
    kind = media_kind(segment)
    common = [ffmpeg, "-hide_banner", "-nostdin", "-v", "error", "-xerror", "-threads", "2", "-i", str(path)]
    if kind == "audio":
        command = common + ["-map", "0:a:0", "-vn", "-acodec", "pcm_s16le", "-f", "s16le", "-"]
    else:
        command = common + ["-map", "0:v:0", "-an", "-fps_mode", "passthrough", "-progress", "pipe:1", "-nostats", "-f", "null", "-"]
    started = time.monotonic()
    with tempfile.TemporaryFile() as errors:
        try:
            proc = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=errors, bufsize=0)
        except FileNotFoundError as exc:
            raise AuditError(f"ffmpeg executable not found: {ffmpeg}") from exc
        byte_count = 0
        frames = 0
        pending = b""
        timed_out = False
        progress_error = None
        try:
            assert proc.stdout is not None
            with selectors.DefaultSelector() as selector:
                selector.register(proc.stdout, selectors.EVENT_READ)
                while True:
                    remaining = timeout - (time.monotonic() - started)
                    if remaining <= 0:
                        timed_out = True
                        break
                    events = selector.select(min(remaining, 0.25))
                    if not events:
                        if proc.poll() is not None:
                            break
                        continue
                    block = os.read(proc.stdout.fileno(), 65536)
                    if not block:
                        break
                    if kind == "audio":
                        byte_count += len(block)
                    else:
                        pending += block
                        while b"\n" in pending:
                            line, pending = pending.split(b"\n", 1)
                            if len(line) > 16384:
                                progress_error = "ffmpeg progress output exceeded the 16 KiB line limit"
                                break
                            if line.startswith(b"frame="):
                                try:
                                    frames = max(frames, int(line.partition(b"=")[2].strip()))
                                except ValueError:
                                    pass
                        if progress_error:
                            break
                        if len(pending) > 16384:
                            progress_error = "ffmpeg progress output exceeded the 16 KiB line limit"
                            break
                    if progress_error:
                        break
                if not timed_out and pending.startswith(b"frame="):
                    try:
                        frames = max(frames, int(pending.partition(b"=")[2].strip()))
                    except ValueError:
                        pass
            if timed_out or progress_error:
                proc.terminate()
                try:
                    proc.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
            else:
                remaining = max(0.0, timeout - (time.monotonic() - started))
                try:
                    proc.wait(timeout=remaining)
                except subprocess.TimeoutExpired:
                    timed_out = True
                    proc.terminate()
                    try:
                        proc.wait(timeout=1)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        proc.wait()
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()
            proc.stdout.close()
        errors.seek(0, os.SEEK_END)
        error_size = errors.tell()
        errors.seek(max(0, error_size - 65536))
        stderr = errors.read().decode("utf-8", "replace")
    code = proc.returncode
    row = {"kind": kind, "exitCode": code, "stderr": stderr, "seconds": round(time.monotonic() - started, 3)}
    if timed_out:
        row["error"] = f"ffmpeg exceeded per-file timeout of {timeout:g}s"
    elif progress_error:
        row["error"] = progress_error
    elif code != 0:
        row["error"] = f"ffmpeg exited with status {code}"
    elif stderr.strip():
        row["error"] = "ffmpeg reported error-level diagnostics despite a zero exit status"
    elif kind == "video":
        row["videoFrames"] = frames
        if frames <= 0:
            row["error"] = "ffmpeg completed without decoding video frames"
    else:
        try:
            channels = int(segment.get("channelCount") or 2)
        except (TypeError, ValueError):
            channels = 0
        if channels <= 0:
            row["error"] = "audio channel count is missing or invalid"
            return row
        row["audioSampleFrames"] = byte_count // (int(channels) * 2)
        row["audioChannelsForCount"] = channels
        row["audioCountNote"] = "Decoded PCM frame count includes codec padding such as AAC priming/trailing samples; it is not a valid-content sample count."
        if byte_count % (int(channels) * 2):
            row["error"] = "ffmpeg emitted a partial PCM sample frame"
        elif row["audioSampleFrames"] <= 0:
            row["error"] = "ffmpeg completed without decoded audio samples"
    return row


def writer_drop_counts(doc: dict) -> dict:
    result = {}
    snapshots = doc.get("snapshots") or []
    stats = snapshots[-1].get("statistics", {}) if snapshots and isinstance(snapshots[-1], dict) else {}
    for name in ("droppedAdmissionEvents", "droppedEncoderSamples", "droppedCaptureFrames"):
        if name in stats:
            result[name] = stats[name]
    result["fixtureSkippedFrames"] = doc.get("fixtureSkippedFrames", 0)
    return result


def write_atomic(path: Path, result: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    data = json.dumps(result, indent=2, sort_keys=True) + "\n"
    fd, name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        try:
            os.unlink(name)
        except FileNotFoundError:
            pass


def audit_once(root: Path, output: Path, ffmpeg: str, timeout: float, cache: dict) -> tuple[dict, bool]:
    doc, input_name = input_document(root)
    if output.resolve() in {(root / "report.json").resolve(), (root / "progress.json").resolve()}:
        raise AuditError("output must not overwrite writer progress.json or report.json")
    segments = doc["segments"]
    media_dir = (root / "media").resolve()
    try:
        output.resolve().relative_to(media_dir)
        raise AuditError("output must not be written inside the media directory")
    except ValueError:
        pass
    for segment in segments:
        if isinstance(segment, dict) and isinstance(segment.get("relativePath"), str):
            try:
                if output.resolve() == (root.resolve() / segment["relativePath"]).resolve():
                    raise AuditError("output must not overwrite a source media file")
            except OSError:
                continue
    rows = []
    active_identities = set()
    for segment in segments:
        if not isinstance(segment, dict) or not isinstance(segment.get("relativePath"), str):
            rows.append({"segment": segment, "status": "failed", "error": "invalid segment record or missing relativePath"})
            continue
        try:
            path = safe_media(root, segment["relativePath"])
            stat = path.stat()
            segment_identity = json.dumps(segment, sort_keys=True, separators=(",", ":"))
            identity = (str(path), segment_identity, stat.st_size, stat.st_mtime_ns)
            active_identities.add(identity)
            if identity in cache:
                decoded = cache[identity]
            else:
                decoded = run_decode(ffmpeg, path, segment, timeout)
                if not decoded.get("error"):
                    cache[identity] = decoded
            rows.append({"id": segment.get("id"), "sourceID": segment.get("sourceID"), "path": segment["relativePath"],
                         "sizeBytes": stat.st_size, "mtimeNs": stat.st_mtime_ns,
                         "status": "passed" if not decoded.get("error") else "failed", **decoded})
        except (AuditError, OSError, ValueError) as exc:
            rows.append({"id": segment.get("id"), "sourceID": segment.get("sourceID"), "path": segment["relativePath"], "status": "failed", "error": str(exc)})
    # Drop stale cache entries so memory use stays proportional to current finalized media.
    for entry in list(cache):
        if entry not in active_identities:
            del cache[entry]
    writer_failures = doc.get("failures") or []
    writer_warnings = doc.get("warnings") or []
    failed = [row for row in rows if row["status"] != "passed"]
    is_final = input_name == "report.json" and doc.get("completed") is True
    coverage = bool(rows) and len(rows) == len(segments) and not failed
    completed = is_final and coverage
    result = {
        "tool": "ProsioRecordingLiveDecode/1",
        "input": input_name,
        "inputCompleted": doc.get("completed") is True,
        "completed": completed,
        "passed": completed and not writer_failures,
        "snapshotDecodePassed": bool(rows) and not failed and not writer_failures,
        "finalizedSegmentCount": len(segments),
        "decodedCount": sum(row["status"] == "passed" for row in rows),
        "failedCount": len(failed),
        "writerFailures": writer_failures,
        "writerWarnings": writer_warnings,
        "writerDropCounts": writer_drop_counts(doc),
        "limits": ["synthetic media only", "decoded AAC PCM frame counts may include codec padding", "does not prove device capture, mouth-sync, or real-device drift"],
        "segments": rows,
    }
    write_atomic(output, result)
    return result, completed


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("media_root", type=Path)
    parser.add_argument("audit_json", type=Path)
    parser.add_argument("--watch", action="store_true", help="poll until completed report coverage is decoded")
    parser.add_argument("--poll-seconds", type=float, default=5.0)
    parser.add_argument("--timeout", type=float, default=120.0, help="per-file ffmpeg timeout in seconds")
    parser.add_argument("--ffmpeg", default=os.environ.get("FFMPEG", "ffmpeg"))
    parser.add_argument("--writer-pid", type=int, help="stop watch with an error if this writer process exits before final report")
    parser.add_argument("--writer-executable", help="optional substring expected in ps command for --writer-pid")
    args = parser.parse_args(argv)
    if args.timeout <= 0 or args.poll_seconds <= 0:
        parser.error("--timeout and --poll-seconds must be positive")
    ffmpeg = shutil.which(args.ffmpeg)
    if not ffmpeg:
        print(f"live_decode: ffmpeg executable not found: {args.ffmpeg}", file=sys.stderr)
        return 2
    cache = {}
    try:
        while True:
            result, completed = audit_once(args.media_root, args.audit_json, ffmpeg, args.timeout, cache)
            print(json.dumps({k: result[k] for k in ("input", "completed", "passed", "decodedCount", "finalizedSegmentCount", "failedCount")}), flush=True)
            terminal_report = result["input"] == "report.json"
            if not args.watch or completed or terminal_report or result["failedCount"]:
                return 0 if result["passed"] or (not args.watch and result["snapshotDecodePassed"] and result["input"] == "progress.json") else 1
            if args.writer_pid:
                probe = subprocess.run(["ps", "-p", str(args.writer_pid), "-o", "comm="], capture_output=True, text=True)
                process_name = probe.stdout.strip()
                if probe.returncode != 0 or not process_name:
                    if input_document(args.media_root)[1] == "report.json":
                        continue
                    raise AuditError(f"writer PID {args.writer_pid} exited before a completed report appeared")
                if args.writer_executable and args.writer_executable not in process_name:
                    if input_document(args.media_root)[1] == "report.json":
                        continue
                    raise AuditError(f"writer PID {args.writer_pid} command changed or did not match expected executable")
            time.sleep(args.poll_seconds)
    except AuditError as exc:
        print(f"live_decode: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
