#!/usr/bin/env bash

# usage:
#   zig             install zig
#   zig -f, -force  reinstall even if VERSION is present
#
# sources:
#   https://ziglang.org/builds/
#   https://ziglang.org/download/index.json

set -euo pipefail

# ---- config ---------------------------------------------------------------

VERSION="0.17.0-dev.2085+5e36170b5"
ARCH="${ARCH:-aarch64}"
case "$(uname -s)" in
Darwin) OS="macos" ;;
Linux) OS="linux" ;;
*) OS="$(uname -s)" ;;
esac

INSTALL_PATH="${INSTALL_PATH:-/usr/local/zig}"
URL="${URL:-https://ziglang.org/builds/zig-$ARCH-$OS-$VERSION.tar.xz}"
MINISIG_URL="${MINISIG_URL:-$URL.minisig}"
ZIG_PUBKEY="RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U"

checksum_for() {
    case "$OS-$ARCH" in
    *) die "no checksum for $OS-$ARCH, install minisign or set CHECKSUM" ;;
    esac
}

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
TARBALL="$WORK_DIR/${URL##*/}"
MINISIG="$TARBALL.minisig"
trap 'sudo rm -rf "$WORK_DIR"' EXIT

# ---- steps ----------------------------------------------------------------

check_prereqs() {
    command -v sudo >/dev/null || die "sudo required"
    command -v curl >/dev/null || die "curl required"
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
    expected="${CHECKSUM:-$(checksum_for)}"
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
}

set_path() {
    case "$OS" in
    macos)
        step "writing /etc/paths.d/zig"
        echo "$INSTALL_PATH" | sudo tee /etc/paths.d/zig >/dev/null
        ;;
    linux)
        step "add to PATH: $INSTALL_PATH"
        ;;
    esac
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

if ! "$force" && already_installed; then
    step "$VERSION already installed at $INSTALL_PATH"
    exit 0
fi

download
verify
extract
install
set_path

step "done: $VERSION at $INSTALL_PATH"
