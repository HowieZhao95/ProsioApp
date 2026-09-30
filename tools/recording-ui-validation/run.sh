#!/bin/bash
set -euo pipefail
validation_fixture_app="${1:-}"
validation_root="$(cd "$(dirname "$0")/../.." && pwd)"
validation_build="$(mktemp -d /tmp/prosio-recording-ui-validation.XXXXXX)"
cat > "$validation_build/project.yml" <<YAML
name: RecordingUIValidation
options:
  deploymentTarget:
    macOS: '26.0'
settings:
  base:
    SWIFT_VERSION: '6.0'
    SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor
    CODE_SIGNING_ALLOWED: NO
    SWIFT_ENFORCE_EXCLUSIVE_ACCESS: checked
targets:
  RecordingUIValidation:
    type: application
    platform: macOS
    sources:
      - "$validation_root/Apps/macOS/Prosio/Recording"
      - "$validation_root/Apps/macOS/Prosio/UI/Recording"
      - "$validation_root/Apps/macOS/Prosio/Capture/Domain/CaptureGeometry.swift"
      - "$validation_root/Apps/macOS/Prosio/Capture/Interaction/CaptureInteractionGeometry.swift"
      - "$validation_root/Apps/macOS/Prosio/System/PermissionsManager.swift"
      - "$validation_root/Apps/macOS/Prosio/System/ProsioLog.swift"
      - path: "$validation_root/tools/recording-ui-validation"
        excludes: ['run.sh', 'README.md', 'Smoke.swift']
    info:
      path: Info.plist
      properties:
        CFBundleIdentifier: app.prosio.validation.immersive
        CFBundleDisplayName: Prosio 原生交互验收
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: app.prosio.validation.immersive
  RecordingUIFixtureSmoke:
    type: tool
    platform: macOS
    sources:
      - "$validation_root/Apps/macOS/Prosio/Recording/Domain"
      - "$validation_root/Apps/macOS/Prosio/Recording/Platform"
      - "$validation_root/Apps/macOS/Prosio/Recording/Storage"
      - "$validation_root/Apps/macOS/Prosio/Recording/Integration/RecordingEngineControlling.swift"
      - "$validation_root/tools/recording-ui-validation/FixtureEngine.swift"
      - "$validation_root/tools/recording-ui-validation/Smoke.swift"
YAML
xcodegen generate --spec "$validation_build/project.yml" > "$validation_build/generate.log" 2>&1
if ! xcodebuild build -project "$validation_build/RecordingUIValidation.xcodeproj" -scheme RecordingUIValidation -configuration Debug -derivedDataPath "$validation_build/build" > "$validation_build/build.log" 2>&1; then
    rg 'error:|BUILD FAILED' "$validation_build/build.log" >&2
    exit 1
fi
validation_app="$validation_build/build/Build/Products/Debug/RecordingUIValidation.app"
if [ -n "$validation_fixture_app" ]; then
    test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$validation_fixture_app/Contents/Info.plist")" = "app.prosio.validation.recording.fixture"
    mkdir -p "$validation_app/Contents/Helpers"
    cp -R "$validation_fixture_app" "$validation_app/Contents/Helpers/"
    codesign --force --sign - "$validation_app/Contents/Helpers/RecordingValidationFixture.app"
fi
codesign --force --sign - "$validation_app"
codesign --verify --deep --strict "$validation_app"
echo "$validation_app"
echo "Built only; use native app tools to launch. No capture or permissions requested."

if [ "${2:-}" = "--smoke" ]; then
    if ! xcodebuild build -project "$validation_build/RecordingUIValidation.xcodeproj" -scheme RecordingUIFixtureSmoke -configuration Debug -derivedDataPath "$validation_build/build" > "$validation_build/smoke-build.log" 2>&1; then
        rg 'error:|BUILD FAILED' "$validation_build/smoke-build.log" >&2
        exit 1
    fi
    "$validation_build/build/Build/Products/Debug/RecordingUIFixtureSmoke"
fi
