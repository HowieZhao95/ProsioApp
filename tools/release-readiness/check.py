#!/usr/bin/env python3
"""Read-only checks of a built macOS bundle; never publishes or changes TCC."""
import argparse
import hashlib
import json
import plistlib
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlparse


def run(*command):
    result = subprocess.run(command, capture_output=True, text=True)
    return result.returncode, result.stdout + result.stderr


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    app = args.app.resolve()
    checks = []

    def check(name, passed, detail):
        checks.append({'check': name, 'passed': bool(passed), 'detail': detail})

    with (app / 'Contents/Info.plist').open('rb') as source:
        info = plistlib.load(source)
    binary = app / 'Contents/MacOS' / info['CFBundleExecutable']
    status, signature = run('codesign', '--verify', '--deep', '--strict', '--verbose=2', str(app))
    check('signature_integrity', status == 0, 'Strict nested-code signature verification')
    _, signing = run('codesign', '-d', '--verbose=4', str(app))
    check('developer_id', 'Authority=Developer ID Application:' in signing and 'TeamIdentifier=not set' not in signing, 'Public distribution requires a Developer ID Application identity')
    check('hardened_runtime', 'runtime' in signing, 'Hardened runtime flag')
    check('secure_timestamp', 'Timestamp=' in signing, 'Secure signing timestamp must be present')
    _, entitlement_output = run('codesign', '-d', '--entitlements', ':-', str(app))
    begin = entitlement_output.find('<?xml')
    end = entitlement_output.find('</plist>')
    entitlements = plistlib.loads(entitlement_output[begin:end+8].encode()) if begin >= 0 and end >= 0 else {}
    for name in ['com.apple.security.get-task-allow', 'com.apple.security.cs.disable-library-validation', 'com.apple.security.cs.allow-unsigned-executable-memory']:
        check(name, begin >= 0 and not entitlements.get(name, False), 'Release must not carry a development exception')
    raw_url = info.get('ProsioBackendURL', '')
    url = urlparse(raw_url)
    host = url.hostname or ''
    check('production_endpoint', url.scheme == 'https' and bool(host) and host not in ['localhost','127.0.0.1','::1'] and not host.endswith(('.test','.invalid')) and host != 'example.com' and not host.endswith('.example.com'), 'Bundle must contain the actual production HTTPS endpoint')
    for key in ['NSMicrophoneUsageDescription','NSCameraUsageDescription','NSSpeechRecognitionUsageDescription','NSCalendarsFullAccessUsageDescription']:
        check(key, bool(info.get(key)), 'Permission purpose description')
    check('validation_mode', not info.get('ProsioOnboardingValidation', False), 'Validation-only launch mode must be absent')
    status, _ = run('xcrun', 'stapler', 'validate', str(app))
    check('notarization_ticket', status == 0, 'Stapled Apple notarization ticket')
    status, _ = run('spctl', '--assess', '--type', 'execute', '--verbose=2', str(app))
    check('gatekeeper', status == 0, 'Gatekeeper execution assessment')
    _, architecture = run('lipo', '-archs', str(binary))
    report = {'checked_at': datetime.now(timezone.utc).isoformat(), 'app': str(app),
              'version': info.get('CFBundleShortVersionString'), 'build': info.get('CFBundleVersion'),
              'minimum_macos': info.get('LSMinimumSystemVersion'), 'architectures': architecture.strip(),
              'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
              'bundle_checks_passed': all(item['passed'] for item in checks),
              'scope': 'Artifact checks only. Login, billing, privacy policy, live database and device acceptance require separate evidence.',
              'checks': checks}
    output = json.dumps(report, ensure_ascii=False, indent=2)
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(output + '\n')
    print(output)
    return 0 if report['bundle_checks_passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
