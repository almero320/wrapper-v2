#!/usr/bin/env bash
# extract-libs.sh - Extract Apple native libraries from an APK source and
# verify each one against LIBS_VERSION.json.
#
# Two input modes (mutually exclusive):
#   --bundle <path-to-.apkm>     APKMirror multi-arch bundle (preferred)
#   --apk    <path-to-split>     Single APK split (e.g. split_config.x86_64.apk)
#
# Common args:
#   --arch <x86_64|arm64-v8a>    Which arch's libs to extract (default x86_64)
#   --out  <directory>           Where to drop the .so files
#
# Bundle mode verifies the bundle's SHA-256 against the .apkm pin in
# LIBS_VERSION.json, then verifies the inner split's SHA-256 against the
# .splits pin, then verifies every .so against the .libs pin.
# APK mode skips the bundle check; the split SHA + per-.so SHAs are still
# verified.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIBS_VERSION="$REPO_ROOT/LIBS_VERSION.json"

BUNDLE=""
APK=""
ARCH="x86_64"
OUT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bundle) BUNDLE="$2"; shift 2 ;;
        --apk)    APK="$2";    shift 2 ;;
        --arch)   ARCH="$2";   shift 2 ;;
        --out)    OUT="$2";    shift 2 ;;
        -h|--help)
            sed -n '2,18p' "$0"
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "$BUNDLE" && -z "$APK" ]]; then
    echo "extract-libs: provide either --bundle <apkm> or --apk <split>" >&2
    exit 2
fi
if [[ -n "$BUNDLE" && -n "$APK" ]]; then
    echo "extract-libs: --bundle and --apk are mutually exclusive" >&2
    exit 2
fi
if [[ -z "$OUT" ]]; then
    echo "extract-libs: missing --out" >&2
    exit 2
fi

case "$ARCH" in
    x86_64)    SPLIT_NAME="split_config.x86_64.apk"    ;;
    arm64-v8a) SPLIT_NAME="split_config.arm64_v8a.apk" ;;
    *) echo "extract-libs: unsupported arch '$ARCH'" >&2; exit 2 ;;
esac
APK_LIB_DIR="lib/$ARCH"

for c in jq sha256sum unzip; do
    command -v "$c" >/dev/null || { echo "extract-libs: $c is required" >&2; exit 3; }
done

verify_sha() {
    local file="$1"
    local expected="$2"
    local label="$3"
    local actual
    actual="$(sha256sum "$file" | awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
        echo "extract-libs: SHA-256 mismatch on $label" >&2
        echo "  expected: $expected" >&2
        echo "  actual:   $actual" >&2
        return 1
    fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ -n "$BUNDLE" ]]; then
    EXPECT_BUNDLE="$(jq -r '.apkm // empty' "$LIBS_VERSION" | tr -d '\r')"
    [[ -n "$EXPECT_BUNDLE" ]] || { echo "extract-libs: no .apkm pin in LIBS_VERSION.json" >&2; exit 4; }
    verify_sha "$BUNDLE" "$EXPECT_BUNDLE" "$(basename "$BUNDLE") (apkm bundle)" || exit 5

    unzip -qq "$BUNDLE" "$SPLIT_NAME" -d "$TMP"
    APK="$TMP/$SPLIT_NAME"

    EXPECT_SPLIT="$(jq -r --arg k "$SPLIT_NAME" '.splits[$k] // empty' "$LIBS_VERSION" | tr -d '\r')"
    [[ -n "$EXPECT_SPLIT" ]] || { echo "extract-libs: no SHA pin for $SPLIT_NAME" >&2; exit 4; }
    verify_sha "$APK" "$EXPECT_SPLIT" "$SPLIT_NAME (extracted from bundle)" || exit 5
else
    EXPECT_SPLIT="$(jq -r --arg k "$(basename "$APK")" '.splits[$k] // empty' "$LIBS_VERSION" | tr -d '\r')"
    if [[ -n "$EXPECT_SPLIT" ]]; then
        verify_sha "$APK" "$EXPECT_SPLIT" "$(basename "$APK")" || exit 5
    else
        echo "extract-libs: warn: no SHA pin matched '$(basename "$APK")', skipping split-level verify" >&2
    fi
fi

mkdir -p "$OUT"
LIB_TMP="$TMP/libs"
mkdir -p "$LIB_TMP"
unzip -qq "$APK" "$APK_LIB_DIR/*" -d "$LIB_TMP"

# `jq.exe` on msys2/MSVC emits CRLF on Windows; strip CR defensively before
# iterating, otherwise lib names get a stray \r appended and every lookup fails.
mapfile -t EXPECTED_LIBS < <(
    jq -r --arg arch "$ARCH" '.libs[$arch] | keys[]' "$LIBS_VERSION" | tr -d '\r'
)

ok=0
fail=0
for so in "${EXPECTED_LIBS[@]}"; do
    src="$LIB_TMP/$APK_LIB_DIR/$so"
    if [[ ! -f "$src" ]]; then
        echo "extract-libs: missing in APK: $so" >&2
        fail=$((fail+1))
        continue
    fi
    expect="$(jq -r --arg arch "$ARCH" --arg so "$so" '.libs[$arch][$so]' "$LIBS_VERSION" | tr -d '\r')"
    actual="$(sha256sum "$src" | awk '{print $1}')"
    if [[ "$expect" != "$actual" ]]; then
        echo "extract-libs: SHA-256 mismatch on $so" >&2
        echo "  expected: $expect" >&2
        echo "  actual:   $actual" >&2
        fail=$((fail+1))
        continue
    fi
    install -m 0644 "$src" "$OUT/$so"
    ok=$((ok+1))
done

echo "extract-libs: $ok ok, $fail failed (arch=$ARCH out=$OUT)"
[[ $fail -eq 0 ]]
