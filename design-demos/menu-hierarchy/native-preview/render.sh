#!/bin/zsh
set -euo pipefail

preview_dir="${0:A:h}"
repo_dir="${preview_dir:h:h:h}"
mkdir -p "$preview_dir/.build" "$preview_dir/images"

swiftc -swift-version 6 \
  "$repo_dir/Apps/macOS/Prosio/UI/MenuBar/MenuBarShell.swift" \
  "$preview_dir/SnapshotRenderer.swift" \
  "$preview_dir/PreviewMain.swift" \
  -o "$preview_dir/.build/menu-native-preview"

"$preview_dir/.build/menu-native-preview" "$preview_dir/images"
