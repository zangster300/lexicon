#!/usr/bin/env bash

# usage:
#   go             install go
#   go -f, -force  reinstall even if VERSION is present
#
# sources:
#   https://go.dev/dl

set -euo pipefail

# ---- config ---------------------------------------------------------------

VERSION="go1.27.1"
ARCH="${ARCH:-arm64}"
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"

INSTALL_PATH="${INSTALL_PATH:-/usr/local/go}"
URL="${URL:-https://go.dev/dl/$VERSION.$OS-$ARCH.tar.gz}"

checksum_for() {
    case "$OS-$ARCH" in
    darwin-arm64) echo ee215d57e0ec269c60cc9ceca68e6bda321ba9ee5afe24f4b0988703c2d87d12 ;;
    linux-arm64) echo 3450b45a3f9ee8568792736a5c5e70a1f2e9b36c35a8f74958c03e51d7d92bec ;;
    *) die "no checksum for $OS-$ARCH, set CHECKSUM" ;;
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
trap 'sudo rm -rf "$WORK_DIR"' EXIT

# ---- steps ----------------------------------------------------------------

check_prereqs() {
    command -v sudo >/dev/null || die "sudo required"
    command -v curl >/dev/null || die "curl required"
}

already_installed() {
    [ -x "$INSTALL_PATH/bin/go" ] &&
        "$INSTALL_PATH/bin/go" version 2>/dev/null | grep -q " $VERSION "
}

download() {
    step "downloading $URL"
    curl -fsSL --retry 3 -o "$TARBALL" "$URL"
}

verify() {
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
    sudo tar -xzf "$TARBALL" -C "$WORK_DIR"
    [ -d "$WORK_DIR/go" ] || die "archive did not contain go/"
}

install() {
    step "installing to $INSTALL_PATH"
    sudo rm -rf "$INSTALL_PATH"
    sudo mkdir -p "$(dirname "$INSTALL_PATH")"
    sudo mv "$WORK_DIR/go" "$INSTALL_PATH"
}

set_path() {
    case "$OS" in
    darwin)
        step "writing /etc/paths.d/go"
        echo "$INSTALL_PATH/bin" | sudo tee /etc/paths.d/go >/dev/null
        ;;
    linux)
        step "add to PATH: $INSTALL_PATH/bin"
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
