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
    if [ -n "${dl_pid-}" ]; then
        kill "$dl_pid" 2>/dev/null
    fi
    rm -rf "$W"
}
trap cleanup EXIT INT TERM HUP

mkdir -p "$W/bin" "$W/fakebin" "$W/nocurl" "$W/tmp" "$W/home" "$W/links" "$W/local"
export HOME="$W/home"
unset QUIETCLAUDE_PRO_PATH
for tool in sh uname mktemp rm dirname basename awk head install ln mkdir sha256sum shasum curl wget cat chmod grep sed readlink; do
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
if [ "$status" -eq 0 ] && printf '%s' "$out" | grep -q 'pro stub: pro --x' && printf '%s' "$out" | grep -q 'QUIETCLAUDE_CORE_VERSION=0.4.1'; then
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
if printf '%s' "$out" | grep -q 'pro stub: --model opus -p reply ok' && printf '%s' "$out" | grep -q 'QUIETCLAUDE_CORE_VERSION=0.4.1' \
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
if printf '%s' "$out" | grep -q '^QuietClaude 0.4.1' && ! printf '%s' "$out" | grep -q 'pro stub'; then
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
    && printf '%s' "$out" | grep -q 'QUIETCLAUDE_CORE_VERSION=0.4.1' && [ -x "$W/download" ]; then
    ok "dispatch 18: qc pro install <file> without Pro runs the downloaded file"
else
    bad "dispatch 18: status $status: $out"
fi

err=$(env -u QUIETCLAUDE_PRO_PATH HOME="$W/home" "$W/links/qc" pro install "$W/missing" 2>&1 >/dev/null)
status=$?
err2=$(env -u QUIETCLAUDE_PRO_PATH HOME="$W/home" "$W/links/qc" pro install 2>&1 >/dev/null)
status2=$?
if [ "$status" -eq 1 ] && [ "$err" = "quietclaude: $W/missing is not a file." ] \
    && [ "$status2" -eq 2 ] && printf '%s' "$err2" | grep -q 'a licence key is needed'; then
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

uninstall_env() {
    env -i PATH="${UPATH:-$W/bin}" HOME="$W/home" "$@" sh "$ROOT/uninstall.sh"
}
fake_claude_code() {
    printf '#!/bin/sh\necho "2.1.304 (Claude Code)"\n' > "$1"
    chmod 755 "$1"
}

U1=$W/u1
mkdir -p "$U1"
env -i PATH="$W/bin" HOME="$W/home" SOURCE="$QC" PREFIX="$U1" sh "$ROOT/install.sh" >/dev/null 2>&1
out=$(uninstall_env PREFIX="$U1" 2>&1)
status=$?
if [ "$status" -eq 0 ] && [ ! -e "$U1/claude" ] && [ ! -L "$U1/qc" ] \
    && printf '%s' "$out" | grep -q "^Removed $U1/claude\$" && printf '%s' "$out" | grep -q "^Removed $U1/qc\$" \
    && printf '%s' "$out" | grep -q 'goes back to Claude Code'; then
    ok "uninstall 1: removes the launcher and the qc link"
else
    bad "uninstall 1: status $status: $out"
fi

out=$(uninstall_env PREFIX="$U1" 2>&1)
status=$?
if [ "$status" -eq 0 ] && printf '%s' "$out" | grep -q '^Nothing to remove'; then
    ok "uninstall 2: running it again says there is nothing to remove"
else
    bad "uninstall 2: status $status: $out"
fi

U3=$W/u3
mkdir -p "$U3"
fake_claude_code "$U3/claude"
ln -s "$U3/claude" "$U3/qc"
out=$(uninstall_env PREFIX="$U3" 2>&1)
status=$?
if [ "$status" -eq 1 ] && [ -x "$U3/claude" ] && [ -L "$U3/qc" ] && printf '%s' "$out" | grep -q 'is not QuietClaude, so it was left alone'; then
    ok "uninstall 3: a claude that is not QuietClaude is never removed, nor a link to it"
else
    bad "uninstall 3: status $status: $out"
fi

U4=$W/u4
mkdir -p "$U4"
env -i PATH="$W/bin" HOME="$W/home" SOURCE="$QC" PREFIX="$U4" ALIAS= sh "$ROOT/install.sh" >/dev/null 2>&1
fake_claude_code "$U4/other"
ln -s "$U4/other" "$U4/qc"
out=$(uninstall_env PREFIX="$U4" 2>&1)
status=$?
if [ "$status" -eq 0 ] && [ ! -e "$U4/claude" ] && [ -L "$U4/qc" ] && [ "$(readlink "$U4/qc")" = "$U4/other" ] \
    && printf '%s' "$out" | grep -q 'was left alone because it is not a QuietClaude link'; then
    ok "uninstall 4: a qc link that points somewhere else is left alone"
else
    bad "uninstall 4: status $status: $out"
fi

U5=$W/u5
mkdir -p "$U5"
env -i PATH="$W/bin" HOME="$W/home" SOURCE="$QC" PREFIX="$U5" sh "$ROOT/install.sh" >/dev/null 2>&1
out=$(uninstall_env PREFIX="$U5" DRY_RUN=1 2>&1)
status=$?
if [ "$status" -eq 0 ] && [ -x "$U5/claude" ] && [ -L "$U5/qc" ] && printf '%s' "$out" | grep -q "^Would remove $U5/claude\$" \
    && printf '%s' "$out" | grep -q 'Dry run: nothing was changed'; then
    ok "uninstall 5: DRY_RUN lists what would go and changes nothing"
