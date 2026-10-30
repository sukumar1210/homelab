# homelab

The machine: how node-01 is laid out, what it needs, and the services that are the machine's own. One command manages
all of it:

```
~/sources/homelab/homelab              # status of everything; exit 1 if anything is wrong
~/sources/homelab/homelab node setup   # make the machine ready (the /srv layout, tools, docker group, linger)
~/sources/homelab/homelab update       # pull this checkout, then reinstall everything installed
~/sources/homelab/homelab <component> install|uninstall|update|status
```

## What this repository owns

| | What | Command |
|---|---|---|
| **Layout** | `/srv/sources` (code checkouts), `/srv/ops` (runtime state), `/srv/data` (data), each owned by you, linked as `~/sources`, `~/ops`, `~/data` | `homelab node check` / `setup` |
| **Tools** | git, make, python3, curl, jq, gawk, docker, git-lfs, restic | `homelab node setup` installs what is missing (apt) |
| **Settings** | you in the `docker` group; linger, so user services run while logged out and after a reboot | `homelab node setup` |
| **Disk space** | free space on `/`, `/srv` (with trading days left at the measured ~0.9 GB/day) and `/srv/archive`: warn under 30 GB (~six weeks), FAIL under 10 GB. The data sits on both `/srv` and the archive disk, so whichever fills first matters | `homelab node check` (part of `homelab status`) |
| `power-logger` | whole-system power and energy log, `/srv/data/power/` (`bin/power-logger-ctl.sh`) | `homelab power-logger install` |
| `mdns-bridge` | answers mDNS queries by unicast, for routers that do not forward multicast wired-to-Wi-Fi (`bin/mdns-bridge-ctl.sh`) | `homelab mdns-bridge install` |
| `nextboot` | queues the current OS as the next EFI boot (`bin/setup-nextboot.sh`) | `homelab nextboot install` |
| `backup` | a restic snapshot of `/srv/data` and the secrets to rebuild, every night at 17:30, onto the archive disk ([Backups](#backups)) | `homelab backup install` |
| `statusline` | the Claude Code status line ([claude-code/README.md](claude-code/README.md)) | `homelab statusline install` |
| `later` | runs a command or script, or sends a message to a Claude session, at a set time; a user timer per job, so it fires after logout ([later](#later)) | `homelab later install` |

`homelab status` checks more than "is it active": for each unit it checks that the file the unit runs **exists and is
this checkout's**. After the move to `/srv/sources`, `mdns-unicast-bridge.service` still ran
`/home/sukumar/bin/service-scripts/mdns-unicast-bridge.py`, which no longer existed, and restarted every few seconds
with nothing reporting it. `homelab <component> install` rewrites the unit from the current checkout. The old
per-component scripts still work on their own; with no argument they show their menu.

**Install, uninstall, update.** `install` is re-runnable, so it is also the reinstall (`reinstall` is accepted).
`uninstall` (or `remove`) takes the component off the machine and leaves its data. `update` fast-forwards this checkout
from GitHub, then the pulled `homelab` reinstalls: one component with `homelab <component> update`, or every installed
one with `homelab update`, skipping what is not installed. It reinstalls because a pull alone changes nothing that is
running: the services keep the code they started with until restarted, and `statusline` and `later` are copies. It
never merges: a checkout with local commits is refused. `homelab reinstall` does the reinstall without the pull. The
system services need sudo, so run it yourself. `./test_homelab.sh` checks all of this against stand-ins for sudo and
systemctl, changing nothing on the machine.

## Projects on this node

Each deploys itself from its own repository. This repository only prepares the machine they run on, and never
installs or restarts them.

| Project | Checkout | Set up / check |
|---|---|---|
| algo-trading (the paper runtime, its OpenAlgo container, the deploy pipeline and its runner) | `/srv/sources/algo-trading` | `deploy/setup_node.sh` |
| market-recorder (the tick recorder and the data collectors) | `/srv/sources/market-recorder` | `make install`, `make status` |

Run `homelab node setup` first: both of them check for what it provides (docker, linger, the layout) and refer back
here.

## Backups

**The archive disk.** The 500 GB HDD is mounted at `/srv/archive`, by UUID in `/etc/fstab` with `nofail`, so a dead
or unplugged disk cannot stop a boot. It holds the backup: `restic/`, the repository, and `stage/`, the consistent copy of
OpenAlgo's state each run makes. No data lives only here: the data stays on the SSD under `/srv/data`, so with the
backup it is on two disks. With the disk
missing, `/srv/archive` is an empty directory on `/srv`. The backup refuses to run then, rather than write the backup
onto the SSD it protects.

**What, when.** All the data under `/srv/data`, fetchable again or not, so the machine can be worked on without a
data subscription, plus the secrets needed to rebuild it: [`backup/include.txt`](backup/include.txt) minus
[`backup/exclude.txt`](backup/exclude.txt), which restic reads as they are. Left out is only what code derives from
that data and can rebuild offline (the research memo table and bar cubes): 12 GB, 8 GB of it rewritten each month,
which "monthly for ever" would otherwise keep permanently. It runs every night at 17:30, after the close
and the evening collectors, as the user timer `homelab-backup.timer`. Each night:
1. it stages OpenAlgo's state (SQLite through its online-backup API, since a copy of a live database file can tear);
2. it writes one snapshot;
3. it applies retention: 14 nightly, 8 weekly, and one a month for ever. First it clears locks left by a restic that
   was killed (only those whose process is gone), and it waits up to 30 minutes for a live one;
4. it reads back one seventh of the stored data and checks it against its hashes, so all of it is verified every week.

`backup/backup.py`'s docstring has the reasons.

**Is it working?** `homelab backup status` (also part of `homelab status`) judges by the age of the newest snapshot
(FAIL past 30 h) and the last run's result, not by the timer being enabled. A timer that fires every night into a
failing run is the silent failure a backup must not have.

**A failed run alerts** on Telegram and WhatsApp through OpenAlgo's notify API, where the node's other alerts go:
the key from `/srv/ops/secrets/openalgo.env`, the recipients (`ALERT_TELEGRAM_USER`, `ALERT_WHATSAPP_USERNAME`) from
`~/.config/homelab/alerts.env`. Without a WhatsApp username it goes to the chat OpenAlgo's `/update-here` named. An
alert never raises, and the run's log prints what each channel answered.

```
homelab backup status                        # newest snapshot, its age, how many are kept, repository size
homelab backup now                           # run it now and print its log
journalctl --user -u homelab-backup          # every run's output: files new/changed, data added, the check
homelab backup restic snapshots              # every snapshot: id, time, paths
homelab backup restic diff <id1> <id2>       # what changed between two nights
homelab backup restic ls latest /srv/data/market/data/2026-10-28
homelab backup restic restore latest --target /tmp/restore --include /srv/data/algo/orderbook
```

**Restoring OpenAlgo.** Its state is in the snapshot as `/srv/archive/stage/openalgo`, the consistent copy, not as
`/srv/data/openalgo`. Stop OpenAlgo, restore that path to a scratch directory, and copy it over the state directory.

**Not encrypted, and not off-site.** The repository sits in the same machine as the plaintext it copies. A password
would protect nothing here, and it would have to live on the SSD that the backup exists to outlive. Both disks share
one machine, so a fire, theft or power surge takes both copies. An off-site copy is a second repository with its own
password, filled by `restic copy`.

## later

`later` is a one-shot job queue: it runs something at a set time. Each job is a transient systemd user timer, so it
fires after logout and needs no long-running process.

```
homelab later install                       # copies bin/later to ~/.local/bin/later
later 15:00 run ./check.sh --quiet          # a script, from the current directory
later "tomorrow 09:20" run 'make status | tail -5 > /tmp/status.txt'
later 15:00 claude research-1 "check JPL depth and report"
later list                                  # id, time, kind, what
later cancel <id>
journalctl --user -u later-<id>             # a job's output and exit status
```

`<when>` is anything `date -d` reads; a time already past is refused. After `run`, one argument is a shell command line
(pipes, `&&`, redirects); several are a command and its arguments, kept exactly as given. A run job gets your `PATH` and
the directory you queued it from, not the rest of your shell's environment: a script that needs more sets it up itself.

**Claude jobs.** The session is the name `claude agents` shows, or its id; an unknown one fails at once, saying so. A
running session (any status: idle, busy, waiting) gets the message through SendMessage, relayed by a throwaway
`claude -p --model haiku`: the only way into a live session from outside it. The session sees a message from another
session, prefixed `Queued message from the user (later, <time>)`, and acts on it within its own permissions; it does not
take it as you approving anything. A stopped session is resumed with `claude --bg --resume <session id>` from its own
directory, under the same id. Claude Code's own scheduled prompts live inside one session and die with it; these do not.

**How delivery is judged.** Not by what the relay says: on 2026-10-29 it answered "SENT" for a message it had shortened
to its last word, and reported "SENT. The message reached..." for one it had delivered intact, which a strict match
counted as a failure. The relay writes its record as stream-json, and the job is done only when that record holds a
SendMessage call carrying exactly the job's text to that session, answered with success. A call that succeeded with
different text is logged with what was sent and not retried, so the session never gets the message twice. When nothing
reached the session the relay is tried again, three times in all, and each failed try logs the relay's last output.
`./test_later.sh` checks that judgement against relay records of each kind.

**Failures stay visible.** A job's file in `~/.local/state/later/` is removed only when the job succeeds. `later list`
marks one that is due and not done, and `homelab later status` fails while any is more than five minutes past its time.

**Pitfalls found building it.** `claude --allowedTools` takes a list and swallows a prompt placed after it, so the relay
prompt goes on stdin. `claude --bg` refuses a directory that has not been trusted. The timer's environment lacks
`~/.local/bin`, so the queuing shell's `PATH` is passed in.
