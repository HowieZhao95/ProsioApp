#!/usr/bin/env python3
"""Fetch FluidAudio's pinned offline diarizer assets with curl's normal TLS validation.

Useful on hosts where FluidAudio's URLSession download fails certificate validation.
Does not disable certificate checks. Files stay in FluidAudio's user model cache.
"""

from pathlib import Path
import subprocess
import sys

REVISION = "df2625ac79a7ac6b65ad868fee6d80f320da4232"
BASE = "https://huggingface.co/FluidInference/speaker-diarization-coreml/resolve"
ROOT = Path.home() / "Library/Application Support/FluidAudio/Models/speaker-diarization"
FILES = {
    "Embedding.mlmodelc/analytics/coremldata.bin": 243,
    "Embedding.mlmodelc/coremldata.bin": 704,
    "Embedding.mlmodelc/metadata.json": 2818,
    "Embedding.mlmodelc/model.mil": 78432,
    "Embedding.mlmodelc/weights/weight.bin": 13412288,
    "FBank.mlmodelc/analytics/coremldata.bin": 243,
    "FBank.mlmodelc/coremldata.bin": 853,
    "FBank.mlmodelc/metadata.json": 3409,
    "FBank.mlmodelc/model.mil": 15667,
    "FBank.mlmodelc/weights/weight.bin": 1776896,
    "PldaRho.mlmodelc/analytics/coremldata.bin": 243,
    "PldaRho.mlmodelc/coremldata.bin": 763,
    "PldaRho.mlmodelc/metadata.json": 2749,
    "PldaRho.mlmodelc/model.mil": 7613,
    "PldaRho.mlmodelc/weights/weight.bin": 200192,
    "Segmentation.mlmodelc/analytics/coremldata.bin": 243,
    "Segmentation.mlmodelc/coremldata.bin": 812,
    "Segmentation.mlmodelc/metadata.json": 3410,
    "Segmentation.mlmodelc/model.mil": 43063,
    "Segmentation.mlmodelc/weights/weight.bin": 5959360,
    "plda-parameters.json": 89416,
}


def main() -> int:
    for name, expected_bytes in FILES.items():
        target = ROOT / name
        if target.is_file() and target.stat().st_size == expected_bytes:
            print("cached", name)
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        temporary = target.with_name(target.name + ".download")
        url = f"{BASE}/{REVISION}/{name}"
        print("fetch", name, flush=True)
        subprocess.run(
            ["curl", "--fail", "--location", "--show-error", "--silent", "--retry", "2",
             "--output", str(temporary), url],
            check=True,
        )
        actual_bytes = temporary.stat().st_size
        if actual_bytes != expected_bytes:
            temporary.unlink(missing_ok=True)
            print(f"size mismatch for {name}: expected {expected_bytes}, got {actual_bytes}", file=sys.stderr)
            return 1
        temporary.replace(target)
    print("FluidAudio offline diarizer assets ready:", ROOT)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