else
    bad "uninstall 5: status $status: $out"
fi

mkdir -p "$W/home/.quietclaude/profiles/work"
printf 'keep me\n' > "$W/home/.quietclaude/profiles/work/.credentials.json"
out=$(uninstall_env PREFIX="$U5" 2>&1)
status=$?
if [ "$status" -eq 0 ] && [ ! -e "$U5/claude" ] && [ -f "$W/home/.quietclaude/profiles/work/.credentials.json" ] \
    && printf '%s' "$out" | grep -q "Left alone: $W/home/.quietclaude" && printf '%s' "$out" | grep -q 'rm -rf'; then
    ok "uninstall 6: Pro data in ~/.quietclaude is left alone and the message says how to remove it"
else
    bad "uninstall 6: status $status: $out"
fi
rm -rf "$W/home/.quietclaude"

U7=$W/u7
mkdir -p "$U7/bin"
env -i PATH="$W/bin" HOME="$W/home" SOURCE="$QC" PREFIX="$U7/bin" sh "$ROOT/install.sh" >/dev/null 2>&1
out=$(UPATH="$U7/bin:$W/bin" uninstall_env 2>&1)
status=$?
if [ "$status" -eq 0 ] && [ ! -e "$U7/bin/claude" ] && [ ! -L "$U7/bin/qc" ]; then
    ok "uninstall 7: without PREFIX it finds the install through qc in PATH"
else
    bad "uninstall 7: status $status: $out"
fi

U8=$W/u8
mkdir -p "$U8"
env -i PATH="$W/bin" HOME="$W/home" SOURCE="$QC" PREFIX="$U8" ALIAS=cq sh "$ROOT/install.sh" >/dev/null 2>&1
out=$(uninstall_env PREFIX="$U8" ALIAS=cq 2>&1)
status=$?
if [ "$status" -eq 0 ] && [ ! -e "$U8/claude" ] && [ ! -L "$U8/cq" ]; then
    ok "uninstall 8: a custom ALIAS is removed with the launcher"
else
    bad "uninstall 8: status $status: $out"
fi

U9=$W/u9
mkdir -p "$U9/own" "$U9/other"
env -i PATH="$W/bin" HOME="$W/home" SOURCE="$QC" PREFIX="$U9/other" sh "$ROOT/install.sh" >/dev/null 2>&1
out=$(UPATH="$U9/other:$W/bin" uninstall_env PREFIX="$U9/own" 2>&1)
status=$?
if [ "$status" -eq 0 ] && [ -x "$U9/other/claude" ] && printf '%s' "$out" | grep -q '^Nothing to remove'; then
    ok "uninstall 9: an explicit PREFIX is never replaced by whatever qc is in PATH"
else
    bad "uninstall 9: status $status: $out"
fi

# qc uninstall: every case installs a scratch copy first, because the command deletes the launcher.
scratch_install() {
    mkdir -p "$1"
    env -i PATH="$W/bin" HOME="$W/home" SOURCE="$QC" PREFIX="$1" sh "$ROOT/install.sh" >/dev/null 2>&1
}
run_qc() {
    d=$1
    shift
    env -i PATH="$W/bin" HOME="$W/home" QUIETCLAUDE_CLAUDE_PATH="$W/stubclaude" "$@" "$d/qc" uninstall
}
sha_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

Q10=$W/q10
scratch_install "$Q10"
out=$(env -i PATH="$W/bin" HOME="$W/home" "$Q10/qc" uninstall 2>&1)
status=$?
# The command prints real paths; on macOS the temp folder is a link (/var to /private/var).
QP10=$(cd "$Q10" && pwd -P)
if [ "$status" -eq 0 ] && [ ! -e "$Q10/claude" ] && [ ! -L "$Q10/qc" ] && printf '%s' "$out" | grep -q "^Removed $QP10/claude\$" \
    && printf '%s' "$out" | grep -q "^Removed $QP10/qc\$" && printf '%s' "$out" | grep -q 'goes back to Claude Code'; then
    ok "qc uninstall 10: removes the launcher and the qc link"
else
    bad "qc uninstall 10: status $status: $out"
fi

Q11=$W/q11
scratch_install "$Q11"
out=$(env -i PATH="$W/bin" HOME="$W/home" QUIETCLAUDE_CLAUDE_PATH="$W/stubclaude" "$Q11/claude" uninstall 2>&1)
status=$?
if [ "$status" -eq 7 ] && printf '%s' "$out" | grep -q 'stub claude: uninstall' && [ -x "$Q11/claude" ] && [ -L "$Q11/qc" ]; then
    ok "qc uninstall 11: claude uninstall goes to Claude Code and removes nothing"
else
    bad "qc uninstall 11: status $status: $out"
fi

