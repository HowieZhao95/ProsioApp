#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
validation_open=false
validation_test=false
validation_dry=false
validation_identity="-"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --open) validation_open=true; shift ;;
        --test) validation_test=true; shift ;;
        --dry-run) validation_dry=true; shift ;;
        --identity) validation_identity="${2:?--identity needs an existing code signing identity}"; shift 2 ;;
        *) echo "Usage: $0 [--dry-run] [--test] [--identity IDENTITY] [--open]" >&2; exit 2 ;;
    esac
done
if [ "$validation_dry" = true ]; then
    echo "Build two independent bundles: app.prosio.validation.recording and app.prosio.validation.recording.fixture"
    echo "Compile unchanged production Engine/Platform/Domain/Storage; no capture, permission request or app launch"
    echo "Default signing identity: $validation_identity; --open explicitly opens only the resulting validation app"
    exit 0
fi
validation_build="$(mktemp -d /tmp/prosio-recording-device-validation.XXXXXX)"
mkdir -p "$validation_build/resources" "$validation_build/sources"
validation_sources="$validation_build/sources"
python3 - "$repo_root" "$validation_build/resources/validation-build.json" "$validation_sources" <<'PY'
import datetime, hashlib, json, pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
paths = []
for folder in ['Apps/macOS/Prosio/Recording/Domain', 'Apps/macOS/Prosio/Recording/Platform', 'Apps/macOS/Prosio/Recording/Storage', 'tools/recording-device-validation']:
    paths.extend(root.joinpath(folder).rglob('*.swift'))
paths.append(root / 'Apps/macOS/Prosio/Recording/Integration/RecordingEngineControlling.swift')
hashes = {}
for p in sorted(set(paths)):
    relative = p.relative_to(root)
    content = p.read_bytes()
    destination = pathlib.Path(sys.argv[3]) / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(content)
    hashes[str(relative)] = hashlib.sha256(content).hexdigest()
payload = {'revision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
           'workingTreeDirty': bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=root)),
           'builtAtUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
           'sourceSHA256': hashes}
pathlib.Path(sys.argv[2]).write_text(json.dumps(payload, indent=2, sort_keys=True))
PY
cat > "$validation_build/project.yml" <<YAML
name: RecordingDeviceValidation
options:
  deploymentTarget:
    macOS: '26.0'
settings:
  base:
    SWIFT_VERSION: '6.0'
    SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor
    SWIFT_ENFORCE_EXCLUSIVE_ACCESS: checked
    CODE_SIGNING_ALLOWED: NO
targets:
  RecordingDeviceValidation:
    type: application
    platform: macOS
    sources:
      - "$validation_sources/Apps/macOS/Prosio/Recording/Domain"
      - "$validation_sources/Apps/macOS/Prosio/Recording/Platform"
      - "$validation_sources/Apps/macOS/Prosio/Recording/Storage"
      - "$validation_sources/Apps/macOS/Prosio/Recording/Integration/RecordingEngineControlling.swift"
      - "$validation_sources/tools/recording-device-validation/Shared"
      - "$validation_sources/tools/recording-device-validation/Main"
      - path: "$validation_build/resources/validation-build.json"
        buildPhase: resources
    info:
      path: MainInfo.plist
      properties:
        CFBundleDisplayName: Prosio 录屏设备验收
        CFBundleIdentifier: app.prosio.validation.recording
        CFBundleShortVersionString: '1.0'
        CFBundleVersion: '1'
        NSCameraUsageDescription: 只有点击开始验收并选择摄像头后，工具才使用所选机位记录真实原片。
        NSMicrophoneUsageDescription: 只有点击开始验收并选择麦克风后，工具才记录独立麦克风原片。
        NSAudioCaptureUsageDescription: 只有点击开始验收并选择系统声音后，工具才记录系统声音原片。
        NSCameraUseContinuityCameraDeviceType: true
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: app.prosio.validation.recording
  RecordingValidationFixture:
    type: application
    platform: macOS
    sources:
      - "$validation_sources/tools/recording-device-validation/Shared"
      - "$validation_sources/tools/recording-device-validation/Fixture"
    info:
      path: FixtureInfo.plist
      properties:
        CFBundleDisplayName: Prosio 动态验收画面
        CFBundleIdentifier: app.prosio.validation.recording.fixture
        CFBundleShortVersionString: '1.0'
        CFBundleVersion: '1'
        LSUIElement: true
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: app.prosio.validation.recording.fixture
  RecordingDeviceValidationTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - "$validation_sources/Apps/macOS/Prosio/Recording/Domain"
      - "$validation_sources/Apps/macOS/Prosio/Recording/Platform"
      - "$validation_sources/Apps/macOS/Prosio/Recording/Storage"
      - "$validation_sources/Apps/macOS/Prosio/Recording/Integration/RecordingEngineControlling.swift"
      - "$validation_sources/tools/recording-device-validation/Shared"
      - "$validation_sources/tools/recording-device-validation/Main/ValidationReport.swift"
      - "$validation_sources/tools/recording-device-validation/Tests"
    settings:
      base:
        GENERATE_INFOPLIST_FILE: YES
        PRODUCT_BUNDLE_IDENTIFIER: app.prosio.validation.recording.tests
