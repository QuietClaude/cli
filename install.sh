#!/bin/sh
set -eu

PREFIX=${PREFIX:-/usr/local/sbin}
DEST=${DEST:-$PREFIX/claude}
ALIAS=${ALIAS-qc}
SOURCE=${SOURCE:-./qc}

if [ ! -f "$SOURCE" ]; then
    echo "install.sh: $SOURCE is not built; run 'make' first." >&2
    exit 1
fi
if [ ! -x "$SOURCE" ]; then
    echo "install.sh: $SOURCE is not executable; run 'make' first." >&2
    exit 1
fi

dest_dir=$(dirname "$DEST")
mkdir -p "$dest_dir"
cp "$SOURCE" "$DEST.tmp.$$"
chmod 0755 "$DEST.tmp.$$"
mv -f "$DEST.tmp.$$" "$DEST"
echo "launcher: $DEST"

if [ -n "$ALIAS" ]; then
    case $ALIAS in
        */*) alias_path=$ALIAS ;;
        *) alias_path=$dest_dir/$ALIAS ;;
    esac
    rm -f "$alias_path"
    ln -s "$DEST" "$alias_path"
    echo "alias:    $alias_path"
fi

echo "Reminder: $dest_dir must precede Claude Code's own claude in PATH,"
echo "or add an alias such as: alias claude='$DEST'"
