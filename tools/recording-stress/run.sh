#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
stress_build="$(mktemp -d /tmp/prosio-recording-stress-build.XXXXXX)"
cat > "$stress_build/project.yml" <<YAML
name: ProsioRecordingStress
options:
  deploymentTarget:
    macOS: '26.0'
settings:
  base:
    SWIFT_VERSION: '6.0'
    SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor
    CODE_SIGNING_ALLOWED: NO
targets:
  ProsioRecordingStress:
    type: tool
    platform: macOS
    sources:
      - "$repo_root/Apps/macOS/Prosio/Recording/Domain"
      - "$repo_root/Apps/macOS/Prosio/Recording/Platform/RecordingMediaWriter.swift"
      - "$repo_root/Apps/macOS/Prosio/Recording/Platform/RecordingTimeline.swift"
      - "$repo_root/tools/recording-stress/RecordingStress.swift"
YAML
xcodegen generate --spec "$stress_build/project.yml" > "$stress_build/generate.log" 2>&1
if ! xcodebuild build -project "$stress_build/ProsioRecordingStress.xcodeproj" -scheme ProsioRecordingStress -configuration Release -derivedDataPath "$stress_build/build" CODE_SIGNING_ALLOWED=NO > "$stress_build/build.log" 2>&1; then
    cat "$stress_build/build.log"
    exit 1
fi
exec "$stress_build/build/Build/Products/Release/ProsioRecordingStress" "$@"
