"""python3 backup/test_backup.py: the two guards the backup's correctness rests on, each shown to fail."""
import os
import shutil
import sqlite3
import sys
import tempfile
import unittest
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import backup  # noqa: E402

# No test reaches the network. On 2026-10-30 at 20:53 and 21:03 test_a_locked_forget_still_fails_the_night ran main()
# with the real alert(), and the operator got two real "the nightly backup FAILED: restic forget exited 11" messages.
REACHED = []


def _no_network(req, *a, **k):
    REACHED.append(getattr(req, "full_url", req))
    raise OSError("the tests never reach the network")


urllib.request.urlopen = _no_network


class Stage(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.src, self.dst = self.tmp / "state", self.tmp / "stage"
        (self.src / "db").mkdir(parents=True)
        (self.src / "tmp").mkdir()
        (self.src / "tmp" / "wheel.whl").write_text("fetchable")
        (self.src / ".env").write_text("SECRET=x")
        self.db = self.src / "db" / "openalgo.db"
        # A live database the way OpenAlgo leaves it: WAL mode, 100 committed rows still only in the -wal file
        # (no checkpoint), and a second writer mid-transaction.
        self.writer = sqlite3.connect(self.db)
        self.writer.execute("PRAGMA journal_mode=WAL")
        self.writer.execute("PRAGMA wal_autocheckpoint=0")
        self.writer.execute("CREATE TABLE t (i)")
        self.writer.executemany("INSERT INTO t VALUES (?)", [(i,) for i in range(100)])
        self.writer.commit()
        self.busy = sqlite3.connect(self.db)
        self.busy.execute("BEGIN")
        self.busy.execute("INSERT INTO t VALUES (-1)")
        self.addCleanup(self.writer.close)
        self.addCleanup(self.busy.close)

    def rows(self, path):
        with sqlite3.connect(path) as c:
            return c.execute("SELECT count(*) FROM t").fetchone()[0]

    def test_a_live_sqlite_database_is_staged_whole(self):
        backup.stage(self.src, self.dst)
        self.assertEqual(sorted(p.name for p in (self.dst / "db").iterdir()), ["openalgo.db"])
        self.assertEqual(self.rows(self.dst / "db" / "openalgo.db"), 100)   # every committed row, none uncommitted
        self.assertEqual(sorted(p.name for p in (self.dst / "db").iterdir()), ["openalgo.db"])  # opened, still one
        self.assertFalse((self.dst / "tmp").exists())
        self.assertEqual((self.dst / ".env").read_text(), "SECRET=x")
        self.assertEqual(self.dst.stat().st_mode & 0o777, 0o700)

    def test_PLANTED_a_plain_file_copy_of_the_same_database_loses_rows(self):
        # The fixture can tell the two apart: copying the file, as a naive backup would, does not give 100 rows.
        naive = self.tmp / "naive.db"
        shutil.copy2(self.db, naive)
        try:
            n = self.rows(naive)
        except sqlite3.Error:
            n = None
        self.assertNotEqual(n, 100)

    def test_a_file_that_keeps_changing_is_refused(self):
        f = self.tmp / "historify.duckdb"
        f.write_text("x")
        sigs = iter(range(100))
        real, backup._sig = backup._sig, lambda p: next(sigs)
        try:
            with self.assertRaises(backup.Failed):
                backup.stable_copy(f, self.tmp / "copy.duckdb")
        finally:
            backup._sig = real


class Mount(unittest.TestCase):
    def test_refuses_a_directory_that_is_not_a_mount(self):
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(backup.Failed):
                backup.require_mount(Path(d))
        backup.require_mount(Path("/"))


class Nightly(unittest.TestCase):
    """2026-10-28 23:10: a killed restic left its lock, and two nights failed after their snapshot."""

    def run_main(self, codes):
        calls, orig = [], (backup.subprocess.run, backup.require_mount, backup.stage, backup.REPO)
        tmp = Path(tempfile.mkdtemp())
        (tmp / "config").write_text("")

        def fake(cmd, **k):
            sub = cmd[len(backup.RESTIC)]
            calls.append(sub)
            return backup.subprocess.CompletedProcess(cmd, codes.get(sub, 0))
        backup.subprocess.run, backup.require_mount, backup.stage, backup.REPO = fake, lambda p: None, lambda a, b: 0, tmp
        try:
            return backup.main(), calls
        finally:
            backup.subprocess.run, backup.require_mount, backup.stage, backup.REPO = orig
            shutil.rmtree(tmp)

    def test_PLANTED_stale_locks_are_cleared_before_retention_and_a_live_one_is_waited_for(self):
        rc, calls = self.run_main({})
        self.assertEqual((rc, calls), (0, ["backup", "unlock", "forget", "check"]))
        self.assertIn("--retry-lock", backup.RESTIC, "a manual restic at 17:30 must be waited for, not fail the night")

    def test_a_locked_forget_still_fails_the_night(self):
        rc, calls = self.run_main({"forget": 11})
        self.assertEqual((rc, calls), (1, ["backup", "unlock", "forget"]))

    def test_PLANTED_a_failed_night_inside_the_tests_reaches_no_channel(self):
        tmp = Path(tempfile.mkdtemp())
        (tmp / "o.env").write_text("OPENALGO_API_KEY=k\n")
        (tmp / "a.env").write_text("ALERT_TELEGRAM_USER=op\n")
        s0, a0, n = backup.SECRETS, backup.ALERTS, len(REACHED)
        backup.SECRETS, backup.ALERTS = tmp / "o.env", tmp / "a.env"
        try:
            self.assertEqual(self.run_main({"forget": 11})[0], 1)
        finally:
            backup.SECRETS, backup.ALERTS = s0, a0
            shutil.rmtree(tmp)
        self.assertEqual(len(REACHED) - n, 2, "both channels were attempted and both were stopped before the network")

    def test_PLANTED_a_failed_night_is_alerted_on_both_channels_and_a_good_one_is_not(self):
        sent, orig = [], backup.alert
        backup.alert = lambda text, post=None: sent.append(text) or {}
        try:
            self.assertEqual(self.run_main({"forget": 11})[0], 1)
            self.assertEqual(self.run_main({})[0], 0)
        finally:
            backup.alert = orig
        self.assertEqual(len(sent), 1, "one alert for the failed night, none for the good one")
        self.assertIn("restic forget exited 11", sent[0])
        tmp = Path(tempfile.mkdtemp())
        (tmp / "o.env").write_text("OPENALGO_API_KEY=k\n")
        (tmp / "a.env").write_text("ALERT_TELEGRAM_USER=op\n")
        posted = []
        s0, a0 = backup.SECRETS, backup.ALERTS
        backup.SECRETS, backup.ALERTS = tmp / "o.env", tmp / "a.env"
        try:
            got = backup.alert("x", post=lambda path, body: posted.append((path, body)) or "sent")
            self.assertEqual(got, {"telegram": "sent", "whatsapp": "sent"})
            self.assertEqual([p for p, _ in posted], ["/api/v1/telegram/notify", "/api/v1/whatsapp/notify"])
            self.assertEqual(posted[1][1].get("self"), True, "no WhatsApp username: the chat /update-here named")
            backup.ALERTS = tmp / "missing.env"
            self.assertEqual(backup.alert("x", post=lambda p, b: "sent")["telegram"], "skipped: no ALERT_TELEGRAM_USER")
            os.environ["OPENALGO_HOST"] = "http://127.0.0.1:9"              # nothing listens: a reason, not a raise
            self.assertTrue(backup.alert("x")["whatsapp"].startswith("failed"))
        finally:
            backup.SECRETS, backup.ALERTS = s0, a0
            os.environ.pop("OPENALGO_HOST", None)
            shutil.rmtree(tmp)


if __name__ == "__main__":
    unittest.main()
