#!/bin/sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPLAY=${REPLAY:-"$HERE/replay"}
fail=0
pass=0

check() {
    name=$1
    expected=$2
    shift 2
    out=$(mktemp "${TMPDIR:-/tmp}/qc-replay.XXXXXX") || exit 1
    if "$REPLAY" "$@" > "$out" 2>/dev/null && cmp -s "$out" "$expected"; then
        pass=$((pass + 1))
        printf 'ok   %s\n' "$name"
    else
        fail=$((fail + 1))
        printf 'FAIL %s (%s)\n' "$name" "$*"
    fi
    rm -f "$out"
}

for fixture in "$HERE"/fixtures/*.bin; do
    base=$(basename "$fixture")
    expected="$HERE/expected/$base"
    [ -f "$expected" ] || { printf 'FAIL %s: no expected output\n' "$base"; fail=$((fail + 1)); continue; }
    case $base in
        settings-dialog-*) event="--key-after 1427" ;;
        resize-*) event="--resize-after 1676" ;;
        *) event="" ;;
    esac
    check "$base whole" "$expected" $event "$fixture"
    check "$base 1-byte" "$expected" $event --chunk 1 "$fixture"
done

check "settings-dialog timeout without keystroke" "$HERE/fixtures/settings-dialog-2.1.304.bin" \
    --key-after 1427 --event-time 0 --after-time 5100 "$HERE/fixtures/settings-dialog-2.1.304.bin"
check "resize redraw not removed after keystroke only" "$HERE/expected/resize-2.1.304.keystroke-only.bin" \
    --key-after 1676 --chunk 1 "$HERE/fixtures/resize-2.1.304.bin"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
