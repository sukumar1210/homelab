# Claude Code on node-01

Two things: the status line (below) and [`claude-later`](#claude-later).

`node-01.statusline.sh` is the Claude Code status line for node-01
(HP Pavilion g6, Debian 13). It renders:

```
algo-trading  ⎇ main  ◆ Opus 5.5·high  session-title

5h ━━━━─  88% ↻21:30  wk ━━━━━  94% ↻Mon  ctx ━━━━─  73% 728k/1M  $215.25
cpu ━────────    11%   66°C    load 0.67
mem ━━━━─────    40%           1.5G/4G
pwr ━━━━─────    43%   ~17.5W  21Wh Sep  fan 21%
net ↓ 21K/s    ↑ 21K/s
```

| Row | Source |
|---|---|
| `cpu` | `/proc/stat` delta between renders; temp from the `x86_pkg_temp` thermal zone; `/proc/loadavg` |
| `mem` | `/proc/meminfo` (`MemTotal - MemAvailable`) |
| `pwr` | `/srv/data/power/latest`, written by the `power-logger` service (`bin/power-logger-ctl.sh`). `~` = estimated. The bar is scaled to 40 W. |
| `net` | `/proc/net/dev` delta, all interfaces except `lo` |

CPU and network rates are deltas against the previous render, cached in
`$XDG_RUNTIME_DIR/claude-statusline/`, so the first render after a reboot
shows `--`. Without the power logger the `pwr` row shows `--`; everything
else still works.

## Replicate

1. Dependencies:

   ```
   sudo apt install -y jq git gawk python3
   ```

2. Install the script:

   ```
   cp ~/sources/homelab/claude-code/node-01.statusline.sh ~/.claude/statusline.sh
   chmod +x ~/.claude/statusline.sh
   ```

3. Point Claude Code at it: merge this into `~/.claude/settings.json`:

   ```json
   "statusLine": {
     "type": "command",
     "command": "~/.claude/statusline.sh",
     "padding": 0,
     "refreshInterval": 10
   }
   ```

   Or, with `jq`, in one command:

   ```
   f=~/.claude/settings.json; [ -f "$f" ] || echo '{}' > "$f"
   jq '.statusLine = {"type":"command","command":"~/.claude/statusline.sh","padding":0,"refreshInterval":10}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
   ```

4. Install the power logger (for the `pwr` row), and choose option 1:

   ```
   ~/sources/homelab/bin/power-logger-ctl.sh
   ```

   It runs as root (the RAPL counter and the EC are root-only), writes
   `/srv/data/power/YYYY-MM.csv` plus `latest`, and the data directory is
   owned by you so it can be cleared without sudo. Tuning knobs are in the
   unit: `POWER_BASE_W` (fixed non-CPU draw, default 6),
   `POWER_BACKLIGHT_MAX_W` (backlight at full brightness, default 4) and
   `POWER_FAN_MAX_W` (fan at full speed, default 2.5).

5. Check it renders:

   ```
   echo '{"workspace":{"current_dir":"'"$PWD"'"},"session_id":"t"}' | ~/.claude/statusline.sh
   ```

## Machine-specific bits

These are node-01 only and need rechecking on other hardware:

- **Power is an estimate.** No sensor measures whole-system draw here (the
  AC adapter reports only online/offline and the battery is dead):
  `sys_w = RAPL CPU package + POWER_BASE_W + backlight + fan`, with the
  backlight scaled by brightness and zero when `bl_power` says it is off.
- **Fan speed** is read from EC register `0xB2` (`RPM1` in the DSDT), which
  (with `0xB3` as the high byte, `RPM1`/`RPM2`) holds a 16-bit tach period: ~640 silent, ~296 at full speed. Another model will
  have a different register; see the docstring in
  `bin/service-scripts/power-logger.py`.
- **CPU temperature** uses the `x86_pkg_temp` thermal zone (Intel).

## claude-later

`claude-later` queues a message for a specific Claude session and delivers it
at a set time, like a delayed queue with one consumer per session. Claude
Code's own scheduled prompts live inside one session and die with it; these
are systemd user timers, so they fire after logout and after the session has
stopped.

```
homelab claude-later install           # copies it to ~/.local/bin/claude-later
claude-later 15:00 research-1 "check JPL depth and report"
claude-later "tomorrow 09:20" openalgo-fork-1 "run the gthread suite"
claude-later list                      # id, time, session, message
claude-later cancel <id>
journalctl --user -u 'claude-later-*'  # every delivery
```

`<when>` is anything `date -d` reads; a time already past is refused. The
session is the name `claude agents` shows, or its id.

**Delivery.** At the time, the timer runs `claude-later deliver <id>`, which
looks the session up in `claude agents --json --all`:

- **Running** (idle or busy): a throwaway `claude -p --model haiku` relays the
  message with SendMessage, the only way into a live session from outside it.
  The session sees a message from another session, prefixed `Queued message
  from the user (claude-later, <time>)`, and acts on it within its own
  permissions; it does not treat it as the user approving anything.
- **Stopped**: `claude --bg --resume <session id>` from the session's own
  directory continues it under the same id with the message as the next turn.

A failed delivery keeps its file in `~/.claude/later/`, so nothing is lost
silently; `homelab claude-later status` fails while any message is more than
five minutes past its time.

**Pitfalls found building it.** `claude --allowedTools` takes a list and
swallows a prompt placed after it, so the relay prompt goes on stdin.
`claude --bg` refuses a directory that has not been trusted. The timer's
environment lacks `~/.local/bin`, so the queuing shell's `PATH` is passed in.
