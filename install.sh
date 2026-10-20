#!/bin/sh
set -eu

PREFIX=${PREFIX:-/usr/local/sbin}
DEST=${DEST:-$PREFIX/claude}
ALIAS=${ALIAS-qc}
SOURCE=${SOURCE-}
VERSION=${VERSION-}
BASE=${QUIETCLAUDE_RELEASE_BASE:-https://github.com/QuietClaude/cli}

tmp=
cleanup() {
    if [ -n "$tmp" ]; then
        rm -rf "$tmp"
    fi
}
trap cleanup EXIT INT TERM HUP

fail() {
    echo "install.sh: $1" >&2
    exit 1
}

if [ -z "$SOURCE" ] && [ -x ./qc ]; then
    SOURCE=./qc
fi

if [ -n "$SOURCE" ]; then
    if [ ! -f "$SOURCE" ]; then
        fail "$SOURCE is not built; run 'make' first."
    fi
    if [ ! -x "$SOURCE" ]; then
        fail "$SOURCE is not executable; run 'make' first."
    fi
else
    os=$(uname -s)
    arch=$(uname -m)
    case "$os/$arch" in
        Linux/x86_64) asset=quietclaude-linux-x86_64 ;;
        Linux/aarch64) asset=quietclaude-linux-arm64 ;;
        Darwin/x86_64) asset=quietclaude-darwin-x86_64 ;;
        Darwin/arm64) asset=quietclaude-darwin-arm64 ;;
        *) fail "no release is built for $os/$arch." ;;
    esac
    if [ -n "$VERSION" ]; then
        url=$BASE/releases/download/$VERSION
    else
        url=$BASE/releases/latest/download
    fi
    if command -v curl >/dev/null 2>&1; then
        fetch() { curl -fsSL -o "$2" "$1"; }
    elif command -v wget >/dev/null 2>&1; then
        fetch() { wget -qO "$2" "$1"; }
    else
        fail "curl or wget is needed to download QuietClaude."
    fi
    if command -v sha256sum >/dev/null 2>&1; then
        digest() { sha256sum "$1" | awk '{print $1}'; }
    elif command -v shasum >/dev/null 2>&1; then
        digest() { shasum -a 256 "$1" | awk '{print $1}'; }
    else
        fail "sha256sum or shasum is needed to verify the download."
    fi
    tmp=$(mktemp -d)
    fetch "$url/$asset" "$tmp/$asset" || fail "download failed: $url/$asset"
    fetch "$url/SHA256SUMS" "$tmp/SHA256SUMS" || fail "download failed: $url/SHA256SUMS"
    expected=$(awk -v name="$asset" '{ n = $2; sub(/^\*/, "", n); if (n == name) { print $1; exit } }' "$tmp/SHA256SUMS")
    if [ -z "$expected" ]; then
        fail "SHA256SUMS has no entry for $asset."
    fi
    actual=$(digest "$tmp/$asset")
    if [ "$actual" != "$expected" ]; then
        echo "install.sh: checksum mismatch for $asset; nothing was installed." >&2
        echo "expected $expected" >&2
        echo "actual   $actual" >&2
        exit 1
    fi
    SOURCE=$tmp/$asset
fi

dest_dir=$(dirname "$DEST")
if [ ! -d "$dest_dir" ]; then
    mkdir -p "$dest_dir" 2>/dev/null || true
fi
if [ -d "$dest_dir" ] && [ -w "$dest_dir" ]; then
    run() { "$@"; }
elif command -v sudo >/dev/null 2>&1; then
    echo "$dest_dir is not writable; the copy will use sudo."
    run() { sudo "$@"; }
else
    fail "$dest_dir is not writable; set PREFIX to a writable directory."
fi

if [ ! -d "$dest_dir" ]; then
    run install -d "$dest_dir"
fi
run install -m 0755 "$SOURCE" "$DEST"

if [ -n "$ALIAS" ]; then
    case $ALIAS in
        */*) alias_path=$ALIAS ;;
        *) alias_path=$dest_dir/$ALIAS ;;
    esac
    run ln -sf "$DEST" "$alias_path"
fi

installed=$("$DEST" --version | head -n 1)
echo "$installed installed at $DEST"

if [ "$(command -v claude 2>/dev/null || true)" != "$DEST" ]; then
    echo "Reminder: $dest_dir must precede Claude Code's own claude in PATH,"
    echo "or add an alias such as: alias claude='$DEST'"
fi