Q12=$W/q12
scratch_install "$Q12"
chmod 555 "$Q12"
if [ "$(id -u)" -ne 0 ]; then
    out=$(env -i PATH="$W/bin" HOME="$W/home" "$Q12/qc" uninstall 2>&1)
    status=$?
    chmod 755 "$Q12"
    if [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q "is not writable. Run: sudo qc uninstall" && [ -x "$Q12/claude" ] && [ -L "$Q12/qc" ]; then
        ok "qc uninstall 12: a folder you cannot write to gives the sudo line and removes nothing"
    else
        bad "qc uninstall 12: status $status: $out"
    fi
else
    chmod 755 "$Q12"
fi

Q13=$W/q13
scratch_install "$Q13"
mkdir -p "$W/home/.quietclaude/profiles/work"
printf 'keep\n' > "$W/home/.quietclaude/profiles/work/.credentials.json"
printf 'licence\n' > "$W/home/.quietclaude/license"
printf '#!/bin/sh\n' > "$W/home/.quietclaude/pro"
chmod 755 "$W/home/.quietclaude/pro"
out=$(env -i PATH="$W/bin" HOME="$W/home" "$Q13/qc" uninstall 2>&1)
status=$?
if [ "$status" -eq 0 ] && [ ! -e "$W/home/.quietclaude/pro" ] && [ -f "$W/home/.quietclaude/profiles/work/.credentials.json" ] \
    && [ -f "$W/home/.quietclaude/license" ] && [ ! -e "$Q13/claude" ] && printf '%s' "$out" | grep -q "^Removed $W/home/.quietclaude/pro\$" \
    && printf '%s' "$out" | grep -q "Left alone: $W/home/.quietclaude"; then
    ok "qc uninstall 13: the Pro binary goes, the profiles, licence and config stay"
else
    bad "qc uninstall 13: status $status: $out"
fi

Q14=$W/q14
scratch_install "$Q14"
printf '#!/bin/sh\n' > "$W/home/.quietclaude/pro"
chmod 755 "$W/home/.quietclaude/pro"
out=$(env -i PATH="$W/bin" HOME="$W/home" "$Q14/qc" uninstall --dry-run 2>&1)
status=$?
QP14=$(cd "$Q14" && pwd -P)
if [ "$status" -eq 0 ] && [ -x "$Q14/claude" ] && [ -L "$Q14/qc" ] && [ -f "$W/home/.quietclaude/pro" ] \
    && printf '%s' "$out" | grep -q "^Would remove $QP14/claude\$" && printf '%s' "$out" | grep -q "^Would remove $W/home/.quietclaude/pro\$" \
    && printf '%s' "$out" | grep -q 'Dry run: nothing was changed'; then
    ok "qc uninstall 14: --dry-run lists the removals and changes nothing"
else
    bad "qc uninstall 14: status $status: $out"
fi
rm -f "$W/home/.quietclaude/pro"

Q15=$W/q15
scratch_install "$Q15"
out=$(python3 "$HERE/pty_uninstall.py" no env -i PATH="$W/bin" HOME="$W/home" "$Q15/qc" uninstall --purge 2>&1)
if printf '%s' "$out" | grep -q 'exit=1' && [ -x "$Q15/claude" ] && [ -f "$W/home/.quietclaude/license" ] \
    && printf '%s' "$out" | grep -q 'nothing was deleted'; then
    ok "qc uninstall 15: --purge answered no deletes nothing"
else
    bad "qc uninstall 15: $out"
fi

out=$(python3 "$HERE/pty_uninstall.py" none env -i PATH="$W/bin" HOME="$W/home" "$Q15/qc" uninstall --purge 2>&1)
if printf '%s' "$out" | grep -q 'exit=1' && [ -x "$Q15/claude" ] && [ -f "$W/home/.quietclaude/license" ] \
    && printf '%s' "$out" | grep -q 'needs a terminal'; then
    ok "qc uninstall 17: --purge with no terminal is refused"
else
    bad "qc uninstall 17: $out"
fi

out=$(python3 "$HERE/pty_uninstall.py" yes env -i PATH="$W/bin" HOME="$W/home" "$Q15/qc" uninstall --purge 2>&1)
if printf '%s' "$out" | grep -q 'exit=0' && [ ! -e "$Q15/claude" ] && [ ! -e "$W/home/.quietclaude" ] \
    && printf '%s' "$out" | grep -q "Deleted the folder $W/home/.quietclaude"; then
    ok "qc uninstall 16: --purge answered yes deletes the Pro folder and the launcher"
else
    bad "qc uninstall 16: $out"
fi

Q18=$W/q18
scratch_install "$Q18"
mkdir -p "$W/home/.quietclaude/profiles/work"
printf 'x\n' > "$W/home/.quietclaude/profiles/work/.credentials.json"
out=$(python3 "$HERE/pty_uninstall.py" none env -i PATH="$W/bin" HOME="$W/home" "$Q18/qc" uninstall --purge --yes 2>&1)
if printf '%s' "$out" | grep -q 'exit=0' && [ ! -e "$Q18/claude" ] && [ ! -e "$W/home/.quietclaude" ]; then
    ok "qc uninstall 18: --purge --yes needs no terminal"
else
    bad "qc uninstall 18: $out"
fi

Q20=$W/q20
mkdir -p "$Q20/other"
env -i PATH="$W/bin" HOME="$W/home" SOURCE="$QC" PREFIX="$Q20" ALIAS= sh "$ROOT/install.sh" >/dev/null 2>&1
fake_claude_code "$Q20/other/claude"
ln -s "$Q20/other/claude" "$Q20/qc"
mkdir -p "$Q20/bin"
ln -s "$Q20/claude" "$Q20/bin/qc"
out=$(env -i PATH="$W/bin" HOME="$W/home" "$Q20/bin/qc" uninstall 2>&1)
status=$?
if [ "$status" -eq 0 ] && [ ! -e "$Q20/claude" ] && [ ! -L "$Q20/bin/qc" ] && [ -L "$Q20/qc" ] && [ "$(readlink "$Q20/qc")" = "$Q20/other/claude" ]; then
    ok "qc uninstall 20: the link it was run through goes, a qc link to something else stays"
else
    bad "qc uninstall 20: status $status: $out"
fi

Q21=$W/q21
scratch_install "$Q21"
fake_claude_code "$Q21/claude-code-copy"
before=$(sha_of "$Q21/claude-code-copy")
env -i PATH="$W/bin" HOME="$W/home" "$Q21/qc" uninstall >/dev/null 2>&1
after=$(sha_of "$Q21/claude-code-copy")
if [ -n "$before" ] && [ "$before" = "$after" ] && [ ! -e "$Q21/claude" ]; then
    ok "qc uninstall 21: another claude in the same folder is untouched"
else
    bad "qc uninstall 21: $before / $after"
fi

Q22=$W/q22
scratch_install "$Q22"
out1=$(env -i PATH="$W/bin" HOME="$W/home" "$Q22/qc" uninstall --bogus 2>&1)
status1=$?
out2=$(env -i PATH="$W/bin" HOME="$W/home" "$Q22/qc" uninstall --yes 2>&1)
status2=$?
if [ "$status1" -eq 2 ] && [ "$status2" -eq 2 ] && printf '%s' "$out1" | grep -q 'usage: qc uninstall' && [ -x "$Q22/claude" ]; then
    ok "qc uninstall 22: unknown options and --yes without --purge are usage errors that remove nothing"
else
    bad "qc uninstall 22: $status1 $out1 / $status2 $out2"
fi
rm -rf "$W/home/.quietclaude"

Q23=$W/q23
scratch_install "$Q23"
out=$(env -i PATH="$Q23:$W/bin" HOME="$W/home" qc uninstall 2>&1)
status=$?
if [ "$status" -eq 0 ] && [ ! -e "$Q23/claude" ] && [ ! -L "$Q23/qc" ] && ! printf '%s' "$out" | grep -q 'cannot remove'; then
    ok "qc uninstall 23: a bare qc found through PATH removes the launcher and the link once"
else
    bad "qc uninstall 23: status $status: $out"
fi

Q24=$W/q24
scratch_install "$Q24"
out=$(cd "$Q24" && env -i PATH=":$W/bin" HOME="$W/home" qc uninstall 2>&1)
status=$?
if [ "$status" -eq 0 ] && [ ! -e "$Q24/claude" ] && [ ! -L "$Q24/qc" ] && ! printf '%s' "$out" | grep -q 'cannot remove'; then
    ok "qc uninstall 24: an empty PATH entry (the current folder) works and the link is not removed twice"
else
    bad "qc uninstall 24: status $status: $out"
fi

Q25=$W/q25
scratch_install "$Q25"
mkdir -p "$W/realqc/profiles/work"
printf 'login\n' > "$W/realqc/profiles/work/.credentials.json"
rm -rf "$W/home/.quietclaude"
ln -s "$W/realqc" "$W/home/.quietclaude"
out=$(env -i PATH="$W/bin" HOME="$W/home" "$Q25/qc" uninstall --purge --yes 2>&1)
status=$?
if [ "$status" -eq 0 ] && [ ! -e "$Q25/claude" ] && [ -L "$W/home/.quietclaude" ] && [ -f "$W/realqc/profiles/work/.credentials.json" ] \
    && printf '%s' "$out" | grep -q 'is a link, so --purge leaves it alone' && printf '%s' "$out" | grep -q "Left alone: $W/home/.quietclaude"; then
    ok "qc uninstall 25: a ~/.quietclaude that is a link is never purged, and the message says so"
else
    bad "qc uninstall 25: status $status: $out"
fi
rm -rf "$W/home/.quietclaude" "$W/realqc"

Q26=$W/q26
mkdir -p "$Q26/bin"
env -i PATH="$W/bin" HOME="$W/home" SOURCE="$QC" PREFIX="$Q26" ALIAS= sh "$ROOT/install.sh" >/dev/null 2>&1
ln -s "$Q26/claude" "$Q26/bin/qc"
chmod 555 "$Q26/bin"
if [ "$(id -u)" -ne 0 ]; then
    out=$(env -i PATH="$W/bin" HOME="$W/home" "$Q26/bin/qc" uninstall 2>&1)
    status=$?
    chmod 755 "$Q26/bin"
    if [ "$status" -eq 1 ] && [ -x "$Q26/claude" ] && [ -L "$Q26/bin/qc" ] && printf '%s' "$out" | grep -q "$Q26/bin is not writable"; then
        ok "qc uninstall 26: a link in a folder you cannot write to stops everything before anything is removed"
    else
        bad "qc uninstall 26: status $status: $out"
    fi
else
    chmod 755 "$Q26/bin"
fi

Q27=$W/q27
scratch_install "$Q27"
mkdir -p "$W/q27other"
printf 'not the launcher\n' > "$W/q27other/qc"
chmod 755 "$W/q27other/qc"
if command -v bash >/dev/null 2>&1; then
    out=$(env -i PATH="$W/bin:$(dirname "$(command -v bash)")" HOME="$W/home" bash -c "exec -a '$W/q27other/qc' '$Q27/claude' uninstall" 2>&1)
    status=$?
    if [ "$status" -eq 1 ] && [ -x "$Q27/claude" ] && [ -L "$Q27/qc" ] && [ "$(cat "$W/q27other/qc")" = "not the launcher" ] \
        && printf '%s' "$out" | grep -q 'is not the program that was started'; then
        ok "qc uninstall 27: a program name that points at some other file removes nothing"
    else
        bad "qc uninstall 27: status $status: $out"
    fi
fi

# qc update goes to Pro. $W/pro is the stub that prints its arguments.
out=$(QUIETCLAUDE_PRO_PATH="$W/pro" "$W/links/qc" update --check 2>&1)
status=$?
if [ "$status" -eq 0 ] && printf '%s' "$out" | grep -q '^pro stub: pro update --check$' && printf '%s' "$out" | grep -q 'QUIETCLAUDE_CORE_VERSION=0.4.1'; then
    ok "qc update 1: with Pro installed, qc update --check runs pro update --check"
else
    bad "qc update 1: status $status: $out"
fi

out=$(QUIETCLAUDE_PRO_PATH="$W/pro" "$W/links/qc" update 2>&1)
if printf '%s' "$out" | grep -q '^pro stub: pro update$'; then
    ok "qc update 2: qc update alone runs pro update"
else
    bad "qc update 2: $out"
fi

printf 'not executable\n' > "$W/notpro"
chmod 644 "$W/notpro"
out=$(QUIETCLAUDE_PRO_PATH="$W/notpro" "$W/links/qc" update 2>&1)
status=$?
if [ "$status" -eq 2 ] && [ "$out" = "$nudge_update" ]; then
    ok "qc update 3: a Pro that is not executable counts as not installed: the nudge"
else
    bad "qc update 3: status $status: $out"
fi

out=$(QUIETCLAUDE_PRO_PATH="$W/pro" QUIETCLAUDE_CLAUDE_PATH="$W/stubclaude" "$W/links/claude" update 2>&1)
if ! printf '%s' "$out" | grep -q 'pro stub: pro update'; then
    ok "qc update 4: claude update is never turned into pro update"
else
    bad "qc update 4: $out"
fi

if unshare -r true 2>/dev/null; then
    out=$(unshare -r env -i PATH="$W/bin" HOME="$W/home" SUDO_USER=someone QUIETCLAUDE_PRO_PATH="$W/pro" "$W/links/qc" update 2>&1)
    status=$?
    out2=$(unshare -r env -i PATH="$W/bin" HOME="$W/home" QUIETCLAUDE_PRO_PATH="$W/pro" "$W/links/qc" update 2>&1)
    if [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q 'run qc update without sudo' && ! printf '%s' "$out" | grep -q 'pro stub' \
        && printf '%s' "$out2" | grep -q '^pro stub: pro update$'; then
        ok "qc update 5: as root through sudo it refuses, as plain root it runs"
    else
        bad "qc update 5: $status $out / $out2"
    fi
fi

# qc uninstall under sudo: a private /etc/passwd in a user namespace stands in for a real sudo.
if unshare -rm true 2>/dev/null; then
    S28=$W/s28
    scratch_install "$S28"
    mkdir -p "$W/bobhome/.quietclaude/profiles/work" "$W/bobbyhome/.quietclaude"
    printf 'login\n' > "$W/bobhome/.quietclaude/profiles/work/.credentials.json"
    printf '#!/bin/sh\n' > "$W/bobhome/.quietclaude/pro"
    printf '#!/bin/sh\n' > "$W/bobbyhome/.quietclaude/pro"
    printf 'root:x:0:0:root:/root:/bin/sh\nbobby:x:1235:1235:%s/decoygecos:%s/bobbyhome:/bin/sh\nbob:x:1234:1234:Bob,,,:%s/bobhome:/bin/sh\n' "$W" "$W" "$W" > "$W/passwd"
    out=$(unshare -rm sh -c "mount --bind '$W/passwd' /etc/passwd && env -i PATH='$W/bin' HOME=/nonexistent SUDO_USER=bob '$S28/qc' uninstall" 2>&1)
    status=$?
    if [ "$status" -eq 0 ] && [ ! -e "$S28/claude" ] && [ ! -e "$W/bobhome/.quietclaude/pro" ] && [ -f "$W/bobhome/.quietclaude/profiles/work/.credentials.json" ] \
        && [ -f "$W/bobbyhome/.quietclaude/pro" ] && printf '%s' "$out" | grep -q "^Removed $W/bobhome/.quietclaude/pro\$"; then
        ok "qc uninstall 28: under sudo it removes the Pro binary of SUDO_USER, not of a user whose name starts the same"
    else
        bad "qc uninstall 28: status $status: $out"
    fi

    scratch_install "$S28"
    out=$(unshare -rm sh -c "mount --bind '$W/passwd' /etc/passwd && env -i PATH='$W/bin' HOME=/nonexistent SUDO_USER=bob '$S28/qc' uninstall --purge --yes" 2>&1)
    status=$?
    if [ "$status" -eq 0 ] && [ ! -e "$W/bobhome/.quietclaude" ] && [ -f "$W/bobbyhome/.quietclaude/pro" ] && [ ! -e "$S28/claude" ]; then
        ok "qc uninstall 29: under sudo --purge deletes only the folder of SUDO_USER"
    else
        bad "qc uninstall 29: status $status: $out"
    fi

    scratch_install "$S28"
    out=$(unshare -rm sh -c "mount --bind '$W/passwd' /etc/passwd && env -i PATH='$W/bin' HOME='$W/bobbyhome' SUDO_USER=nosuchuser '$S28/qc' uninstall --purge --yes" 2>&1)
    status=$?
    if [ "$status" -eq 0 ] && [ -f "$W/bobbyhome/.quietclaude/pro" ] && printf '%s' "$out" | grep -q 'home folder could not be found'; then
        ok "qc uninstall 30: under sudo with an unknown user it skips Pro files rather than using root's HOME"
    else
        bad "qc uninstall 30: status $status: $out"
    fi
    rm -rf "$W/bobhome" "$W/bobbyhome" "$W/passwd"
fi

# qc pro install with no file: detect the system, ask for the key, download, install.
DL=$W/dl
mkdir -p "$DL/root" "$DL/tmp"
case "$(uname -s)/$(uname -m)" in
    Linux/x86_64) DLASSET=quietclaude-pro-linux-x86_64 ;;
    Linux/aarch64) DLASSET=quietclaude-pro-linux-arm64 ;;
    Darwin/x86_64) DLASSET=quietclaude-pro-darwin-x86_64 ;;
    *) DLASSET=quietclaude-pro-darwin-arm64 ;;
