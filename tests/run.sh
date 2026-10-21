#!/bin/sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
REPLAY=${REPLAY:-"$HERE/replay"}
QC=${QC:-"$ROOT/qc"}
fail=0
pass=0

ok() {
    pass=$((pass + 1))
    printf 'ok   %s\n' "$1"
}

bad() {
    fail=$((fail + 1))
    printf 'FAIL %s\n' "$1"
}

check() {
    name=$1
    expected=$2
    shift 2
    out=$(mktemp "${TMPDIR:-/tmp}/qc-replay.XXXXXX") || exit 1
    if "$REPLAY" "$@" > "$out" 2>/dev/null && cmp -s "$out" "$expected"; then
        ok "$name"
    else
        bad "$name ($*)"
    fi
    rm -f "$out"
}

for fixture in "$HERE"/fixtures/*.bin; do
    base=$(basename "$fixture")
    expected="$HERE/expected/$base"
    [ -f "$expected" ] || { bad "$base: no expected output"; continue; }
    if [ -d "$ROOT/spec/fixtures" ]; then
        cmp -s "$fixture" "$ROOT/spec/fixtures/$base" || bad "$base differs from spec/fixtures"
    fi
    case $base in
        settings-dialog-*) flag=--key-after; at=1427 ;;
        resize-*) flag=--resize-after; at=1676 ;;
        *) flag=""; at="" ;;
    esac
    check "$base whole" "$expected" ${flag:+"$flag" "$at"} "$fixture"
    check "$base 1-byte" "$expected" ${flag:+"$flag" "$at"} --chunk 1 "$fixture"
done

check "settings-dialog timeout without keystroke" "$HERE/fixtures/settings-dialog-2.1.304.bin" \
    --key-after 1427 --event-time 0 --after-time 5100 "$HERE/fixtures/settings-dialog-2.1.304.bin"
check "resize redraw not removed after keystroke only" "$HERE/expected/resize-2.1.304.keystroke-only.bin" \
    --key-after 1676 --chunk 1 "$HERE/fixtures/resize-2.1.304.bin"
check "header inserted where the banner was" "$HERE/expected/banner-2.1.304.header.bin" \
    --header 'work · test' "$HERE/fixtures/banner-2.1.304.bin"
check "header inserted where the banner was, 1-byte" "$HERE/expected/banner-2.1.304.header.bin" \
    --header 'work · test' --chunk 1 "$HERE/fixtures/banner-2.1.304.bin"
check "header written once across a resize redraw" "$HERE/expected/resize-2.1.304.header.bin" \
    --header 'work · test' --resize-after 1676 "$HERE/fixtures/resize-2.1.304.bin"
check "header written once across a resize redraw, 1-byte" "$HERE/expected/resize-2.1.304.header.bin" \
    --header 'work · test' --resize-after 1676 --chunk 1 "$HERE/fixtures/resize-2.1.304.bin"
check "header_fn result written from the removed bytes" "$HERE/expected/banner-2.1.304.headerfn.bin" \
    --header-fn --chunk 1 "$HERE/fixtures/banner-2.1.304.bin"

W=$(mktemp -d "${TMPDIR:-/tmp}/qc-tests.XXXXXX") || exit 1
server_pid=
cleanup() {
    if [ -n "$server_pid" ]; then
        kill "$server_pid" 2>/dev/null
    fi
    rm -rf "$W"
}
trap cleanup EXIT INT TERM HUP

mkdir -p "$W/bin" "$W/fakebin" "$W/nocurl" "$W/tmp" "$W/home" "$W/links" "$W/local"
export HOME="$W/home"
unset QUIETCLAUDE_PRO_PATH
for tool in sh uname mktemp rm dirname basename awk head install ln mkdir sha256sum shasum curl wget cat chmod grep sed; do
    path=$(command -v "$tool" 2>/dev/null) || continue
    ln -s "$path" "$W/bin/$tool"
    [ "$tool" = curl ] || ln -s "$path" "$W/nocurl/$tool"
done
real_uname=$(command -v uname)
cat > "$W/fakebin/uname" <<SCRIPT
#!/bin/sh
case \${1-} in
    -s) echo "\${FAKE_OS}" ;;
    -m) echo "\${FAKE_ARCH}" ;;
    *) exec "$real_uname" "\$@" ;;
esac
SCRIPT
chmod 755 "$W/fakebin/uname"

for name in quietclaude-linux-x86_64 quietclaude-linux-arm64 quietclaude-darwin-x86_64 quietclaude-darwin-arm64; do
    for dir in "$W/srv/good/releases/latest/download" "$W/srv/good/releases/download/v9.9.9" "$W/srv/bad/releases/latest/download" "$W/srv/nosum/releases/latest/download"; do
        mkdir -p "$dir"
        cat > "$dir/$name" <<'SCRIPT'
#!/bin/sh
case ${1-} in --version) echo "QuietClaude 9.9.9" ;; esac
SCRIPT
        chmod 755 "$dir/$name"
    done
done
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}
(cd "$W/srv/good/releases/latest/download" && for name in quietclaude-*; do printf '%s  %s\n' "$(sha256_of "$name")" "$name"; done > SHA256SUMS)
cp "$W/srv/good/releases/latest/download/SHA256SUMS" "$W/srv/good/releases/download/v9.9.9/SHA256SUMS"
cp "$W/srv/good/releases/latest/download/SHA256SUMS" "$W/srv/bad/releases/latest/download/SHA256SUMS"
echo "echo tampered" >> "$W/srv/bad/releases/latest/download/quietclaude-linux-x86_64"
grep -v quietclaude-linux-x86_64 "$W/srv/good/releases/latest/download/SHA256SUMS" > "$W/srv/nosum/releases/latest/download/SHA256SUMS"

python3 -I "$HERE/release_server.py" "$W/srv" > "$W/server.port" 2> "$W/server.log" &
server_pid=$!
port=
tries=0
while [ -z "$port" ]; do
    first=$(head -n 1 "$W/server.port" 2>/dev/null)
    case $first in
        *[!0-9]*|"") ;;
        *) port=$first ;;
    esac
    if [ -z "$port" ]; then
        tries=$((tries + 1))
        if [ "$tries" -gt 100 ]; then
            bad "release server did not start"
            break
        fi
        sleep 0.1
    fi
done
BASE=http://127.0.0.1:$port
SCRATCH=$W/scratch
mkdir -p "$SCRATCH"

installer() {
    (cd "$SCRATCH" && env -i PATH="$W/fakebin:$W/bin" HOME="$W/home" TMPDIR="$W/tmp" FAKE_OS="${FAKE_OS:-Linux}" FAKE_ARCH="${FAKE_ARCH:-x86_64}" "$@" sh "$ROOT/install.sh")
}

requests() {
    grep -c 'GET ' "$W/server.log"
}

tmp_empty() {
    [ -z "$(ls -A "$W/tmp")" ]
}

out=$(installer PREFIX="$W/p1" QUIETCLAUDE_RELEASE_BASE="$BASE/good" 2>&1)
status=$?
if [ "$status" -eq 0 ] && [ -x "$W/p1/claude" ] && [ "$(readlink "$W/p1/qc")" = "$W/p1/claude" ] \
    && printf '%s\n' "$out" | grep -qx "QuietClaude 9.9.9 installed at $W/p1/claude" && tmp_empty; then
    ok "installer 1: download, link, version line, temp dir removed"
else
    bad "installer 1: $out"
fi

for pair in "Linux aarch64 quietclaude-linux-arm64" "Darwin x86_64 quietclaude-darwin-x86_64" "Darwin arm64 quietclaude-darwin-arm64"; do
    eval "set -- $pair"
    before=$(requests)
    installer PREFIX="$W/p2" QUIETCLAUDE_RELEASE_BASE="$BASE/good" FAKE_OS="$1" FAKE_ARCH="$2" >/dev/null 2>&1
    sleep 0.2
    if [ "$(requests)" -gt "$before" ] && tail -n 4 "$W/server.log" | grep -q "GET /good/releases/latest/download/$3 "; then
        ok "installer 2: $1/$2 requests $3"
    else
        bad "installer 2: $1/$2 did not request $3"
    fi
done

out=$(installer PREFIX="$W/p3" QUIETCLAUDE_RELEASE_BASE="$BASE/good" FAKE_OS=SunOS FAKE_ARCH=sparc 2>&1)
status=$?
if [ "$status" -eq 1 ] && [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq 1 ] && printf '%s' "$out" | grep -q 'SunOS/sparc' && [ ! -e "$W/p3/claude" ]; then
    ok "installer 3: unsupported pair"
else
    bad "installer 3: status $status: $out"
fi

out=$(installer PREFIX="$W/p4" QUIETCLAUDE_RELEASE_BASE="$BASE/bad" 2>&1)
status=$?
if [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q 'mismatch' && printf '%s' "$out" | grep -q '^expected ' \
    && printf '%s' "$out" | grep -q '^actual ' && [ ! -e "$W/p4/claude" ] && tmp_empty; then
    ok "installer 4: tampered asset rejected"
else
    bad "installer 4: status $status: $out"
fi

out=$(installer PREFIX="$W/p5" QUIETCLAUDE_RELEASE_BASE="$BASE/nosum" 2>&1)
status=$?
if [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q 'no entry' && [ ! -e "$W/p5/claude" ]; then
    ok "installer 5: missing SHA256SUMS line"
else
    bad "installer 5: status $status: $out"
fi

mkdir -p "$W/ro"
chmod 555 "$W/ro"
out=$(installer PREFIX="$W/ro" QUIETCLAUDE_RELEASE_BASE="$BASE/good" 2>&1)
status=$?
if [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q 'set PREFIX to a writable directory' && [ ! -e "$W/ro/claude" ]; then
    ok "installer 6: read-only prefix without sudo"
else
    bad "installer 6: status $status: $out"
fi
chmod 755 "$W/ro"

cat > "$W/local/qc" <<'SCRIPT'
#!/bin/sh
case ${1-} in --version) echo "QuietClaude 7.7.7" ;; esac
SCRIPT
chmod 755 "$W/local/qc"
before=$(requests)
out=$(cd "$W/local" && env -i PATH="$W/bin" HOME="$W/home" TMPDIR="$W/tmp" PREFIX="$W/p7" QUIETCLAUDE_RELEASE_BASE="$BASE/good" sh "$ROOT/install.sh" 2>&1)
status=$?
sleep 0.2
if [ "$status" -eq 0 ] && printf '%s\n' "$out" | grep -qx "QuietClaude 7.7.7 installed at $W/p7/claude" && [ "$(requests)" -eq "$before" ]; then
    ok "installer 7: local build installed without download"
else
    bad "installer 7: status $status: $out"
fi

installer PREFIX="$W/p8" QUIETCLAUDE_RELEASE_BASE="$BASE/good" VERSION=v9.9.9 >/dev/null 2>&1
status=$?
sleep 0.2
if [ "$status" -eq 0 ] && grep -q 'GET /good/releases/download/v9.9.9/quietclaude-linux-x86_64 ' "$W/server.log" && [ -x "$W/p8/claude" ]; then
    ok "installer 8: VERSION requests the tagged path"
else
    bad "installer 8: status $status"
fi

out=$(cd "$SCRATCH" && env -i PATH="$W/fakebin:$W/nocurl" HOME="$W/home" TMPDIR="$W/tmp" FAKE_OS=Linux FAKE_ARCH=x86_64 PREFIX="$W/p9" QUIETCLAUDE_RELEASE_BASE="$BASE/good" sh "$ROOT/install.sh" 2>&1)
status=$?
if [ "$status" -eq 0 ] && [ -x "$W/p9/claude" ] && printf '%s\n' "$out" | grep -qx "QuietClaude 9.9.9 installed at $W/p9/claude"; then
    ok "installer 9: wget fallback"
else
    bad "installer 9: status $status: $out"
fi

ln -s "$QC" "$W/links/qc"
ln -s "$QC" "$W/links/claude"
cat > "$W/stubclaude" <<'SCRIPT'
#!/bin/sh
echo "stub claude: $*"
exit 7
SCRIPT
chmod 755 "$W/stubclaude"
cat > "$W/pro" <<'SCRIPT'
#!/bin/sh
echo "pro stub: $*"
echo "QUIETCLAUDE_CORE_VERSION=${QUIETCLAUDE_CORE_VERSION-}"
SCRIPT
chmod 755 "$W/pro"
nudge_update="quietclaude: the free launcher does not update itself.
Updating is part of QuietClaude Pro. See https://github.com/QuietClaude/cli#pro
To update the free launcher, run the install command again: curl -fsSL https://quietclaude.com/install.sh | sh"

pro_nudge() {
    printf "quietclaude: '%s' is part of QuietClaude Pro. See https://github.com/QuietClaude/cli#pro\nTo update the free launcher, run the install command again: curl -fsSL https://quietclaude.com/install.sh | sh\n" "$1"
}

err=$("$W/links/qc" update 2>&1 >/dev/null)
status=$?
if [ "$status" -eq 2 ] && [ "$err" = "$nudge_update" ]; then
    ok "dispatch 11: qc update prints the nudge"
else
    bad "dispatch 11: status $status: $err"
fi

out=$(QUIETCLAUDE_CLAUDE_PATH="$W/stubclaude" "$W/links/claude" update 2>&1 | cat)
QUIETCLAUDE_CLAUDE_PATH="$W/stubclaude" "$W/links/claude" update >/dev/null 2>&1
status=$?
if [ "$status" -eq 7 ] && printf '%s' "$out" | grep -q 'stub claude: update' && ! printf '%s' "$out" | grep -q 'QuietClaude Pro'; then
    ok "dispatch 12: claude update forwards to Claude Code"
else
    bad "dispatch 12: status $status: $out"
fi

err=$(env -u QUIETCLAUDE_PRO_PATH HOME="$W/home" "$W/links/qc" pro 2>&1 >/dev/null)
status=$?
if [ "$status" -eq 2 ] && [ "$err" = "$(pro_nudge pro)" ]; then
    ok "dispatch 13: qc pro without a Pro binary"
else
    bad "dispatch 13: status $status: $err"
fi

out=$(QUIETCLAUDE_PRO_PATH="$W/pro" "$W/links/qc" pro --x 2>&1)
status=$?
if [ "$status" -eq 0 ] && printf '%s' "$out" | grep -q 'pro stub: pro --x' && printf '%s' "$out" | grep -q 'QUIETCLAUDE_CORE_VERSION=0.2.1'; then
    ok "dispatch 14: qc pro --x runs the stub with argv and core version"
else
    bad "dispatch 14: status $status: $out"
fi

for args in "@work" "--profile work" "profile list" "header show" "sync status"; do
    eval "set -- $args"
    err=$(env -u QUIETCLAUDE_PRO_PATH HOME="$W/home" "$W/links/qc" "$@" 2>&1 >/dev/null)
    status=$?
    if [ "$status" -eq 2 ] && [ "$err" = "$(pro_nudge "$1")" ]; then
        ok "dispatch 15: qc $args nudges"
    else
        bad "dispatch 15: qc $args status $status: $err"
    fi
    out=$(QUIETCLAUDE_PRO_PATH="$W/pro" "$W/links/qc" "$@" 2>&1)
    status=$?
    if [ "$status" -eq 0 ] && printf '%s' "$out" | grep -q "pro stub: $args"; then
        ok "dispatch 15: qc $args runs the stub"
    else
        bad "dispatch 15: qc $args stub status $status: $out"
    fi
done

out=$(QUIETCLAUDE_PRO_PATH="$W/pro" QUIETCLAUDE_CLAUDE_PATH="$W/stubclaude" "$W/links/qc" --model opus -p 'reply ok' 2>&1 | cat)
if printf '%s' "$out" | grep -q 'pro stub: --model opus -p reply ok' && printf '%s' "$out" | grep -q 'QUIETCLAUDE_CORE_VERSION=0.2.1' \
    && ! printf '%s' "$out" | grep -q 'stub claude'; then
    ok "dispatch 16: with Pro installed, a plain launch goes to Pro"
else
    bad "dispatch 16: $out"
fi

out=$(QUIETCLAUDE_CLAUDE_PATH="$W/stubclaude" "$W/links/qc" --model opus -p 'reply ok' 2>&1 | cat)
QUIETCLAUDE_CLAUDE_PATH="$W/stubclaude" "$W/links/qc" --model opus -p 'reply ok' >/dev/null 2>&1
status=$?
if [ "$status" -eq 7 ] && printf '%s' "$out" | grep -q "stub claude: --model opus -p reply ok" && ! printf '%s' "$out" | grep -q 'pro stub'; then
    ok "dispatch 16b: without Pro, ordinary arguments go to Claude Code"
else
    bad "dispatch 16b: status $status: $out"
fi

printf '#!/nonexistent/interpreter\n' > "$W/brokenpro"
chmod 755 "$W/brokenpro"
out=$(QUIETCLAUDE_PRO_PATH="$W/brokenpro" QUIETCLAUDE_CLAUDE_PATH="$W/stubclaude" "$W/links/qc" -p 'reply ok' 2>&1 | cat)
QUIETCLAUDE_PRO_PATH="$W/brokenpro" QUIETCLAUDE_CLAUDE_PATH="$W/stubclaude" "$W/links/qc" -p 'reply ok' >/dev/null 2>&1
status=$?
if [ "$status" -eq 7 ] && printf '%s' "$out" | grep -q 'exec pro' && printf '%s' "$out" | grep -q 'stub claude: -p reply ok'; then
    ok "dispatch 16c: a Pro that cannot start is reported and Claude Code still launches"
else
    bad "dispatch 16c: status $status: $out"
fi

out=$(QUIETCLAUDE_PRO_PATH="$W/pro" QUIETCLAUDE_CLAUDE_PATH="$W/stubclaude" "$W/links/qc" --version 2>&1 | cat)
if printf '%s' "$out" | grep -q '^QuietClaude 0.2.1' && ! printf '%s' "$out" | grep -q 'pro stub'; then
    ok "dispatch 16d: --version stays with the free launcher"
else
    bad "dispatch 16d: $out"
fi

err=$(PATH=/usr/bin "$W/links/qc" update 2>&1 >/dev/null)
status=$?
if [ "$status" -eq 2 ] && [ "$err" = "$nudge_update" ]; then
    ok "dispatch 17: nudge with PATH=/usr/bin"
else
    bad "dispatch 17: status $status: $err"
fi

cp "$W/pro" "$W/download"
chmod 644 "$W/download"
out=$(cd "$W" && env -u QUIETCLAUDE_PRO_PATH HOME="$W/home" "$W/links/qc" pro install download --key - 2>&1)
status=$?
if [ "$status" -eq 0 ] && printf '%s' "$out" | grep -q 'pro stub: pro install download --key -' \
    && printf '%s' "$out" | grep -q 'QUIETCLAUDE_CORE_VERSION=0.2.1' && [ -x "$W/download" ]; then
    ok "dispatch 18: qc pro install <file> without Pro runs the downloaded file"
else
    bad "dispatch 18: status $status: $out"
fi

err=$(env -u QUIETCLAUDE_PRO_PATH HOME="$W/home" "$W/links/qc" pro install "$W/missing" 2>&1 >/dev/null)
status=$?
err2=$(env -u QUIETCLAUDE_PRO_PATH HOME="$W/home" "$W/links/qc" pro install 2>&1 >/dev/null)
status2=$?
if [ "$status" -eq 1 ] && [ "$err" = "quietclaude: $W/missing is not a file." ] \
    && [ "$status2" -eq 2 ] && [ "$err2" = "$(pro_nudge pro)" ]; then
    ok "dispatch 19: qc pro install with a missing or no file is refused"
else
    bad "dispatch 19: status $status: $err / $status2: $err2"
fi

out=$(QUIETCLAUDE_PRO_PATH="$W/pro" "$W/links/qc" pro install "$W/download" 2>&1)
status=$?
if [ "$status" -eq 0 ] && printf '%s' "$out" | grep -q "pro stub: pro install $W/download"; then
    ok "dispatch 20: with Pro installed, qc pro install goes to Pro"
else
    bad "dispatch 20: status $status: $out"
fi

cat > "$W/standalone.c" <<'SOURCE'
#include "core.h"
int main(void) { return qc_core_version() == 0; }
SOURCE
case $(uname -s) in
    Linux) libs=-lutil ;;
    *) libs= ;;
esac
if "${CC:-cc}" -std=c11 -Wall -Wextra -Werror -I "$ROOT/src" -o "$W/standalone" "$W/standalone.c" "$ROOT/libquietclaude.a" ${libs:+"$libs"} \
    && "$W/standalone"; then
    ok "library: core.h compiles standalone against libquietclaude.a"
else
    bad "library: standalone program did not build or run"
fi

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
