#!/usr/bin/env python3
"""Run isolated, signed sandbox/non-sandbox probes. Does not modify Prosio or TCC."""
import json
import platform
import os
from pathlib import Path
import plistlib
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / '.build' / 'distribution-probe'
OUT.mkdir(parents=True, exist_ok=True)
IDENTITY = os.environ.get('PROSIO_PROBE_SIGNING_IDENTITY', 'Prosio Local Development')
binary = OUT / 'Probe'
subprocess.run(['xcrun', 'swiftc', str(Path(__file__).with_name('Probe.swift')), '-o', str(binary)], check=True)
fixture = OUT / 'Fixture.app'
(fixture / 'Contents/MacOS').mkdir(parents=True, exist_ok=True)
(fixture / 'Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'app.prosio.distribution-fixture', 'CFBundleExecutable': 'Fixture',
    'CFBundleName': 'Prosio Distribution Fixture', 'CFBundlePackageType': 'APPL',
}))
import shutil
shutil.copy2(binary, fixture / 'Contents/MacOS/Fixture')
subprocess.run(['codesign', '--force', '--sign', IDENTITY, str(fixture)], check=True)
outside = OUT / 'outside-sandbox.txt'
outside.write_text('Non-sensitive sandbox denial control.\n')
results = []
for sandboxed in [False, True]:
    mode = 'sandbox' if sandboxed else 'unsandboxed'
    entitlements = OUT / f'{mode}.entitlements'
    entitlements.write_bytes(plistlib.dumps({'com.apple.security.app-sandbox': sandboxed}))
    bundle = OUT / f'Probe-{mode}.app'
    (bundle / 'Contents/MacOS').mkdir(parents=True, exist_ok=True)
    (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'app.prosio.distribution-probe', 'CFBundleExecutable': 'Probe',
        'CFBundleName': 'Prosio Distribution Probe', 'CFBundlePackageType': 'APPL',
        'LSUIElement': True,
    }))
    probe = bundle / 'Contents/MacOS/Probe'
    shutil.copy2(binary, probe)
    subprocess.run(['codesign', '--force', '--sign', IDENTITY, '--identifier', 'app.prosio.distribution-probe',
                    '--entitlements', str(entitlements), str(bundle)], check=True)
    log = OUT / f'{mode}-fixture.jsonl'
    with log.open('w') as stream:
        proc = subprocess.Popen([str(fixture / 'Contents/MacOS/Fixture'), '--fixture'], stdout=stream, stderr=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline and not log.read_text().strip():
                time.sleep(.1)
            time.sleep(.5)
            run = subprocess.run([str(probe), str(proc.pid), str(outside), mode], capture_output=True, text=True, timeout=12)
            time.sleep(.2)
            observations = [json.loads(line) for line in log.read_text().splitlines() if line.startswith('{')]
            result = {'mode': mode, 'returncode': run.returncode, 'stdout': run.stdout,
                      'stderr': run.stderr, 'fixtureObservations': observations, 'macOS': platform.mac_ver()[0]}
            print(json.dumps(result, ensure_ascii=False), flush=True)
            results.append(result)
        finally:
            proc.terminate()
            proc.wait(timeout=5)
(OUT / 'results.json').write_text(json.dumps(results, indent=2, ensure_ascii=False) + '\n')
print('Results:', OUT / 'results.json')
