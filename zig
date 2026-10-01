#!/usr/bin/env bash

# usage:
#   zig             install zig
#   zig -f, -force  reinstall even if VERSION is present
#
# env:
#   VERSION   e.g. 0.17.0 or a -dev build, blank for latest stable
#   CHECKSUM  sha256, only used without minisign, blank to look up for VERSION
#   URL       archive url, blank for ziglang.org
#
# sources:
#   https://ziglang.org/builds/
#   https://ziglang.org/download/index.json

set -euo pipefail

# ---- config ---------------------------------------------------------------

VERSION="${VERSION:-}"
CHECKSUM="${CHECKSUM:-}"
ARCH="${ARCH:-aarch64}"
case "$(uname -s)" in
Darwin) OS="macos" ;;
Linux) OS="linux" ;;
*) OS="$(uname -s)" ;;
esac

INSTALL_PATH="${INSTALL_PATH:-/opt/zig}"
BIN_PATH="${BIN_PATH:-/usr/local/bin}"
URL="${URL:-}"
MINISIG_URL="${MINISIG_URL:-}"
INDEX_JSON="${INDEX_JSON:-https://ziglang.org/download/index.json}"
ZIG_PUBKEY="RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U"

# ---- helpers --------------------------------------------------------------

step() { printf "==> %s\n" "$*"; }
die() {
  printf "error: %s\n" "$*" >&2
  exit 1
}

sha256() {
  if command -v sha256sum >/dev/null; then
    sha256sum "$1"
  else
    shasum -a 256 "$1"
  fi | awk '{print $1}'
}

WORK_DIR="$(mktemp -d)"
trap 'sudo rm -rf "$WORK_DIR"' EXIT

# ---- steps ----------------------------------------------------------------

check_prereqs() {
  command -v sudo >/dev/null || die "sudo required"
  command -v curl >/dev/null || die "curl required"
}

# fills blank VERSION/URL/CHECKSUM from the index; tagged releases only
lookup() {
  command -v jq >/dev/null || die "jq required unless VERSION is set and minisign or CHECKSUM is available"
  step "resolving ${VERSION:-latest} for $ARCH-$OS"
  local entry tarball sum
  entry="$(curl -fsSL --retry 3 "$INDEX_JSON" | jq -er --arg v "$VERSION" --arg t "$ARCH-$OS" '
    [to_entries[] | select(.key | test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))]
    | sort_by(.key | split(".") | map(tonumber))
    | (if $v == "" then last else .[] | select(.key == $v) end) // empty
    | [.key, .value[$t].tarball // "none", .value[$t].shasum // "none"] | @tsv')" ||
    die "${VERSION:-release} not in index, install minisign or set CHECKSUM"
  IFS=$'\t' read -r VERSION tarball sum <<<"$entry"
  [ "$tarball" != none ] || die "no $VERSION build for $ARCH-$OS"
  URL="${URL:-$tarball}"
  CHECKSUM="${CHECKSUM:-$sum}"
}

resolve() {
  if [ -z "$VERSION" ] || { [ -z "$CHECKSUM" ] && ! command -v minisign >/dev/null; }; then
    lookup
  fi
  case "$VERSION" in
  *-dev.*) URL="${URL:-https://ziglang.org/builds/zig-$ARCH-$OS-$VERSION.tar.xz}" ;;
  *) URL="${URL:-https://ziglang.org/download/$VERSION/zig-$ARCH-$OS-$VERSION.tar.xz}" ;;
  esac
  MINISIG_URL="${MINISIG_URL:-$URL.minisig}"
  TARBALL="$WORK_DIR/${URL##*/}"
  MINISIG="$TARBALL.minisig"
}

already_installed() {
  [ -x "$INSTALL_PATH/zig" ] &&
    [ "$("$INSTALL_PATH/zig" version 2>/dev/null)" = "$VERSION" ]
}

download() {
  step "downloading $URL"
  curl -fsSL --retry 3 -o "$TARBALL" "$URL"
}

verify() {
  if command -v minisign >/dev/null; then
    step "verifying signature"
    curl -fsSL --retry 3 -o "$MINISIG" "$MINISIG_URL"
    minisign -Vqm "$TARBALL" -x "$MINISIG" -P "$ZIG_PUBKEY" || die "invalid signature"
    return
  fi

  step "verifying checksum"
  local expected actual
  expected="$CHECKSUM"
  actual="$(sha256 "$TARBALL")"
  [ "$actual" = "$expected" ] || die "checksum mismatch
  expected $expected
  actual   $actual"
}

extract() {
  step "extracting"
  mkdir "$WORK_DIR/zig"
  sudo tar -xJf "$TARBALL" -C "$WORK_DIR/zig" --strip-components=1
  [ -x "$WORK_DIR/zig/zig" ] || die "archive did not contain zig binary"
}

install() {
  step "installing to $INSTALL_PATH"
  sudo rm -rf "$INSTALL_PATH"
  sudo mkdir -p "$(dirname "$INSTALL_PATH")"
  sudo mv "$WORK_DIR/zig" "$INSTALL_PATH"
  sudo chown -R 0:0 "$INSTALL_PATH"
}

link() {
  step "linking into $BIN_PATH"
  sudo mkdir -p "$BIN_PATH"
  sudo ln -sfn "$INSTALL_PATH/zig" "$BIN_PATH/zig"
}

# ---- main -----------------------------------------------------------------

force=false
for arg in "$@"; do
  case "$arg" in
  -f | -force) force=true ;;
  *) die "unknown flag $arg" ;;
  esac
done

check_prereqs
resolve

if ! "$force" && already_installed; then
  step "$VERSION already installed at $INSTALL_PATH"
  exit 0
fi

download
verify
extract
install
link

step "done: $VERSION at $INSTALL_PATH"
