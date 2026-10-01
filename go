#!/usr/bin/env bash

# usage:
#   go             install go
#   go -f, -force  reinstall even if VERSION is present
#
# env:
#   VERSION   e.g. go1.27.1, blank for latest stable
#   CHECKSUM  sha256, blank to look up for VERSION
#   URL       archive url, blank for go.dev/dl
#
# sources:
#   https://go.dev/dl

set -euo pipefail

# ---- config ---------------------------------------------------------------

VERSION="${VERSION:-}"
CHECKSUM="${CHECKSUM:-}"
ARCH="${ARCH:-arm64}"
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"

INSTALL_PATH="${INSTALL_PATH:-/opt/go}"
BIN_PATH="${BIN_PATH:-/usr/local/bin}"
URL="${URL:-}"
RELEASES_JSON="${RELEASES_JSON:-https://go.dev/dl/?mode=json}"

# accept 1.27.1 as go1.27.1
[ -z "$VERSION" ] || [[ "$VERSION" == go* ]] || VERSION="go$VERSION"

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

# fills blank VERSION/CHECKSUM from go.dev
lookup() {
  command -v jq >/dev/null || die "jq required unless VERSION and CHECKSUM are set"
  step "resolving ${VERSION:-latest} for $OS-$ARCH"
  local json="$RELEASES_JSON" entry sum
  [ -z "$VERSION" ] || json="$json&include=all"
  entry="$(curl -fsSL --retry 3 "$json" | jq -er --arg v "$VERSION" --arg os "$OS" --arg arch "$ARCH" '
    [.[] | select(if $v == "" then .stable else .version == $v end)] | first // empty | .files[]
    | select(.kind == "archive" and .os == $os and .arch == $arch)
    | [.version, .sha256] | @tsv')" ||
    die "no ${VERSION:-release} found for $OS-$ARCH"
  IFS=$'\t' read -r VERSION sum <<<"$entry"
  CHECKSUM="${CHECKSUM:-$sum}"
}

resolve() {
  [ -n "$VERSION" ] && [ -n "$CHECKSUM" ] || lookup
  URL="${URL:-https://go.dev/dl/$VERSION.$OS-$ARCH.tar.gz}"
  TARBALL="$WORK_DIR/${URL##*/}"
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
  expected="$CHECKSUM"
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
  sudo chown -R 0:0 "$INSTALL_PATH"
}

link() {
  step "linking into $BIN_PATH"
  sudo mkdir -p "$BIN_PATH"
  sudo ln -sfn "$INSTALL_PATH/bin/go" "$BIN_PATH/go"
  sudo ln -sfn "$INSTALL_PATH/bin/gofmt" "$BIN_PATH/gofmt"
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
