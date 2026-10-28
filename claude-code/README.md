# Claude Code status line (node-01)

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
