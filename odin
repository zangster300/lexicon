#!/usr/bin/env bash

# usage:
#   odin             install odin
#   odin -ols        install odin, then ols + odinfmt
#   odin -skip -ols  install ols + odinfmt only
#   odin -f, -force  reinstall odin even if VERSION is present
#
# sources:
#   https://github.com/odin-lang/Odin/releases
#   https://odin-lang.org/docs/nightly/
#   https://github.com/DanielGavin/ols

set -euo pipefail

# ---- config ---------------------------------------------------------------

VERSION="dev-2026-09"
ARCH="${ARCH:-arm64}"
case "$(uname -s)" in
Darwin) OS="macos" ;;
Linux) OS="linux" ;;
*) OS="$(uname -s)" ;;
esac

INSTALL_PATH="${INSTALL_PATH:-/usr/local/odin}"
ODINBIN="${ODINBIN:-$HOME/.local/share/odin/bin}"
URL="${URL:-https://github.com/odin-lang/Odin/releases/download/$VERSION/odin-$OS-$ARCH-$VERSION.tar.gz}"
OLS_REPO="https://github.com/DanielGavin/ols.git"

checksum_for() {
    case "$OS-$ARCH" in
    macos-arm64) echo 3e6cbc1f247d8d14fe02c3151272d0a5b8d6d77acb7219f5b62914e4d95d97f7 ;;
    linux-arm64) echo c150c6f2d13668f3a1c4116ef96ea85c1ba1c9ededfd76081cd3c7d4ba92aa91 ;;
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

# ---- odin steps -----------------------------------------------------------

check_prereqs() {
    command -v sudo >/dev/null || die "sudo required"
    command -v curl >/dev/null || die "curl required"
}

already_installed() {
    [ -x "$INSTALL_PATH/odin" ] &&
        "$INSTALL_PATH/odin" version 2>/dev/null | grep -q "$VERSION"
}

download() {
    step "downloading $URL"
    curl -fsSL --retry 3 -o "$TARBALL" "$URL"
}

verify() {
    step "verifying checksum"
    local expected actual
    expected="${CHECKSUM:-$(checksum_for)}"
    expected="${expected#sha256:}"
    actual="$(sha256 "$TARBALL")"
    [ "$actual" = "$expected" ] || die "checksum mismatch
  expected $expected
  actual   $actual"
}

extract() {
    step "extracting"
    mkdir "$WORK_DIR/odin"
    sudo tar -xzf "$TARBALL" -C "$WORK_DIR/odin" --strip-components=1
    [ -x "$WORK_DIR/odin/odin" ] || die "archive did not contain odin binary"
}

install() {
    step "installing to $INSTALL_PATH"
    sudo rm -rf "$INSTALL_PATH"
    sudo mkdir -p "$(dirname "$INSTALL_PATH")"
    sudo mv "$WORK_DIR/odin" "$INSTALL_PATH"
}

set_path() {
    case "$OS" in
    macos)
        step "writing /etc/paths.d/odin"
        echo "$INSTALL_PATH" | sudo tee /etc/paths.d/odin >/dev/null
        ;;
    linux)
        step "add to PATH: $INSTALL_PATH"
        ;;
    esac
}

install_odin() {
    if ! "$force" && already_installed; then
        step "$VERSION already installed at $INSTALL_PATH"
        return
    fi
    download
    verify
    extract
    install
    set_path
}

# ---- ols steps ------------------------------------------------------------

install_ols() {
    command -v git >/dev/null || die "git required"
    export PATH="$INSTALL_PATH:$PATH"
    command -v odin >/dev/null || die "odin not found on PATH"

    step "cloning ols"
    git clone -q --depth 1 "$OLS_REPO" "$WORK_DIR/ols"

    step "patching ols defaults:"
    step "  - setting multiline_composite_literals to true"
    local printer="$WORK_DIR/ols/src/odin/printer/printer.odin"
    grep -q 'multiline_composite_literals = false' "$printer" || die "expected default not found in $printer"
    sed -i.bak 's/multiline_composite_literals = false/multiline_composite_literals = true/g' "$printer"
    rm -f "$printer.bak"

    step "building ols and odinfmt"
    (cd "$WORK_DIR/ols" && ./build.sh && ./odinfmt.sh)

    step "installing to $ODINBIN"
    mkdir -p "$ODINBIN"
    mv "$WORK_DIR/ols/ols" "$WORK_DIR/ols/odinfmt" "$ODINBIN"

    step "add to PATH: $ODINBIN"
}

# ---- main -----------------------------------------------------------------

do_odin=true
do_ols=false
force=false
for arg in "$@"; do
    case "$arg" in
    -skip) do_odin=false ;;
    -ols) do_ols=true ;;
    -f | -force) force=true ;;
    *) die "unknown flag $arg" ;;
    esac
done

check_prereqs
"$do_odin" && install_odin
"$do_ols" && install_ols

step "done"
