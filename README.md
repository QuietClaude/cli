# QuietClaude

QuietClaude starts Claude Code without the startup banner. No logo, no version line, no model
line, no working directory line. You get the prompt and nothing else, and whatever was on your
screen before stays there.

Everything else Claude Code prints comes through as it is. Trust prompts, settings warnings, the
first-run setup, notices, the whole interface. QuietClaude only removes the three banner lines.

Claude Code has no option to turn the banner off (see issues
[#21210](https://github.com/anthropics/claude-code/issues/21210) and
[#2254](https://github.com/anthropics/claude-code/issues/2254)). This is the missing switch.

## Install

One line, Linux or macOS:

```sh
curl -fsSL https://quietclaude.com/install.sh | sh
```

The script downloads the release for your machine, checks it against `SHA256SUMS`, and puts it in
`/usr/local/sbin` as `claude` with a `qc` link next to it. It asks for `sudo` only for that last
copy. To avoid `sudo`, pick a folder you own:

```sh
curl -fsSL https://quietclaude.com/install.sh | PREFIX="$HOME/bin" sh
```

Prefer to do it by hand? Download the file for your machine from the
[latest release](https://github.com/QuietClaude/cli/releases/latest) and check it against
`SHA256SUMS`. Then put it somewhere in your `PATH` ahead of Claude Code's own `claude`:

```sh
chmod +x quietclaude-linux-x86_64
sudo mv quietclaude-linux-x86_64 /usr/local/sbin/claude
sudo ln -s /usr/local/sbin/claude /usr/local/sbin/qc
hash -r
claude --version
```

Files are named `quietclaude-linux-x86_64`, `quietclaude-linux-arm64`,
`quietclaude-darwin-x86_64` and `quietclaude-darwin-arm64`.

Claude Code's own `claude` may still win if it sits earlier in your `PATH`. In that case add an
alias to your shell profile:

```sh
alias claude=/usr/local/sbin/claude
```

### Build it yourself

You need a C compiler and `make`. Linux and macOS are supported.

```sh
make
sudo make install
```

`make install` copies the binary to `/usr/local/sbin/claude` and adds a `qc` link next to it. You
can change the location with `PREFIX`, `DEST`, `ALIAS` (set it empty to skip the link) and
`SOURCE`:

```sh
PREFIX="$HOME/bin" make install
```

## Uninstall

One line, the same way you installed:

```sh
curl -fsSL https://quietclaude.com/uninstall.sh | sh
```

It removes the `claude` launcher and the `qc` link, and nothing else. Before it deletes a `claude`
it checks that the file is QuietClaude, so Claude Code's own `claude` is never touched. Afterwards
the name `claude` goes back to Claude Code. If you added an alias for it to your shell profile,
remove that line yourself.

If you installed into a folder of your own, name it again:

```sh
curl -fsSL https://quietclaude.com/uninstall.sh | PREFIX="$HOME/bin" sh
```

To see what it would remove without removing anything, add `DRY_RUN=1` the same way. It uses
`sudo` only when the folder is not yours to write to.

QuietClaude Pro keeps its licence, profiles and sync files in `~/.quietclaude`. The script leaves
that folder alone and tells you how to delete it. Pro profiles hold separate Claude logins, so
check before you remove it. From a clone, `make uninstall` runs the same script.

## Updating

The free launcher does not update itself. Run the install line again and you have the newest
version. `qc update` tells you the same thing.

## Use

Run `claude` or `qc` the way you always have. Every argument goes straight to Claude Code.

```sh
qc
qc --model opus
qc -p "summarise this repository"
claude update
```

`claude --version` shows which launcher is running and which Claude Code it found. Claude Code's
own version follows:

```
QuietClaude 0.1.0
  launcher:     /usr/local/sbin/claude
  claude code:  /home/you/.local/bin/claude
2.1.304 (Claude Code)
```

When the output is not a terminal, for example `claude -p "..." | cat` or a script, QuietClaude
steps aside and runs Claude Code directly.

## How it finds Claude Code

In this order:

1. `QUIETCLAUDE_CLAUDE_PATH`, if set.
2. `~/.local/bin/claude`, unless that is QuietClaude itself.
3. `~/.local/bin/claude.real`.
4. The first `claude` in your `PATH` that is not QuietClaude.

If nothing is found it tells you and exits with status 127.

## Settings

| Variable | What it does |
|---|---|
| `QUIETCLAUDE_CLAUDE_PATH` | Use this Claude Code binary and skip the search. |
| `QUIETCLAUDE_DEBUG=1` | Print what was removed, and when the watch stopped, on stderr. |
| `QUIETCLAUDE_PRO_PATH` | Where the Pro binary lives, if not `~/.quietclaude/pro`. |

Exit status is Claude Code's own. If Claude Code is killed by a signal you get 128 plus the signal
number. 127 means Claude Code was not found. 1 means QuietClaude itself failed, with one line on
stderr saying what went wrong.

## How it works

QuietClaude runs Claude Code inside a pseudoterminal and passes bytes between it and your
terminal. For the first few seconds it watches Claude Code's output for the banner block: three
lines that start with the logo colour and end with the banner's line ending. When it sees that
block it drops it. The watch window extends with every key you press, because the banner can come
after a dialog that waits for you. It opens again after a window resize, because Claude Code
redraws the banner then.

Nothing is ever held back for long. Bytes that cannot be part of a banner go to your terminal at
once, and anything undecided is released after 200 ms.

Before starting Claude Code, QuietClaude sets `CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1` so the
banner lands on the normal screen, and `CLAUDE_CODE_DISABLE_MOUSE_CLICKS=1` because the bridge is
meant for the keyboard.

## Tests

```sh
make test
```

The tests replay real Claude Code output recorded in `tests/fixtures/` through the filter, whole
and one byte at a time, and compare the result with `tests/expected/`. `tests/pty_check.py` runs
the built binary in a pseudoterminal and checks that the banner is gone and the rest is intact.

## Pro

The free launcher stays free and open source. QuietClaude Pro is a separate paid binary that adds
profiles for several Claude Code accounts, a header line you choose instead of the banner, config
sync between your machines, and `qc pro update`. Once it is installed, `qc` hands the Pro commands
and every normal launch over to it, so your default profile and header apply. If Pro cannot start,
`qc` says so and starts Claude Code anyway. `qc --version` and `qc update` stay with the free
launcher. Pro is not on sale yet; this section gets the link when it is.

## Licence

MIT. See `LICENSE`.
