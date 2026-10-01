#!/usr/bin/env bash

# usage:
#   odin             install odin
#   odin -ols        install odin, then ols + odinfmt
#   odin -skip -ols  install ols + odinfmt only
#   odin -f, -force  reinstall odin even if VERSION is present
#   odin -nightly    install the latest nightly instead of a release
#
# env:
#   VERSION   release tag, e.g. dev-2026-09, blank for latest release
#   CHECKSUM  sha256, blank to look up for VERSION
#   URL       archive url, blank for github releases
#
# sources:
#   https://github.com/odin-lang/Odin/releases
#   https://odin-lang.org/docs/nightly/
#   https://github.com/DanielGavin/ols

set -euo pipefail

# ---- config ---------------------------------------------------------------

VERSION="${VERSION:-}"
CHECKSUM="${CHECKSUM:-}"
ARCH="${ARCH:-arm64}"
case "$(uname -s)" in
Darwin) OS="macos" ;;
Linux) OS="linux" ;;
*) OS="$(uname -s)" ;;
esac

INSTALL_PATH="${INSTALL_PATH:-/opt/odin}"
BIN_PATH="${BIN_PATH:-/usr/local/bin}"
ODINBIN="${ODINBIN:-$HOME/.local/share/odin/bin}"
URL="${URL:-}"
RELEASES_API="${RELEASES_API:-https://api.github.com/repos/odin-lang/Odin/releases}"
NIGHTLY_JSON="${NIGHTLY_JSON:-https://odinbinaries.thisdrunkdane.io/file/odin-binaries/nightly.json}"
HASH="sha256"
OLS_REPO="https://github.com/DanielGavin/ols.git"

# ---- helpers --------------------------------------------------------------

step() { printf "==> %s\n" "$*"; }
die() {
  printf "error: %s\n" "$*" >&2
  exit 1
}

# digest sha256|sha1 file
digest() {
  if command -v "${1}sum" >/dev/null; then
    "${1}sum" "$2"
  else
    shasum -a "${1#sha}" "$2"
  fi | awk '{print $1}'
}

WORK_DIR="$(mktemp -d)"
trap 'sudo rm -rf "$WORK_DIR"' EXIT

# ---- odin steps -----------------------------------------------------------

check_prereqs() {
  command -v sudo >/dev/null || die "sudo required"
  command -v curl >/dev/null || die "curl required"
}

# newest build for OS-ARCH; sets VERSION, URL, TARBALL, CHECKSUM
resolve_nightly() {
  command -v jq >/dev/null || die "jq required for -nightly"
  step "resolving latest nightly for $OS-$ARCH"
  local entry name
  entry="$(curl -fsSL --retry 3 "$NIGHTLY_JSON" | jq -er --arg p "odin-$OS-$ARCH-nightly+" '
    [.files | to_entries | sort_by(.key) | reverse[] | .value[]
      | select((.name | startswith($p)) and (.name | endswith(".tar.gz")))]
    | first // empty | [.name, .url, .sha1] | @tsv')" ||
    die "no nightly found for $OS-$ARCH"
  IFS=$'\t' read -r name URL CHECKSUM <<<"$entry"
  [ -n "$CHECKSUM" ] && [ "$CHECKSUM" != none ] || die "nightly $name has no checksum"
  VERSION="${name#odin-$OS-$ARCH-}"
  VERSION="${VERSION%.tar.gz}"
  TARBALL="$WORK_DIR/$name"
  HASH="sha1"
}

# fills blank VERSION/CHECKSUM from github
lookup() {
  command -v jq >/dev/null || die "jq required unless VERSION and CHECKSUM are set"
  step "resolving ${VERSION:-latest} for $OS-$ARCH"
  local api="$RELEASES_API/latest" entry sum
  [ -z "$VERSION" ] || api="$RELEASES_API/tags/$VERSION"
  entry="$(curl -fsSL --retry 3 "$api" | jq -er --arg os "$OS" --arg arch "$ARCH" '
    .tag_name as $t | .assets[] | select(.name == "odin-\($os)-\($arch)-\($t).tar.gz")
    | [$t, .digest // "none"] | @tsv')" ||
    die "no ${VERSION:-release} found for $OS-$ARCH"
  IFS=$'\t' read -r VERSION sum <<<"$entry"
  [ "$sum" != none ] || [ -n "$CHECKSUM" ] || die "$VERSION has no checksum, set CHECKSUM"
  CHECKSUM="${CHECKSUM:-$sum}"
}

resolve() {
  if "$nightly"; then
    resolve_nightly
    return
  fi
  [ -n "$VERSION" ] && [ -n "$CHECKSUM" ] || lookup
  URL="${URL:-https://github.com/odin-lang/Odin/releases/download/$VERSION/odin-$OS-$ARCH-$VERSION.tar.gz}"
  TARBALL="$WORK_DIR/${URL##*/}"
}

# nightly version output lacks the build date, so nightlies leave a marker
already_installed() {
  [ -x "$INSTALL_PATH/odin" ] || return 1
  if "$nightly"; then
    [ "$(cat "$INSTALL_PATH/.nightly" 2>/dev/null)" = "$VERSION" ]
  else
    [ ! -e "$INSTALL_PATH/.nightly" ] &&
      "$INSTALL_PATH/odin" version 2>/dev/null | grep -q "$VERSION"
  fi
}

download() {
  step "downloading $URL"
  curl -fsSL --retry 3 -o "$TARBALL" "$URL"
}

verify() {
  step "verifying $HASH checksum"
  local expected actual
  expected="$CHECKSUM"
  expected="${expected#"$HASH":}"
  actual="$(digest "$HASH" "$TARBALL")"
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
  sudo chown -R 0:0 "$INSTALL_PATH"
  if "$nightly"; then
    printf '%s\n' "$VERSION" | sudo tee "$INSTALL_PATH/.nightly" >/dev/null
  fi
}

link() {
  step "linking into $BIN_PATH"
  sudo mkdir -p "$BIN_PATH"
  sudo ln -sfn "$INSTALL_PATH/odin" "$BIN_PATH/odin"
}

install_odin() {
  resolve
  if ! "$force" && already_installed; then
    step "$VERSION already installed at $INSTALL_PATH"
    return
  fi
  download
  verify
  extract
  install
  link
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

  step "installing ols and odinfmt to $ODINBIN"
  mkdir -p "$ODINBIN"
  mv "$WORK_DIR/ols/ols" "$WORK_DIR/ols/odinfmt" "$ODINBIN"

  step "add to PATH: $ODINBIN"
}

# ---- main -----------------------------------------------------------------

do_odin=true
do_ols=false
force=false
nightly=false
for arg in "$@"; do
  case "$arg" in
  -skip) do_odin=false ;;
  -ols) do_ols=true ;;
  -f | -force) force=true ;;
  -nightly) nightly=true ;;
  *) die "unknown flag $arg" ;;
  esac
done
! { "$nightly" && [ -n "$VERSION" ]; } || die "-nightly and VERSION are exclusive"

check_prereqs
"$do_odin" && install_odin
"$do_ols" && install_ols

step "done"
