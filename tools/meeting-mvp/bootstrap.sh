#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
COMMIT=20d4f0bd46d11d7f50a6eb4f7835cfdbd2b4ba14
TARGET="$ROOT/.vendor/FluidAudio"

if [ -d "$TARGET/.git" ]; then
    ACTUAL=$(git -C "$TARGET" rev-parse HEAD)
    if [ "$ACTUAL" = "$COMMIT" ]; then
        echo "FluidAudio already at $COMMIT"
        exit 0
    fi
    echo "Existing FluidAudio checkout is at $ACTUAL; expected $COMMIT" >&2
    exit 1
fi

mkdir -p "$ROOT/.vendor"
TEMP=$(mktemp -d "$ROOT/.vendor/FluidAudio.XXXXXX")
trap 'rm -rf "$TEMP"' EXIT HUP INT TERM
git -C "$TEMP" init -q
git -C "$TEMP" fetch --depth 1 https://github.com/FluidInference/FluidAudio.git "$COMMIT"
git -C "$TEMP" checkout --detach -q FETCH_HEAD
ACTUAL=$(git -C "$TEMP" rev-parse HEAD)
[ "$ACTUAL" = "$COMMIT" ] || { echo "Commit verification failed" >&2; exit 1; }
mv "$TEMP" "$TARGET"
trap - EXIT HUP INT TERM
echo "FluidAudio ready at $COMMIT"
