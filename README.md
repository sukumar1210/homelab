# homelab

The machine: how node-01 is laid out, what it needs, and the services that are the machine's own. One command manages
all of it:

```
~/sources/homelab/homelab              # status of everything; exit 1 if anything is wrong
~/sources/homelab/homelab node setup   # make the machine ready (the /srv layout, tools, docker group, linger)
~/sources/homelab/homelab <component> install|remove|status
```

## What this repository owns

| | What | Command |
|---|---|---|
| **Layout** | `/srv/sources` (code checkouts), `/srv/ops` (runtime state), `/srv/data` (data), each owned by you, linked as `~/sources`, `~/ops`, `~/data` | `homelab node check` / `setup` |
| **Tools** | git, make, python3, curl, jq, gawk, docker, git-lfs, restic | `homelab node setup` installs what is missing (apt) |
| **Settings** | you in the `docker` group; linger, so user services run while logged out and after a reboot | `homelab node setup` |
| `power-logger` | whole-system power and energy log, `/srv/data/power/` (`bin/power-logger-ctl.sh`) | `homelab power-logger install` |
| `mdns-bridge` | answers mDNS queries by unicast, for routers that do not forward multicast wired-to-Wi-Fi (`bin/mdns-bridge-ctl.sh`) | `homelab mdns-bridge install` |
| `nextboot` | queues the current OS as the next EFI boot (`bin/setup-nextboot.sh`) | `homelab nextboot install` |
| `backup` | a restic snapshot of `/srv/data` and the secrets to rebuild, every night at 17:30, onto the archive disk ([Backups](#backups)) | `homelab backup install` |
| `statusline` | the Claude Code status line ([claude-code/README.md](claude-code/README.md)) | `homelab statusline install` |

`homelab status` checks more than "is it active": for each unit it checks that the file the unit runs **exists and is
this checkout's**. After the move to `/srv/sources`, `mdns-unicast-bridge.service` still ran
`/home/sukumar/bin/service-scripts/mdns-unicast-bridge.py`, which no longer existed, and restarted every few seconds
with nothing reporting it. `homelab <component> install` rewrites the unit from the current checkout. The old
per-component scripts still work on their own; with no argument they show their menu.

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
or unplugged disk cannot stop a boot. It holds two things: `restic/`, the backup repository, and `history/`, the
1-minute history backfill (cold, write-once, and fetchable again, so it is not itself backed up). With the disk
missing, `/srv/archive` is an empty directory on `/srv`. The backup refuses to run then, rather than write the backup
onto the SSD it protects.

**What, when.** Everything under `/srv/data`, plus the secrets needed to rebuild the machine, listed in
[`backup/include.txt`](backup/include.txt), which restic reads as it is. It runs every night at 17:30, after the close
and the evening collectors, as the user timer `homelab-backup.timer`. Each night:
1. it stages OpenAlgo's state (SQLite through its online-backup API, since a copy of a live database file can tear);
2. it writes one snapshot;
3. it applies retention: 14 nightly, 8 weekly, and one a month for ever;
4. it reads back one seventh of the stored data and checks it against its hashes, so all of it is verified every week.

`backup/backup.py`'s docstring has the reasons.

**Is it working?** `homelab backup status` (also part of `homelab status`) judges by the age of the newest snapshot
(FAIL past 30 h) and the last run's result, not by the timer being enabled. A timer that fires every night into a
failing run is the silent failure a backup must not have.

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