esac
cat > "$DL/root/$DLASSET" <<'SCRIPT'
#!/bin/sh
echo "pro stub args: $*"
IFS= read -r k
echo "pro stub key: $k"
exit "${STUB_EXIT:-0}"
SCRIPT
printf 'sums\n' > "$DL/root/SHA256SUMS"
printf 'sig\n' > "$DL/root/SHA256SUMS.sig"
python3 -I "$HERE/fake_dl.py" "$DL/root" "$DL/log" > "$DL/port" 2> "$DL/err" &
dl_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -s "$DL/port" ] && break
    sleep 0.2
done
DLPORT=$(head -n 1 "$DL/port")
rm -rf "$W/home/.quietclaude"
dlenv() { env HOME="$W/home" TMPDIR="$DL/tmp" QUIETCLAUDE_PRO_BASE="http://127.0.0.1:$DLPORT" "$@"; }
dl_left() { { find "$DL/tmp" -mindepth 1; find "$W/home/.quietclaude" -mindepth 0 2>/dev/null; } | wc -l | tr -d ' '; }
: > "$DL/log"

out=$(printf 'VALID-KEY-1234\n' | dlenv "$W/links/qc" pro install --key - 2>&1)
status=$?
if [ "$status" -eq 0 ] && printf '%s' "$out" | grep -q "^Downloading QuietClaude Pro for this machine ($DLASSET)" \
    && printf '%s' "$out" | grep -qE "^pro stub args: pro install $W/home/\.quietclaude/\.qcpro\.[A-Za-z0-9]+/$DLASSET --key -$" \
    && printf '%s' "$out" | grep -q '^pro stub key: VALID-KEY-1234$' && [ "$(printf '%s\n' "$out" | grep -c '^Licence key accepted\.$')" = "1" ] && [ "$(dl_left)" = "0" ]; then
    ok "pro download 1: the key from stdin, three files fetched, the installer run on them with the key, temporary folder removed"
