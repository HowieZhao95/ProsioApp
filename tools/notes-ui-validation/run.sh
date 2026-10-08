#!/bin/bash
set -euo pipefail
notes_repo="$(cd "$(dirname "$0")/../.." && pwd)"
notes_build="${PROSIO_NOTES_BUILD_DIR:-/tmp/prosio-notes-ui-build}"
mkdir -p "$notes_build"
cat > "$notes_build/project.yml" <<YAML
name: NotesValidation
options:
  deploymentTarget:
    macOS: '26.0'
settings:
  base:
    SWIFT_VERSION: '6.0'
    SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor
    CODE_SIGNING_ALLOWED: NO
targets:
  NotesValidation:
    type: application
    platform: macOS
    sources:
      - path: "$notes_repo/Apps/macOS/Prosio/Notes"
        excludes: ['Editor']
      - path: "$notes_repo/Apps/macOS/Prosio/Notes/Editor/NotesEditor"
        type: folder
        buildPhase: resources
      - path: "$notes_repo/tools/notes-ui-validation/ValidationApp.swift"
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: app.prosio.validation.notes
    info:
      path: Info.plist
      properties:
        CFBundleIdentifier: app.prosio.validation.notes
        CFBundleDisplayName: Prosio 便签验收
        LSUIElement: true
        NSCalendarsFullAccessUsageDescription: 便签验收读取系统节假日，不修改日历事件。
  NotesStoreTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - "$notes_repo/Apps/macOS/Prosio/Notes/Domain"
      - "$notes_repo/Apps/macOS/Prosio/Notes/Storage"
      - "$notes_repo/Apps/macOS/ProsioTests/DailyNoteStoreTests.swift"
    settings:
      base:
        GENERATE_INFOPLIST_FILE: YES
schemes:
  NotesValidation:
    build:
      targets:
        NotesValidation: all
    test:
      targets: [NotesStoreTests]
YAML
xcodegen generate --spec "$notes_build/project.yml" --project "$notes_build" >/dev/null
xcodebuild -project "$notes_build/NotesValidation.xcodeproj" -scheme NotesValidation -derivedDataPath "$notes_build/products" build test > "$notes_build/build-test.log" 2>&1
printf '%s\n' "$notes_build/products/Build/Products/Debug/NotesValidation.app"
