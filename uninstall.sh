#!/bin/sh
set -eu

prefix_given=${PREFIX+yes}
PREFIX=${PREFIX:-/usr/local/sbin}
DEST=${DEST-}
ALIAS=${ALIAS-qc}
DRY_RUN=${DRY_RUN-}

fail() {
    echo "uninstall.sh: $1" >&2
    exit 1
}

# True when the file is the QuietClaude launcher. Claude Code's own claude must never match.
# It looks for a name only the launcher contains, so nothing is run.
is_quietclaude() {
    [ -f "$1" ] && grep -a -q QUIETCLAUDE_CLAUDE_PATH "$1" 2>/dev/null
}

# Where the symlink at $1 points, as an absolute path.
link_target() {
    target=$(readlink "$1") || return 1
    case $target in
        /*) printf '%s\n' "$target" ;;
        *) printf '%s/%s\n' "$(dirname "$1")" "$target" ;;
    esac
}

if [ -z "$DEST" ]; then
    DEST=$PREFIX/claude
    found=
    if [ -z "$prefix_given" ]; then
        found=$(command -v "${ALIAS:-qc}" 2>/dev/null || true)
    fi
    if [ -n "$found" ] && [ -L "$found" ]; then
        resolved=$(link_target "$found" || true)
        if [ -n "$resolved" ] && is_quietclaude "$resolved"; then
            DEST=$resolved
        fi
    fi
fi

dest_dir=$(dirname "$DEST")
alias_path=
if [ -n "$ALIAS" ]; then
    case $ALIAS in
        */*) alias_path=$ALIAS ;;
        *) alias_path=$dest_dir/$ALIAS ;;
    esac
fi

remove_launcher=
remove_alias=
if [ -e "$DEST" ] || [ -L "$DEST" ]; then
    if is_quietclaude "$DEST"; then
        remove_launcher=1
    else
        echo "$DEST is not QuietClaude, so it was left alone."
        refused=1
    fi
fi
if [ -n "$alias_path" ] && [ -L "$alias_path" ]; then
    if [ "$(link_target "$alias_path" || true)" = "$DEST" ] && { [ -n "$remove_launcher" ] || [ ! -e "$DEST" ]; }; then
        remove_alias=1
    else
        echo "$alias_path was left alone because it is not a QuietClaude link."
    fi
fi

if [ -z "$remove_launcher" ] && [ -z "$remove_alias" ]; then
    if [ -n "${refused-}" ]; then
        exit 1
    fi
    echo "Nothing to remove: no QuietClaude launcher at $DEST."
    exit 0
fi

if [ -z "$DRY_RUN" ]; then
    if [ -w "$dest_dir" ]; then
        run() { "$@"; }
    elif command -v sudo >/dev/null 2>&1; then
        echo "$dest_dir is not writable; the removal will use sudo."
        run() { sudo "$@"; }
    else
        fail "$dest_dir is not writable; run this as a user who can write there."
    fi
fi

if [ -n "$remove_alias" ]; then
    if [ -n "$DRY_RUN" ]; then
        echo "Would remove $alias_path"
    else
        run rm -f "$alias_path"
        echo "Removed $alias_path"
    fi
fi
if [ -n "$remove_launcher" ]; then
    if [ -n "$DRY_RUN" ]; then
        echo "Would remove $DEST"
    else
        run rm -f "$DEST"
        echo "Removed $DEST"
    fi
fi

if [ -n "$DRY_RUN" ]; then
    echo "Dry run: nothing was changed."
    exit 0
fi

echo "The name claude goes back to Claude Code. Run 'hash -r' or open a new terminal."
echo "If you added an alias for claude to your shell profile, remove that line too."
if [ -n "${HOME-}" ] && [ -d "$HOME/.quietclaude" ]; then
    echo "Left alone: $HOME/.quietclaude (QuietClaude Pro: licence, profiles and sync files)."
    echo "Delete it yourself if you no longer want it: rm -rf $HOME/.quietclaude"
fi
