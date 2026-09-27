#!/usr/bin/env python3
"""Log this machine's estimated whole-system power draw as a monthly CSV.

Nothing on this laptop measures system draw: the AC adapter reports only
online/offline, and the battery (the only whole-system gauge a laptop has)
is dead. So sys_w is an ESTIMATE:

    sys_w = cpu_w + BASE_W + backlight_w + fan_w

cpu_w is MEASURED from the RAPL package counter (root-only, hence a root
service); it is the part that moves with load. BASE_W is everything else
(HDD, chipset, RAM, Wi-Fi, panel electronics) and is a guess, so it is a knob:
set POWER_BASE_W in the unit. Check it once against a wall meter if you can.

backlight_w = BACKLIGHT_MAX_W * brightness / max_brightness, and 0 when
bl_power reports it off. It is modelled separately because the backlight is
the one non-CPU load that changes (and it stays lit behind a closed lid,
since logind ignores the lid on this node).
For a true reading, a metering smart plug is the only option.

The fan has no Linux driver; its tachometer lives in the embedded controller
at 0xB2 (RPM1 in the DSDT), found by probing under load. It holds a PERIOD,
so it falls as speed rises: ~190 idle, ~40 at full speed (held under
sustained all-core load). fan_pct = FAN_FULL_PERIOD / period, and
fan_w = FAN_MAX_W * fan_pct^3 (fan affinity law). The EC is read over
/dev/port with the standard ACPI read command (0x80), as nbfc-linux does,
because Debian's kernel lacks ec_sys. Read-only, one byte per interval.

Files in DATA_DIR (delete any whenever; the logger starts over):
  YYYY-MM.csv   ts,cpu_w,fan_pct,sys_w,sys_wh   one row per interval
  latest        "ts sys_w e month_kwh fan_pct"  read by the status line (e = estimated)
"""
import csv, glob, os, time

DATA_DIR = os.environ.get("POWER_DATA_DIR", "/srv/data/power")
BASE_W = float(os.environ.get("POWER_BASE_W", "6"))
FAN_MAX_W = float(os.environ.get("POWER_FAN_MAX_W", "2.5"))  # 5V x 0.5A
BACKLIGHT_MAX_W = float(os.environ.get("POWER_BACKLIGHT_MAX_W", "4"))  # 15.6" LED at full
INTERVAL = 30
RAPL = "/sys/class/powercap/intel-rapl:0"
EC_FAN_REG = 0xB2
FAN_FULL_PERIOD = 40     # ponytail: measured once; re-probe if the fan is replaced


def read(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return None


def ec_read(addr):
    """One EC byte via /dev/port (ACPI EC read, 0x80). None if the EC is busy."""
    def wait(port, mask, want):
        for _ in range(10000):
            port.seek(0x66)
            if (port.read(1)[0] & mask) == want:
                return True
        return False
    try:
        with open("/dev/port", "r+b", buffering=0) as port:
            if not wait(port, 0x02, 0):
                return None
            port.seek(0x66); port.write(b"\x80")
            if not wait(port, 0x02, 0):
                return None
            port.seek(0x62); port.write(bytes([addr]))
            if not wait(port, 0x01, 0x01):
                return None
            port.seek(0x62)
            return port.read(1)[0]
    except OSError:
        return None


def backlight_w():
    for bl in glob.glob("/sys/class/backlight/*"):
        b, m = read(f"{bl}/brightness"), read(f"{bl}/max_brightness")
        if read(f"{bl}/bl_power") not in (None, "0") or not b or not m or int(m) == 0:
            return 0.0
        return BACKLIGHT_MAX_W * int(b) / int(m)
    return 0.0


def fan_pct():
    for _ in range(3):           # the EC is sometimes busy with the kernel's own traffic
        period = ec_read(EC_FAN_REG)
        if period and period != 0xFF:
            return min(100.0, FAN_FULL_PERIOD / period * 100)
        time.sleep(0.05)
    return None                  # stopped, or unreadable


def month_wh(path):
    """Re-derive the month's total from the CSV, so restarts don't lose it."""
    wh = 0.0
    try:
        with open(path) as f:
            for row in csv.DictReader(f):
                wh += float(row["sys_wh"] or 0)
    except (OSError, ValueError, KeyError):
        pass
    return wh


def main():
    os.makedirs(DATA_DIR, exist_ok=True)
    wrap = int(read(f"{RAPL}/max_energy_range_uj") or 0)
    prev_e, prev_t = read(f"{RAPL}/energy_uj"), time.time()
    month, total_wh = None, 0.0

    while True:
        time.sleep(INTERVAL)
        now = time.time()
        e, dt = read(f"{RAPL}/energy_uj"), now - prev_t
        cpu_w = None
        if e is not None and prev_e is not None and dt > 0:
            d = int(e) - int(prev_e)
            if d < 0:
                d += wrap        # counter wrapped
            cpu_w = d / dt / 1e6
        prev_e, prev_t = e, now
        if cpu_w is None:
            continue             # no reading: record nothing rather than a guess
        fan = fan_pct()
        fan_w = FAN_MAX_W * (fan / 100) ** 3 if fan is not None else 0.0

        sys_w = cpu_w + BASE_W + backlight_w() + fan_w
        sys_wh = sys_w * dt / 3600

        path = os.path.join(DATA_DIR, time.strftime("%Y-%m.csv", time.localtime(now)))
        if path != month or not os.path.exists(path):
            month, total_wh = path, month_wh(path)   # new month, restart, or file cleared
        total_wh += sys_wh

        new = not os.path.exists(path)
        with open(path, "a") as f:
            if new:
                f.write("ts,cpu_w,fan_pct,sys_w,sys_wh\n")
            fp = "" if fan is None else f"{fan:.0f}"
            f.write(f"{int(now)},{cpu_w:.2f},{fp},{sys_w:.2f},{sys_wh:.5f}\n")

        tmp = os.path.join(DATA_DIR, ".latest.tmp")
        with open(tmp, "w") as f:
            f.write(f"{int(now)} {sys_w:.2f} e {total_wh / 1000:.3f} {fp or '-'}\n")
        os.replace(tmp, os.path.join(DATA_DIR, "latest"))


if __name__ == "__main__":
    main()
