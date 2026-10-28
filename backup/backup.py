#!/usr/bin/env python3
"""The nightly backup: this machine's data onto the archive disk, as restic snapshots.

    python3 backup/backup.py     # what homelab-backup.timer runs at 17:30: stage, back up, prune, verify

WHAT is backed up is include.txt beside this file, which restic reads as it is. The rule: everything under /srv/data
plus the secrets needed to rebuild the machine. Not /srv/archive/history, which already lives on this disk and can be
fetched again, and not the code checkouts, which live on GitHub.

**restic, one snapshot a night.** A snapshot is the whole set as it was that evening, stored deduplicated, so a night
costs only what changed. Kept: the last 14 nightly snapshots, 8 weekly and one per month for ever, grouped by tag so an
edit to include.txt does not start a second retention series. A file deleted from the SSD therefore stays restorable
as long as any month's last snapshot held it.

**Verified, not assumed.** `restic check` re-reads one seventh of the stored data every night (the day of the week
picks which seventh), so all of it is read back and checked against its hash once a week. A backup that is written and
never read back is a hope.

**OpenAlgo's state is staged first** into /srv/archive/stage/openalgo, and the snapshot holds that copy: restore
OpenAlgo from there. Its SQLite databases are written all day, and a file copy of a live one can tear, so each goes
through SQLite's online-backup API, which cannot. A DuckDB file is copied until two reads agree. The rule is the deploy
pipeline's (algo-trading `deploy_queue.backup`), learned when a tar of the live db/ failed a deploy on 2026-10-26.
Everything else is read by restic where it lies: at 17:30 the market is shut and the collectors are done.

**Not encrypted, on purpose.** The repository sits in the same machine as the plaintext it copies, so a password
would protect nothing here, and it would have to live on the SSD this exists to survive: lose the SSD and the backup
is locked. An off-site copy gets its own encrypted repository (`restic copy`).

**It refuses to write anywhere but the archive disk.** /srv/archive is mounted `nofail`, so with the disk missing it
is an empty directory on /srv, and a backup there would land on the SSD it is meant to protect. The unit asserts the
mount and so does this script, for a run by hand.
"""
from __future__ import annotations

import os
import shutil
import sqlite3
import subprocess
import sys
from datetime import date
from pathlib import Path

HERE = Path(__file__).resolve().parent
ARCHIVE = Path("/srv/archive")
REPO = ARCHIVE / "restic"
OPENALGO = Path("/srv/data/openalgo")
STAGE = ARCHIVE / "stage" / "openalgo"
SKIP = {"tmp"}                          # OpenAlgo's tmp/: release wheels and caches, all fetchable again
SQLITE_HEADER = b"SQLite format 3\x00"
RESTIC = ["restic", "--repo", str(REPO), "--insecure-no-password"]
KEEP = ["--keep-daily", "14", "--keep-weekly", "8", "--keep-monthly", "unlimited"]


class Failed(Exception):
    pass


def require_mount(path: Path) -> None:
    if not os.path.ismount(path):
        raise Failed(f"{path} is not a mounted filesystem: the archive disk is missing, and a backup there would land "
                     f"on the SSD (findmnt {path})")


def _sig(p: Path) -> tuple[int, int]:
    s = p.stat()
    return s.st_size, s.st_mtime_ns


def stable_copy(src: Path, dst: Path, tries: int = 3) -> None:
    for _ in range(tries):
        before = _sig(src)
        shutil.copy2(src, dst)
        if _sig(src) == before:
            return
    raise Failed(f"{src} kept changing across {tries} copies")


def stage(src: Path, dst: Path) -> int:
    """A consistent copy of OpenAlgo's state at `dst`, mode 700 (it holds .env and keys). Returns the file count."""
    if dst.exists():
        shutil.rmtree(dst)
    dst.mkdir(parents=True, mode=0o700)
    n = 0
    for p in sorted(src.rglob("*")):
        rel = p.relative_to(src)
        if rel.parts[0] in SKIP or p.is_symlink() or not p.is_file():
            continue
        if p.name.endswith(("-wal", "-shm", "-journal")):     # SQLite's: the online backup's copy is whole without them
            continue
        out = dst / rel
        out.parent.mkdir(parents=True, exist_ok=True)
        try:
            with open(p, "rb") as f:
                sqlite = f.read(16) == SQLITE_HEADER
            if sqlite:
                db, copy = sqlite3.connect(f"file:{p}?mode=ro", uri=True), sqlite3.connect(out)
                try:
                    db.backup(copy)
                    copy.execute("PRAGMA journal_mode=DELETE")    # one self-contained file, even once opened
                except sqlite3.Error as e:
                    # e.g. a hot journal left by a crashed writer: rolling it back would mean WRITING OpenAlgo's
                    # database from a backup. Refused.
                    raise Failed(f"{p} could not be read consistently ({e})") from e
                finally:
                    db.close()
                    copy.close()
            elif p.suffix in (".duckdb", ".wal"):
                stable_copy(p, out)
            else:
                shutil.copy2(p, out)    # a log caught mid-append loses its last line, which the next snapshot has
        except FileNotFoundError:       # a temporary file that went away during the walk was not data
            continue
        n += 1
    return n


def restic(*args: str) -> None:
    r = subprocess.run([*RESTIC, *args])
    if r.returncode:    # 3 = a snapshot was written but some files could not be read: still a failure
        raise Failed(f"restic {args[0]} exited {r.returncode}")


def main() -> int:
    try:
        require_mount(ARCHIVE)
        if not (REPO / "config").exists():
            raise Failed(f"no repository at {REPO} (homelab backup install)")
        print(f"staged OpenAlgo's state: {stage(OPENALGO, STAGE)} files into {STAGE}", flush=True)
        restic("backup", "--files-from", str(HERE / "include.txt"), "--exclude-caches", "--tag", "nightly")
        restic("forget", "--tag", "nightly", "--group-by", "host,tags", *KEEP, "--prune")
        restic("check", f"--read-data-subset={date.today().isoweekday()}/7")
    except Failed as e:
        print(f"BACKUP FAILED: {e}", file=sys.stderr)
        return 1
    print("backup complete: snapshot written, retention applied, a seventh of the data read back and verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