else
    bad "pro download 1: status $status: $out (left: $(dl_left))"
fi
reqs=$(sed 's/ key=yes//' "$DL/log" | tr '\n' ' ')
if [ "$reqs" = "/pro/download/SHA256SUMS /pro/download/SHA256SUMS.sig /pro/download/$DLASSET " ]; then
    ok "pro download 2: the free checksum files are asked for first, the program last, each with the key"
else
    bad "pro download 2: $reqs"
fi

: > "$DL/log"
out=$(printf 'BAD-KEY-12345\n' | dlenv "$W/links/qc" pro install --key - 2>&1)
status=$?
if [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q 'this licence key is not valid; nothing installed' && ! printf '%s' "$out" | grep -q 'pro stub' \
    && ! printf '%s' "$out" | grep -qi 'accepted' \
    && [ "$(wc -l < "$DL/log" | tr -d ' ')" = "1" ] && [ "$(dl_left)" = "0" ]; then
    ok "pro download 3: an invalid key stops at the first free file, before the program is downloaded, and nothing is left behind"
else
    bad "pro download 3: status $status: $out (requests: $(wc -l < "$DL/log"))"
fi

out=$(printf 'LIMIT-KEY-1234\n' | dlenv "$W/links/qc" pro install --key - 2>&1)
status=$?
if [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q 'too many downloads today' && [ "$(dl_left)" = "0" ]; then
    ok "pro download 4: the daily limit is reported and cleaned up"
else
    bad "pro download 4: status $status: $out"
fi
out=$(printf 'DOWN-KEY-12345\n' | dlenv "$W/links/qc" pro install --key - 2>&1)
status=$?
if [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q 'licence service is not available right now'; then
    ok "pro download 5: an outage is reported and nothing is installed"
else
    bad "pro download 5: status $status: $out"
fi
out=$(printf 'NOREL-KEY-1234\n' | dlenv "$W/links/qc" pro install --key - 2>&1)
status=$?
if [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q 'no Pro release for this machine yet'; then
    ok "pro download 6: no release yet is reported"
else
    bad "pro download 6: status $status: $out"
fi

out=$(PTY_PROMPT="Licence key:" python3 "$HERE/pty_uninstall.py" VALID-TYPED-KEY1 env HOME="$W/home" TMPDIR="$DL/tmp" QUIETCLAUDE_PRO_BASE="http://127.0.0.1:$DLPORT" "$W/links/qc" pro install 2>&1)
if printf '%s' "$out" | grep -q 'exit=0' && printf '%s' "$out" | grep -q 'pro stub key: VALID-TYPED-KEY1' && ! printf '%s' "$out" | grep -v 'pro stub key' | grep -q 'VALID-TYPED-KEY1'; then
    ok "pro download 7: with nothing else given it asks for the key at the terminal, and the key is not shown as you type"
else
    bad "pro download 7: $out"
fi

mkdir -p "$W/home/.quietclaude"
printf 'VALID-SAVED-KEY\n' > "$W/home/.quietclaude/license"
out=$(dlenv "$W/links/qc" pro install 2>&1 < /dev/null)
status=$?
if [ "$status" -eq 0 ] && printf '%s' "$out" | grep -qF "Using the saved licence key VALI$(printf '\342\200\246')-KEY (from ~/.quietclaude/license)" && printf '%s' "$out" | grep -q 'pro stub key: VALID-SAVED-KEY' \
    && ! printf '%s' "$out" | grep -v 'pro stub key' | grep -q 'VALID-SAVED-KEY' && printf '%s' "$out" | grep -q '^Licence key accepted\.$'; then
    ok "pro download 8: a key kept by an earlier install is reused without asking, shown with its middle hidden, and reported as accepted"
else
    bad "pro download 8: status $status: $out"
fi
rm -rf "$W/home/.quietclaude"

: > "$DL/log"
out=$(python3 "$HERE/pty_uninstall.py" none env HOME="$W/home" TMPDIR="$DL/tmp" QUIETCLAUDE_PRO_BASE="http://127.0.0.1:$DLPORT" "$W/links/qc" pro install 2>&1)
if printf '%s' "$out" | grep -q 'exit=2' && printf '%s' "$out" | grep -q 'a licence key is needed' && [ ! -s "$DL/log" ]; then
    ok "pro download 9: no key and no terminal is a clear error and nothing is requested"
else
    bad "pro download 9: $out"
fi

out=$(printf 'bad"key with spaces\n' | dlenv "$W/links/qc" pro install --key - 2>&1)
status=$?
out2=$(printf 'short\n' | dlenv "$W/links/qc" pro install --key - 2>&1)
if [ "$status" -eq 2 ] && printf '%s' "$out" | grep -q 'does not look like a licence key' && printf '%s' "$out2" | grep -q 'does not look like a licence key' && [ ! -s "$DL/log" ]; then
    ok "pro download 10: a key with odd characters or the wrong length never reaches curl or the server"
else
    bad "pro download 10: $status $out / $out2"
fi

mkdir -p "$W/shim"
REALCURL=$(command -v curl)
cat > "$W/shim/curl" <<SCRIPT
#!/bin/sh
printf '%s\n' "\$@" >> "$W/curl.args"
exec "$REALCURL" "\$@"
SCRIPT
chmod 755 "$W/shim/curl"
: > "$W/curl.args"
out=$(printf 'VALID-SECRET-9876\n' | PATH="$W/shim:$PATH" dlenv "$W/links/qc" pro install --key - 2>&1)
if printf '%s' "$out" | grep -q 'pro stub key: VALID-SECRET-9876' && [ -s "$W/curl.args" ] && ! grep -q 'VALID-SECRET-9876' "$W/curl.args" && grep -qx -- '-K' "$W/curl.args"; then
    ok "pro download 11: the key is never in curl's arguments (it goes through curl's config on standard input)"
else
    bad "pro download 11: $(cat "$W/curl.args" | tr '\n' ' ')"
fi

out=$(printf 'VALID-KEY-1234\n' | env HOME="$W/home" TMPDIR="$DL/tmp" QUIETCLAUDE_PRO_BASE="http://example.com" "$W/links/qc" pro install --key - 2>&1)
status=$?
if [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q 'must start with https://'; then
    ok "pro download 12: plain http is refused except for a local test server"
else
    bad "pro download 12: status $status: $out"
fi

out=$(printf 'VALID-KEY-1234\n' | dlenv env PATH="$W/nocurl" "$W/links/qc" pro install --key - 2>&1)
status=$?
if [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q 'curl is needed' && [ "$(dl_left)" = "0" ]; then
    ok "pro download 13: without curl it says so and cleans up"
else
    bad "pro download 13: status $status: $out"
fi

out=$(printf 'VALID-KEY-1234\n' | STUB_EXIT=3 dlenv "$W/links/qc" pro install --key - 2>&1)
status=$?
if [ "$status" -eq 3 ] && [ "$(dl_left)" = "0" ]; then
    ok "pro download 14: the installer's exit status is passed on and the temporary folder is removed"
else
    bad "pro download 14: status $status (left: $(dl_left))"
fi

out=$(dlenv "$W/links/qc" pro install VALID-KEY-1234 2>&1 < /dev/null)
status=$?
if [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q 'is not a file'; then
    ok "pro download 15: a file argument still takes the old route (install from a file you have)"
else
    bad "pro download 15: status $status: $out"
fi

: > "$DL/log"
for badbase in "http://127.0.0.1.evil.example" "http://localhost.evil.com" "http://127.0.0.1@evil.example"; do
    out=$(printf 'VALID-KEY-1234\n' | env HOME="$W/home" QUIETCLAUDE_PRO_BASE="$badbase" "$W/links/qc" pro install --key - 2>&1)
    status=$?
    if [ "$status" -ne 1 ] || ! printf '%s' "$out" | grep -q 'must start with https://'; then
        badhttp="$badbase: $status $out"
    fi
done
if [ -z "${badhttp-}" ] && [ ! -s "$DL/log" ]; then
    ok "pro download 16: addresses that only begin like 127.0.0.1 or localhost are refused, so the key is never sent in clear text to another host"
else
    bad "pro download 16: ${badhttp-}"
fi

mkdir -p "$W/curlhome"
printf 'fail\ninsecure\nverbose\n' > "$W/curlhome/.curlrc"
cp "$W/curlhome/.curlrc" "$W/home/.curlrc"
out=$(printf 'BAD-KEY-12345\n' | CURL_HOME="$W/curlhome" dlenv "$W/links/qc" pro install --key - 2>&1)
status=$?
rm -f "$W/home/.curlrc"
if [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q 'this licence key is not valid' && ! printf '%s' "$out" | grep -qi 'authorization'; then
    ok "pro download 17: the user's .curlrc is ignored (no fail, insecure or verbose changing the result or printing the key)"
else
    bad "pro download 17: status $status: $out"
fi

mkdir -p "$W/home/.quietclaude"
printf 'BAD-SAVED-KEY1\n' > "$W/home/.quietclaude/license"
out=$(dlenv "$W/links/qc" pro install 2>&1 < /dev/null)
status=$?
if [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q 'That was the key saved in ~/.quietclaude/license' && printf '%s' "$out" | grep -q 'qc pro install --key -'; then
    ok "pro download 18: a refused saved key says it was the saved one and how to give another"
else
    bad "pro download 18: status $status: $out"
fi

rm -f "$W/home/.quietclaude/license"
if command -v mkfifo >/dev/null 2>&1 && mkfifo "$W/home/.quietclaude/license" 2>/dev/null; then
    out=$(python3 -c "
import subprocess, sys
try:
    r = subprocess.run(sys.argv[1:], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=10, start_new_session=True)
    print(r.stdout.decode(), 'exit=%d' % r.returncode)
except subprocess.TimeoutExpired:
    print('TIMEOUT')
" env HOME="$W/home" QUIETCLAUDE_PRO_BASE="http://127.0.0.1:$DLPORT" "$W/links/qc" pro install)
    if printf '%s' "$out" | grep -q 'a licence key is needed' && ! printf '%s' "$out" | grep -q TIMEOUT; then
        ok "pro download 19: a FIFO where the saved key should be does not hang qc"
    else
        bad "pro download 19: $out"
    fi
    rm -f "$W/home/.quietclaude/license"
fi

printf 'VALID-LINKED-KEY\n' > "$W/linked-key"
ln -s "$W/linked-key" "$W/home/.quietclaude/license"
out=$(python3 "$HERE/pty_uninstall.py" none env HOME="$W/home" QUIETCLAUDE_PRO_BASE="http://127.0.0.1:$DLPORT" "$W/links/qc" pro install 2>&1)
if printf '%s' "$out" | grep -q 'a licence key is needed' && ! printf '%s' "$out" | grep -q 'pro stub'; then
    ok "pro download 20: a symlink in place of the saved key file is not followed"
else
    bad "pro download 20: $out"
fi
rm -rf "$W/home/.quietclaude" "$W/linked-key"

out=$(printf 'VALID-KEY-1234\n' | STUB_EXIT=3 dlenv sh -c 'trap "" CHLD; exec "$0" "$@"' "$W/links/qc" pro install --key - 2>&1)
status=$?
if [ "$status" -eq 3 ]; then
    ok "pro download 21: with SIGCHLD inherited as ignored, a failing installer is still reported as failing"
else
    bad "pro download 21: status $status: $out"
fi

mkdir -p "$W/ho\"me"
: > "$DL/log"
out=$(printf 'VALID-KEY-1234\n' | env HOME="$W/ho\"me" QUIETCLAUDE_PRO_BASE="http://127.0.0.1:$DLPORT" "$W/links/qc" pro install --key - 2>&1)
status=$?
if [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q 'character that is not allowed' && [ ! -s "$DL/log" ] && [ -z "$(find "$W/ho\"me" -mindepth 1 2>/dev/null)" ]; then
    ok "pro download 22: a quote or newline in the address or folder cannot add curl options, and nothing is left behind"
else
    bad "pro download 22: status $status: $out"
fi
rm -rf "$W/ho\"me"

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