schemes:
  RecordingDeviceValidation:
    build:
      targets:
        RecordingDeviceValidation: all
        RecordingValidationFixture: all
  RecordingDeviceValidationTests:
    build:
      targets:
        RecordingDeviceValidationTests: all
    test:
      targets: [RecordingDeviceValidationTests]
YAML
xcodegen generate --spec "$validation_build/project.yml" > "$validation_build/generate.log" 2>&1
if ! xcodebuild build -project "$validation_build/RecordingDeviceValidation.xcodeproj" -scheme RecordingDeviceValidation -configuration Release -derivedDataPath "$validation_build/build" CODE_SIGNING_ALLOWED=NO > "$validation_build/build.log" 2>&1; then
    echo "Build failed; diagnostics: $validation_build/build.log" >&2
    rg -n 'error:|warning:' "$validation_build/build.log" >&2 || true
    exit 1
fi
validation_app="$validation_build/build/Build/Products/Release/RecordingDeviceValidation.app"
validation_fixture="$validation_build/build/Build/Products/Release/RecordingValidationFixture.app"
mkdir -p "$validation_app/Contents/Helpers"
ditto "$validation_fixture" "$validation_app/Contents/Helpers/RecordingValidationFixture.app"
python3 - "$validation_app/Contents/Resources/validation-build.json" "$validation_build/resources/validation-build.json" "$validation_sources" <<'PY'
import hashlib, json, pathlib, sys
packaged = pathlib.Path(sys.argv[1])
assert packaged.is_file(), 'Required build evidence was not packaged in the app'
payload = json.loads(packaged.read_text())
assert payload == json.loads(pathlib.Path(sys.argv[2]).read_text()), 'Packaged build evidence differs from the build snapshot'
hashes = payload['sourceSHA256']
assert len(hashes) == 15, f'Expected 15 frozen Swift sources, found {len(hashes)}'
for relative, expected in hashes.items():
    actual = hashlib.sha256((pathlib.Path(sys.argv[3]) / relative).read_bytes()).hexdigest()
    assert actual == expected, f'Frozen source identity mismatch: {relative}'
print('Packaged build evidence verified: 15 frozen source hashes match')
PY
codesign --force --sign "$validation_identity" --timestamp=none --options runtime "$validation_app/Contents/Helpers/RecordingValidationFixture.app"
codesign --force --sign "$validation_identity" --timestamp=none --options runtime --entitlements "$repo_root/tools/recording-device-validation/Validation.entitlements" "$validation_app"
codesign --verify --deep --strict "$validation_app"
if [ "$validation_test" = true ]; then
    if ! xcodebuild test -project "$validation_build/RecordingDeviceValidation.xcodeproj" -scheme RecordingDeviceValidationTests -configuration Release -destination 'platform=macOS' -derivedDataPath "$validation_build/test-build" CODE_SIGNING_ALLOWED=NO > "$validation_build/test.log" 2>&1; then
        echo "Synthetic tests failed; diagnostics: $validation_build/test.log" >&2
        rg -n 'error:|failed|Executed' "$validation_build/test.log" >&2 || true
        exit 1
    fi
    echo "Synthetic test log: $validation_build/test.log"
fi
echo "Validation app: $validation_app"
echo "Build evidence: $validation_app/Contents/Resources/validation-build.json"
echo "Built and signed only. No capture, permission request, fixture launch or editor launch."
if [ "$validation_open" = true ]; then open -n "$validation_app"; fi
