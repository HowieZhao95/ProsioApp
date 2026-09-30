import json
import os
import shutil
import subprocess
import sys
import io
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

import live_decode


FFMPEG = shutil.which("/opt/homebrew/bin/ffmpeg") or shutil.which("ffmpeg")


@unittest.skipUnless(FFMPEG, "ffmpeg is required for live decode tests")
class LiveDecodeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="prosio-live-decode-test-")
        self.root = Path(self.temp.name) / "media-root"
        (self.root / "media").mkdir(parents=True)
        self.output = Path(self.temp.name) / "audit.json"
        self.video = self.root / "media" / "test.mp4"
        self.audio = self.root / "media" / "test.m4a"
        self.make_media()

    def tearDown(self):
        self.temp.cleanup()

    def make_media(self):
        subprocess_run = subprocess.run
        subprocess_run([FFMPEG, "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "color=c=blue:s=64x64:r=10:d=0.5",
                        "-c:v", "libx264", "-threads", "2", "-pix_fmt", "yuv420p", "-y", str(self.video)], check=True)
        subprocess_run([FFMPEG, "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=0.5",
                        "-c:a", "aac", "-threads", "2", "-y", str(self.audio)], check=True)

    def segment(self, path, source, ident, **extra):
        return {"id": ident, "sourceID": source, "relativePath": str(path.relative_to(self.root)), **extra}

    def write_input(self, segments, completed=False, filename="progress.json", **extra):
        (self.root / filename).write_text(json.dumps({"completed": completed, "segments": segments, "warnings": [], "failures": [], **extra}))

    def decode(self, cache=None, timeout=10):
        return live_decode.audit_once(self.root, self.output, FFMPEG, timeout, cache if cache is not None else {})[0]

    def test_snapshot_is_partial_but_decodes_published_segments(self):
        self.write_input([self.segment(self.video, "screen", "v1", width=64, height=64)])
        result = self.decode()
        self.assertFalse(result["completed"])
        self.assertFalse(result["passed"])
        self.assertEqual(result["decodedCount"], 1)
        self.assertEqual(result["segments"][0]["videoFrames"], 5)
        self.assertEqual(json.loads(self.output.read_text())["input"], "progress.json")

    def test_incremental_cache_and_final_report_coverage(self):
        video = self.segment(self.video, "screen", "v1", width=64, height=64)
        audio = self.segment(self.audio, "microphone", "a1", channelCount=1, sampleRate=48000)
        cache = {}
        self.write_input([video])
        with mock.patch.object(live_decode, "run_decode", wraps=live_decode.run_decode) as decode:
            self.decode(cache)
            self.write_input([video, audio])
            self.decode(cache)
            self.assertEqual(decode.call_count, 2)
            self.write_input([video, audio], completed=True, filename="report.json")
            result = self.decode(cache)
            self.assertEqual(decode.call_count, 2)
        self.assertTrue(result["completed"])
        self.assertTrue(result["passed"])
        self.assertEqual(result["finalizedSegmentCount"], 2)
        self.assertGreater(result["segments"][1]["audioSampleFrames"], 0)
        self.assertIn("AAC", result["segments"][1]["audioCountNote"])

    def test_empty_final_report_is_not_successful_decode_evidence(self):
        self.write_input([], completed=True, filename="report.json")
        result = self.decode()
        self.assertFalse(result["completed"])
        self.assertFalse(result["passed"])
        script = Path(live_decode.__file__)
        process = subprocess.run([sys.executable, str(script), str(self.root), str(self.output),
                                  "--watch", "--ffmpeg", FFMPEG], capture_output=True, text=True, timeout=3)
        self.assertEqual(process.returncode, 1)

    def test_writer_failures_are_separate_from_decode_coverage(self):
        self.write_input([self.segment(self.video, "screen", "v1", width=64, height=64)],
                         completed=True, filename="report.json", failures=["writer failed"])
        result = self.decode()
        self.assertTrue(result["completed"])
        self.assertFalse(result["passed"])
        self.assertEqual(result["writerFailures"], ["writer failed"])

    def test_corrupt_media_returns_ffmpeg_failure(self):
        bad = self.root / "media" / "bad.mp4"
        bad.write_bytes(b"not a media file")
        self.write_input([self.segment(bad, "screen", "bad", width=64, height=64)])
        result = self.decode()
        self.assertEqual(result["failedCount"], 1)
        self.assertNotEqual(result["segments"][0]["exitCode"], 0)

    def test_timeout_is_controlled(self):
        sleeper = Path(self.temp.name) / "slow-ffmpeg"
        sleeper.write_text("#!/usr/bin/env python3\nimport time\ntime.sleep(5)\n")
        sleeper.chmod(0o755)
        start = time.monotonic()
        result = live_decode.run_decode(str(sleeper), self.video,
                                        self.segment(self.video, "screen", "v1", width=64, height=64), 0.15)
        self.assertLess(time.monotonic() - start, 2)
        self.assertIn("timeout", result["error"])

    def test_watch_stops_if_writer_pid_is_gone(self):
        self.write_input([])
        script = Path(live_decode.__file__)
        result = subprocess.run([sys.executable, str(script), str(self.root), str(self.output), "--watch",
                                 "--poll-seconds", "0.01", "--writer-pid", "99999999", "--ffmpeg", FFMPEG],
                                capture_output=True, text=True, timeout=3)
        self.assertEqual(result.returncode, 2)
        self.assertIn("exited before a completed report", result.stderr)

    def test_watch_exits_on_failed_decode_in_final_report_without_pid(self):
        bad = self.root / "media" / "bad.mp4"
        bad.write_bytes(b"not a media file")
        self.write_input([self.segment(bad, "screen", "bad", width=64, height=64)],
                         completed=True, filename="report.json")
        script = Path(live_decode.__file__)
        result = subprocess.run([sys.executable, str(script), str(self.root), str(self.output), "--watch",
                                 "--poll-seconds", "0.01", "--ffmpeg", FFMPEG],
                                capture_output=True, text=True, timeout=3)
        self.assertEqual(result.returncode, 1)
        self.assertTrue(self.output.is_file())
        self.assertEqual(json.loads(self.output.read_text())["failedCount"], 1)

    def test_watch_exits_on_writer_failure_in_final_report_without_pid(self):
        segment = self.segment(self.video, "screen", "v1", width=64, height=64)
        self.write_input([segment], completed=True, filename="report.json", failures=["writer failure"])
        script = Path(live_decode.__file__)
        result = subprocess.run([sys.executable, str(script), str(self.root), str(self.output), "--watch",
                                 "--poll-seconds", "0.01", "--ffmpeg", FFMPEG],
                                capture_output=True, text=True, timeout=3)
        self.assertEqual(result.returncode, 1)
        audit = json.loads(self.output.read_text())
        self.assertEqual(audit["decodedCount"], 1)
        self.assertFalse(audit["passed"])
        self.assertEqual(audit["writerFailures"], ["writer failure"])

    def test_watch_rereads_final_report_if_writer_exits_during_progress_decode(self):
        segment = self.segment(self.video, "screen", "v1", width=64, height=64)
        self.write_input([segment])
        report = {"completed": True, "segments": [segment], "warnings": [], "failures": []}
        def exited_after_finalize(*_args, **_kwargs):
            (self.root / "report.json").write_text(json.dumps(report))
            return subprocess.CompletedProcess(args=["ps"], returncode=1, stdout="", stderr="")
        with mock.patch.object(live_decode.subprocess, "run", side_effect=exited_after_finalize), \
                mock.patch("sys.stdout", new=io.StringIO()):
            status = live_decode.main([str(self.root), str(self.output), "--watch", "--poll-seconds", "0.01",
                                       "--writer-pid", "12345", "--ffmpeg", FFMPEG])
        self.assertEqual(status, 0)
        result = json.loads(self.output.read_text())
        self.assertEqual(result["input"], "report.json")
        self.assertTrue(result["passed"])

    def test_zero_exit_with_error_diagnostic_fails(self):
        fake = Path(self.temp.name) / "fake-ffmpeg"
        fake.write_text("#!/usr/bin/env python3\nimport sys\nsys.stdout.write('frame=1\\nprogress=end\\n')\nsys.stderr.write('decode error: damaged frame\\n')\n")
        fake.chmod(0o755)
        result = live_decode.run_decode(str(fake), self.video,
                                        self.segment(self.video, "screen", "v1", width=64, height=64), 1)
        self.assertEqual(result["exitCode"], 0)
        self.assertIn("error-level diagnostics", result["error"])

    def test_video_progress_line_is_bounded(self):
        fake = Path(self.temp.name) / "no-newline-ffmpeg"
        fake.write_text("#!/usr/bin/env python3\nimport sys\nsys.stdout.write('x' * 20000)\nsys.stdout.flush()\nimport time\ntime.sleep(5)\n")
        fake.chmod(0o755)
        start = time.monotonic()
        result = live_decode.run_decode(str(fake), self.video,
                                        self.segment(self.video, "screen", "v1", width=64, height=64), 2)
        self.assertLess(time.monotonic() - start, 1.5)
        self.assertIn("16 KiB line limit", result["error"])

    def test_cache_identity_includes_path_when_same_id_size_and_mtime(self):
        original = self.segment(self.video, "screen", "same-id", width=64, height=64)
        copied_path = self.root / "media" / "second.mp4"
        copied_path.write_bytes(self.video.read_bytes())
        original_stat = self.video.stat()
        os.utime(copied_path, ns=(original_stat.st_atime_ns, original_stat.st_mtime_ns))
        copied = self.segment(copied_path, "screen", "same-id", width=64, height=64)
        self.write_input([original])
        cache = {}
        first = self.decode(cache)
        self.assertEqual(first["decodedCount"], 1)
        copied_path.write_bytes(b"\0" * original_stat.st_size)
        os.utime(copied_path, ns=(original_stat.st_atime_ns, original_stat.st_mtime_ns))
        self.assertEqual(copied_path.stat().st_size, original_stat.st_size)
        self.write_input([original, copied])
        result = self.decode(cache)
        self.assertEqual(result["decodedCount"], 1)
        self.assertEqual(result["failedCount"], 1)

    def test_vfr_gaps_count_decoded_input_frames_without_duplication(self):
        vfr = self.root / "media" / "gaps.mkv"
        subprocess.run([FFMPEG, "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=s=64x64:r=10:d=1",
                        "-vf", "select=eq(n\\,0)+eq(n\\,4)+eq(n\\,9)", "-fps_mode", "vfr", "-c:v", "libx264",
                        "-threads", "2", "-y", str(vfr)], check=True)
        result = live_decode.run_decode(FFMPEG, vfr, self.segment(vfr, "screen", "vfr", width=64, height=64), 10)
        self.assertEqual(result["videoFrames"], 3)

    def test_unsafe_paths_rejected(self):
        outside = Path(self.temp.name) / "outside.mp4"
        outside.write_bytes(self.video.read_bytes())
        cases = ["/absolute.mp4", "../outside.mp4"]
        for relative in cases:
            with self.subTest(relative=relative):
                with self.assertRaises(live_decode.AuditError):
                    live_decode.safe_media(self.root, relative)
        link = self.root / "media" / "escape.mp4"
        link.symlink_to(outside)
        with self.assertRaises(live_decode.AuditError):
            live_decode.safe_media(self.root, "media/escape.mp4")

    def test_cache_invalidated_when_media_changes(self):
        segment = self.segment(self.video, "screen", "v1", width=64, height=64)
        cache = {}
        self.write_input([segment])
        with mock.patch.object(live_decode, "run_decode", wraps=live_decode.run_decode) as decode:
            self.decode(cache)
            with self.video.open("ab") as stream:
                stream.write(b" ")
            os.utime(self.video, ns=(self.video.stat().st_atime_ns, self.video.stat().st_mtime_ns + 1_000_000))
            self.decode(cache)
            self.assertEqual(decode.call_count, 2)


if __name__ == "__main__":
    unittest.main()
