#!/bin/bash
# Claude Code status line: a header plus a stacked gauge block.
#   header       dir · branch · worktree · repo · PR · agent · model + mode · title
#   5h / wk / ctx  rate limits and context window on one compact line, with the
#                  burn-rate runway on whichever limit is closest
#   cpu usage, load average
#   mem / pwr / net  memory used, system power draw, network throughput
# Input: status-line JSON on stdin. Sensors come from /proc and /sys (Linux).

input=$(cat)

# One field per line, read in order. Values are flattened so no field can span
# lines; `read` in a loop (not word splitting) keeps empty fields aligned.
fields=()
while IFS= read -r value; do fields+=("$value"); done < <(
  printf '%s' "$input" | jq -r '
    def s: if . == null then "" else tostring end;
    def flat: s | gsub("[[:space:]]+"; " ");
    [ (.workspace.current_dir // .cwd // "")
    , (.model.display_name | s)
    , (.rate_limits.five_hour.used_percentage | s)
    , (.rate_limits.five_hour.resets_at | s)
    , (.rate_limits.seven_day.used_percentage | s)
    , (.rate_limits.seven_day.resets_at | s)
    , (.context_window.used_percentage | s)
    , (.context_window.total_input_tokens | s)
    , (.context_window.context_window_size | s)
    , (.cost.total_cost_usd | s)
    , (.session_id // "default")
    , (.session_name | s)
    , (.agent.name | s)
    , (.pr.number | s)
    , (.pr.review_state // (if .pr then "pending" else null end) | s)
    , (.worktree.name // (.workspace.git_worktree | if . then sub(".*/"; "") else null end) | s)
    , (.workspace.added_dirs | if . then length else 0 end | s)
    , (.effort.level | s)
    , (.fast_mode | s)
    , (.thinking.enabled | s)
    , (.output_style.name | s)
    , (.workspace.repo | if type == "object" then ((.owner // "") + "/" + (.name // "")) else "" end)
    ] | map(flat) | .[]'
)

cwd=${fields[0]}
model=${fields[1]}
fh_pct=${fields[2]}
fh_reset=${fields[3]}
wk_pct=${fields[4]}
wk_reset=${fields[5]}
ctx_pct=${fields[6]}
ctx_tok=${fields[7]}
ctx_size=${fields[8]}
cost=${fields[9]}
sid=${fields[10]:-default}
session_name=${fields[11]}
agent_name=${fields[12]}
pr_num=${fields[13]}
pr_state=${fields[14]}
wt_name=${fields[15]}
added_dirs=${fields[16]}
effort=${fields[17]}
fast=${fields[18]}
thinking=${fields[19]}
style=${fields[20]}
repo=${fields[21]}

now=$(date +%s)

# Three weights of grey carry the hierarchy: BRT anchors, DIM labels, FNT recedes.
BRT=$'\033[38;5;252m'
DIM=$'\033[38;5;245m'
FNT=$'\033[38;5;239m'
ACC=$'\033[38;5;110m'
OK=$'\033[38;5;114m'
WARN=$'\033[38;5;179m'
HOT=$'\033[38;5;204m'
OFF=$'\033[0m'

GAP="  "                       # within a line: two spaces, no pipes
BAR_W=9
MINI_BAR_W=5                   # 5h / wk / ctx share one line, so their bars shrink

# Color by fill level: <60% ok, <85% warn, else hot.
tone() {
  local p=${1%%.*}
  if   [ "${p:-0}" -ge 85 ]; then printf '%s' "$HOT"
  elif [ "${p:-0}" -ge 60 ]; then printf '%s' "$WARN"
  else printf '%s' "$OK"
  fi
}

# A continuous rule: heavy where used, hairline where free.
# Args: percent (empty = unknown), fill-color, width (defaults to BAR_W)
bar() {
  local p=${1%%.*} c=$2 w=${3:-$BAR_W} filled i out=""
  [ -z "$p" ] && p=0
  [ "$p" -gt 100 ] && p=100
  filled=$(( (p * w + 50) / 100 ))
  [ "$filled" -eq 0 ] && [ "$p" -gt 0 ] && filled=1
  [ "$filled" -gt 0 ] && out+="$c"
  for ((i = 0; i < filled; i++)); do out+="━"; done
  [ "$filled" -lt "$w" ] && out+="$FNT"
  for ((i = filled; i < w; i++)); do out+="─"; done
  printf '%s' "$out"
}

# Reset clock: HH:MM, or just the weekday once it's more than a day out.
clock() {
  local at=${1%%.*} delta
  [ -z "$at" ] && return
  delta=$(( at - now ))
  if [ "$delta" -gt 86400 ]; then
    date -d "@$at" "+%a" 2>/dev/null
  else
    date -d "@$at" "+%H:%M" 2>/dev/null
  fi
}

# Coarse duration: 45m / 2h10m / 3d
humanize() {
  local s=$1
  if   [ "$s" -ge 172800 ]; then printf '%dd' $(( s / 86400 ))
  elif [ "$s" -ge 3600 ];   then printf '%dh%02dm' $(( s / 3600 )) $(( (s % 3600) / 60 ))
  else printf '%dm' $(( (s + 59) / 60 ))
  fi
}

# Compact token count: 950 / 118k / 1M
tokens() {
  local t=${1%%.*}
  [ -z "$t" ] && return
  if [ "$t" -ge 1000000 ]; then
    awk -v t="$t" 'BEGIN { m = t / 1000000; printf (m == int(m) ? "%dM" : "%.1fM"), m }'
  elif [ "$t" -ge 1000 ]; then printf '%dk' $(( (t + 500) / 1000 ))
  else printf '%d' "$t"
  fi
}

# Trim to a fixed budget so a long name can't shove the line around.
clip() {
  local s=$1 n=$2
  if [ ${#s} -gt "$n" ]; then printf '%s…' "${s:0:$(( n - 1 ))}"; else printf '%s' "$s"; fi
}

NOTE_W=6

# The note column holds a reset clock on limit rows and a temperature on sensor
# rows. printf pads by bytes, which over-counts multibyte glyphs (↻ is 3 bytes,
# ° is 2), so callers pass the visible width instead of relying on %-*s.
# Args: text, visible-width, color
note() {
  local text=$1 w=$2 c=$3 i
  [ -n "$text" ] && printf '%s%s%s' "$c" "$text" "$OFF"
  for ((i = w; i < NOTE_W; i++)); do printf ' '; done
}

blank_note() { note "" 0 ""; }
text_note()  { note "$1" "${#1}" "$2"; }
reset_note() {
  local t; t=$(clock "$1")
  [ -z "$t" ] && { blank_note; return; }
  note "↻$t" $(( ${#t} + 1 )) "$FNT"
}

# Unpadded reset clock, for inline use on the combined 5h/wk/ctx line.
inline_clock() {
  local t; t=$(clock "$1")
  [ -n "$t" ] && printf '%s↻%s%s' "$FNT" "$t" "$OFF"
}

# One gauge row of the stacked block. The bar is always exactly 9 glyphs and the
# note arrives pre-padded, so every column lines up:
#   label(4) bar(9) ␣␣␣ pct(4) ␣␣␣ note(6) ␣␣ trailing
# Args: label, percent, note, trailing
row() {
  local label=$1 pct=$2 note_txt=$3 trail=$4 c
  printf '%s%-4s%s' "$DIM" "$label" "$OFF"
  if [ -z "$pct" ]; then
    printf '%s   %s  --%s' "$(bar "" "$FNT")" "$FNT" "$OFF"
  else
    c=$(tone "$pct")
    printf '%s   %s%3.0f%%%s' "$(bar "$pct" "$c")" "$c" "$pct" "$OFF"
  fi
  printf '   %s' "$note_txt"
  [ -n "$trail" ] && printf '  %s' "$trail"
}

# A condensed gauge for the combined 5h / wk / ctx line: label, mini bar,
# percentage, then whatever extra text (reset clock, token count, runway
# warning) the caller has already formatted and space-joined.
# Args: label, percent, extra (pre-formatted, may be empty)
compact_gauge() {
  local label=$1 pct=$2 extra=$3 c
  printf '%s%s%s ' "$DIM" "$label" "$OFF"
  if [ -z "$pct" ]; then
    printf '%s %s--%s' "$(bar "" "$FNT" "$MINI_BAR_W")" "$FNT" "$OFF"
  else
    c=$(tone "$pct")
    printf '%s %s%3.0f%%%s' "$(bar "$pct" "$c" "$MINI_BAR_W")" "$c" "$pct" "$OFF"
  fi
  [ -n "$extra" ] && printf ' %s' "$extra"
}

# ── machine ───────────────────────────────────────────────────────────────
# Linux: everything comes from /proc and /sys. CPU %, network rate and power are
# counters, so they need a delta against the previous render's sample, kept in
# STATE_DIR. Renders closer than 2s apart reuse the last computed rates, so a
# burst of redraws can't divide by a near-zero interval.
STATE_DIR="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/claude-statusline"
mkdir -p "$STATE_DIR" 2>/dev/null
MACHINE_STATE="$STATE_DIR/machine"
PWR_SCALE=40                  # watts mapped to a full bar (display scale only)
# Power comes from the power-logger service (homelab/bin/power-logger-ctl.sh):
# "ts sys_w src month_kwh fan_pct", src e = estimated.
POWER_LATEST=/srv/data/power/latest

read -r load1 _ < /proc/loadavg
mem_pct="" mem_used="" mem_total=""
read -r mem_pct mem_used mem_total < <(
  awk '/^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 }
       END { if (t > 0) printf "%d %.1f %.0f\n", (t - a) * 100 / t, (t - a) / 1048576, t / 1048576 }' /proc/meminfo
)

cpu_pct="" rx_rate="" tx_rate=""
read -r cpu_pct rx_rate tx_rate < <(
  { cat "$MACHINE_STATE" 2>/dev/null || echo; head -n 1 /proc/stat; cat /proc/net/dev; } |
  awk -v now="$(date +%s.%N)" -v out="$MACHINE_STATE" '
    NR == 1 { pt = $1; pi = $2; ptot = $3; prx = $4; ptx = $5
              pc = $6; prr = $7; ptr = $8; next }
    /^cpu / { for (i = 2; i <= NF; i++) tot += $i; idle = $5 + $6; next }
    /:/     { sub(/^ */, ""); split($0, f, /[: ]+/)
              if (f[1] != "lo") { rx += f[2]; tx += f[10] }; next }
    END {
      dt = now - pt
      if (pt == "" || dt < 2) {                  # too soon: keep last rates
        if (pt != "") { printf "%s %s %s\n", pc, prr, ptr; exit }
        cpu = rr = tr = "-"
      } else {
        dtot = tot - ptot
        cpu = dtot > 0 ? sprintf("%d", (1 - (idle - pi) / dtot) * 100) : "-"
        rr  = rx >= prx ? sprintf("%d", (rx - prx) / dt) : "-"
        tr  = tx >= ptx ? sprintf("%d", (tx - ptx) / dt) : "-"
      }
      printf "%s %s %s %s %s %s %s %s\n", now, idle, tot, rx, tx, cpu, rr, tr > out
      printf "%s %s %s\n", cpu, rr, tr
    }'
)
[ "$cpu_pct" = - ] && cpu_pct=""
sys_pwr="" pwr_src="" month_kwh="" fan_pct=""
if [ -r "$POWER_LATEST" ]; then
  read -r pwr_t sys_pwr pwr_src month_kwh fan_pct < "$POWER_LATEST"
  # A stopped logger must not show a frozen reading as live.
  [ $(( now - ${pwr_t:-0} )) -gt 90 ] && sys_pwr=""
  [ "$sys_pwr" = - ] && sys_pwr=""
  [ "$fan_pct" = - ] && fan_pct=""
fi

cpu_temp=""
for z in /sys/class/thermal/thermal_zone*; do
  [ "$(cat "$z/type" 2>/dev/null)" = x86_pkg_temp ] && { cpu_temp=$(( $(< "$z/temp") / 1000 )); break; }
done

# Bytes/sec → 850B/s, 45K/s, 1.2M/s
rate() {
  [ -z "$1" ] || [ "$1" = - ] && { printf -- '--'; return; }
  awk -v b="$1" 'BEGIN {
    if (b >= 1048576) printf "%.1fM/s", b / 1048576
    else if (b >= 1024) printf "%dK/s", b / 1024
    else printf "%dB/s", b }'
}

temp_note() {
  [ -z "$1" ] && { blank_note; return; }
  local c=$FNT
  [ "$1" -ge 80 ] && c=$WARN
  [ "$1" -ge 95 ] && c=$HOT
  note "${1}°C" $(( ${#1} + 2 )) "$c"
}

# ── burn rate ─────────────────────────────────────────────────────────────
# Samples (epoch, 5h%, wk%) are appended at most once a minute to a per-session
# file, then linearly extrapolated to see which limit runs out of runway first.
state="$STATE_DIR/${sid//[^A-Za-z0-9_-]/_}"

record_sample() {
  [ -z "$fh_pct$wk_pct" ] && return
  mkdir -p "$STATE_DIR" 2>/dev/null || return
  local last_t=0 last_fh=0 last_wk=0
  if [ -s "$state" ]; then
    read -r last_t last_fh last_wk < <(tail -n 1 "$state")
    # A limit window rolled over — drop history so the stale slope isn't reused.
    if awk -v a="${fh_pct:-0}" -v b="$last_fh" -v c="${wk_pct:-0}" -v d="$last_wk" \
         'BEGIN { exit !(a < b - 1 || c < d - 1) }'; then
      : > "$state"
      last_t=0
    fi
  fi
  [ $(( now - last_t )) -lt 60 ] && return
  printf '%s %s %s\n' "$now" "${fh_pct:-0}" "${wk_pct:-0}" >> "$state"
  if [ "$(wc -l < "$state")" -gt 240 ]; then
    tail -n 180 "$state" > "$state.tmp" && mv "$state.tmp" "$state"
  fi
}

# Prints "<label> <runway-seconds>" for the limit closest to exhaustion, or nothing.
project() {
  [ -s "$state" ] || return
  awk -v now="$now" -v fh="$fh_pct" -v wk="$wk_pct" \
      -v fh_reset="${fh_reset:-0}" -v wk_reset="${wk_reset:-0}" '
    { t[NR] = $1; a[NR] = $2; b[NR] = $3 }
    END {
      if (NR < 1) exit
      split("5h wk", name, " ")
      best_label = ""; best_eta = 0
      for (k = 1; k <= 2; k++) {
        cur    = (k == 1 ? fh : wk)
        reset  = (k == 1 ? fh_reset : wk_reset)
        window = (k == 1 ? 2700 : 10800)   # 5h moves fast; weekly needs a longer arm
        if (cur == "") continue
        # oldest sample still inside the window
        i = NR
        for (j = 1; j <= NR; j++) if (now - t[j] <= window) { i = j; break }
        span = now - t[i]
        used = cur - (k == 1 ? a[i] : b[i])
        if (span < 300 || used <= 0.1) continue   # too little signal to extrapolate
        eta = (100 - cur) * span / used
        if (eta <= 0 || eta > 21600) continue           # more than 6h out: not actionable
        if (reset > 0 && now + eta >= reset) continue   # resets before it caps
        if (best_label == "" || eta < best_eta) { best_label = name[k]; best_eta = eta }
      }
      if (best_label != "") printf "%s %d\n", best_label, best_eta
    }' "$state"
}

# ── line 1: place ─────────────────────────────────────────────────────────
dir=${cwd##*/}
branch=""
[ -n "$cwd" ] && branch=$(git -C "$cwd" branch --show-current 2>/dev/null)

top="${BRT}${dir}${OFF}"
[ -n "$branch" ] && top+="${GAP}${DIM}⎇ $(clip "$branch" 28)${OFF}"
[ -n "$wt_name" ] && [ "$wt_name" != "$dir" ] && top+="${GAP}${WARN}⧉ ${wt_name}${OFF}"
# Repo slug only when it isn't just the directory name again.
[ -n "$repo" ] && [ "${repo##*/}" != "$dir" ] && top+="${GAP}${FNT}${repo}${OFF}"
[ "${added_dirs:-0}" -gt 0 ] 2>/dev/null && top+="${GAP}${FNT}+${added_dirs}${OFF}"

if [ -n "$pr_num" ]; then
  case $pr_state in
    approved)          pr_mark="✓"; pr_col=$OK ;;
    changes_requested) pr_mark="✗"; pr_col=$HOT ;;
    draft)             pr_mark="◌"; pr_col=$FNT ;;
    *)                 pr_mark="◔"; pr_col=$WARN ;;
  esac
  top+="${GAP}${pr_col}#${pr_num} ${pr_mark}${OFF}"
fi

[ -n "$agent_name" ] && top+="${GAP}${WARN}⚙ $(clip "$agent_name" 20)${OFF}"

if [ -n "$model" ]; then
  top+="${GAP}${ACC}◆ ${model}${OFF}"
  [ -n "$effort" ] && top+="${FNT}·${effort}${OFF}"
  [ "$fast" = true ] && top+=" ${HOT}⚡${OFF}"
  [ "$thinking" = false ] && top+=" ${WARN}no-think${OFF}"
fi
[ -n "$style" ] && [ "$style" != default ] && top+="${GAP}${FNT}${style}${OFF}"
# Title last: it's the longest and most volatile field, so truncation lands here.
[ -n "$session_name" ] && top+="${GAP}${FNT}$(clip "$session_name" 32)${OFF}"

# ── the gauge block: one row per limit ────────────────────────────────────
record_sample
read -r runway_label runway_eta <<<"$(project)"

# The warning rides on the row of the limit it belongs to, so it needs no label.
warn_for() {
  [ "$runway_label" = "$1" ] || return
  local c=$WARN
  [ "$runway_eta" -lt 1800 ] && c=$HOT
  printf '%s⚠ runway %s%s' "$c" "$(humanize "$runway_eta")" "$OFF"
}

ctx_trail=""
[ -n "$ctx_tok" ] && [ -n "$ctx_size" ] &&
  ctx_trail="${FNT}$(tokens "$ctx_tok")/$(tokens "$ctx_size")${OFF}"
if [ -n "$cost" ] && awk -v c="$cost" 'BEGIN { exit !(c > 0.005) }'; then
  [ -n "$ctx_trail" ] && ctx_trail+="  "
  ctx_trail+="${FNT}$(printf '$%.2f' "$cost")${OFF}"
fi

# Power has no natural percentage, so the bar is scaled to PWR_SCALE watts; the
# wattage itself is the real datum and sits in the note column.
pwr_pct="" pwr_txt=""
if [ -n "$sys_pwr" ]; then
  pwr_pct=$(awk -v w="$sys_pwr" -v m="$PWR_SCALE" \
    'BEGIN { p = w / m * 100; printf "%d", (p > 100 ? 100 : p) }')
  pwr_txt=$(awk -v w="$sys_pwr" -v e="$pwr_src" 'BEGIN { printf "%s%.1fW", (e == "e" ? "~" : ""), w }')
fi
fan_trail=""
[ -n "$month_kwh" ] && fan_trail="${FNT}$(awk -v k="$month_kwh" 'BEGIN { if (k < 1) printf "%.0fWh", k * 1000; else printf "%.2fkWh", k }') $(date +%b)${OFF}"
[ -n "$fan_pct" ] && fan_trail+="  ${FNT}fan ${fan_pct}%${OFF}"

# 5h, wk and ctx share a single line: each is a mini gauge, and any reset
# clock / token count / runway warning rides along as inline extra text.
fh_extra="$(inline_clock "$fh_reset")"
wk_extra="$(inline_clock "$wk_reset")"
fh_warn="$(warn_for 5h)"
wk_warn="$(warn_for wk)"
[ -n "$fh_warn" ] && fh_extra="${fh_extra:+$fh_extra }$fh_warn"
[ -n "$wk_warn" ] && wk_extra="${wk_extra:+$wk_extra }$wk_warn"

usage="$(compact_gauge 5h  "$fh_pct"  "$fh_extra")${GAP}"
usage+="$(compact_gauge wk  "$wk_pct"  "$wk_extra")${GAP}"
usage+="$(compact_gauge ctx "$ctx_pct" "$ctx_trail")"

# Every row always renders, so the block never changes height.
r4="$(row cpu "$cpu_pct" "$(temp_note "$cpu_temp")"       "${FNT}load ${load1}${OFF}")"
r6="$(row mem "$mem_pct" "$(blank_note)"                  "${FNT}${mem_used}G/${mem_total}G${OFF}")"
r7="$(row pwr "$pwr_pct" "$(text_note "$pwr_txt" "$FNT")" "$fan_trail")"
r8="$(printf '%s%-4s%s%s↓ %-8s ↑ %s%s' "$DIM" net "$OFF" "$FNT" "$(rate "$rx_rate")" "$(rate "$tx_rate")" "$OFF")"

# A space-only spacer row: terminals have no line-height, so breathing room has
# to be an actual line. Emptying it entirely would collapse to zero height.
printf '%s\n \n%s\n%s\n%s\n%s\n%s' \
  "$top" "$usage" "$r4" "$r6" "$r7" "$r8"
