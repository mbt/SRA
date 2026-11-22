#!/bin/sh
# Build all shipped harness binaries, size-first.
# Usage: scripts/build-harness.sh [out-dir]
# Default: ReleaseSmall into dist/ in repo root.
set -eu
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

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

# Single source of truth: dist/ is authoritative; mirror into the iOS
# resources dir so the Xcode bundle always ships exactly what was built
# (both paths are gitignored — only the build produces them).
IOS_RES="../ios/SecureRemoteAgent/Resources/Harnesses"
if [ -d "../ios/SecureRemoteAgent" ]; then
  mkdir -p "$IOS_RES"
  for f in "../$OUT"/harness-*; do
    [ -e "$f" ] || continue
    cp "$f" "$IOS_RES/$(basename "$f")"
  done
  # Verify byte-for-byte equality (catches drift before archive).
  for f in "../$OUT"/harness-*; do
    [ -e "$f" ] || continue
    b=$(basename "$f")
    if ! cmp -s "$f" "$IOS_RES/$b"; then
      echo "ERROR: $b differs between $OUT and $IOS_RES" >&2
      exit 1
    fi
  done
  echo "Mirrored $OUT -> $IOS_RES (sha-identical)."
fi

"$REPO_ROOT/scripts/size-report.sh" "../$OUT"
