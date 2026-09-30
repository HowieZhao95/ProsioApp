#!/bin/sh
set -eu

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "Usage: $0 <progress.json|report.json|recording.json> [media-root]" >&2
  exit 2
fi

input=$1
root=${2:-$(dirname "$input")}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/prosio-media-audit.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

swiftc -parse-as-library -O "$(dirname "$0")/RecordingMediaAudit.swift" \
  -framework AVFoundation -framework CoreMedia -o "$tmp/recording-media-audit"
"$tmp/recording-media-audit" "$input" "$root"
