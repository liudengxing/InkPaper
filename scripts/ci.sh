#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

MODE="${1:-all}"

case "$MODE" in
  all|android|android-debug|android-release|android-release-split)
    ;;
  *)
    echo "Usage: scripts/ci.sh [all|android-debug|android-release|android-release-split]" >&2
    exit 2
    ;;
esac

case "$MODE" in
  android) MODE="android-release" ;;
esac

dart tool/inkpaper.dart ci "$MODE"
