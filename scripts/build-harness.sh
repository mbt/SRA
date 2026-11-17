#!/bin/sh
# Build all shipped harness binaries, size-first.
# Usage: scripts/build-harness.sh [out-dir]
# Default: ReleaseSmall into dist/ in repo root.
set -eu

OUT="${1:-dist}"
cd "$(dirname "$0")/../harness"
# Pinned toolchain: system Zig 0.17.x (0.14/0.15 cannot link on current macOS).
ZIG=zig

build_one() {
  slug="$1"; target="$2"
  echo "==> $slug ($target, --release=small)"
  rm -rf "zig-out/$slug"
  $ZIG build --release=small -Dtarget="$target" -p "zig-out/$slug"
  mkdir -p "../$OUT"
  cp "zig-out/$slug/bin/secure-remote-harness" "../$OUT/harness-$slug"
  # Belt-and-braces strip (build.zig already sets strip=true).
  case "$(uname -sm)" in
    *Darwin*) strip -x "../$OUT/harness-$slug" 2>/dev/null || true ;;
    *Linux*) strip "../$OUT/harness-$slug" 2>/dev/null || true ;;
  esac
}

build_one "darwin-arm64" "aarch64-macos"
build_one "darwin-x64" "x86_64-macos"
build_one "linux-x64" "x86_64-linux-musl"
build_one "linux-arm64" "aarch64-linux-musl"

echo "--- sizes ---"
ls -lh "../$OUT"/harness-*
"$(dirname "$0")/size-report.sh" "../$OUT"
