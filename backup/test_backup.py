"""python3 backup/test_backup.py: the two guards the backup's correctness rests on, each shown to fail."""
import shutil
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import backup  # noqa: E402


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


if __name__ == "__main__":
    unittest.main()
