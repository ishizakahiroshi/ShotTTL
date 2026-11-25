"""Windows integration check. Uses only a temporary source and receiver."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    with tempfile.TemporaryDirectory() as tmp:
        source = Path(tmp, "source")
        target = Path(tmp, "receiver")
        source.mkdir()
        target.mkdir()
        fresh = source / "fresh.png"
        fresh.write_bytes(b"fixture")
        now = time.time()
        os.utime(fresh, (now - 5, now - 5))
        old = source / "old.png"
        old.write_bytes(b"expired")
        os.utime(old, (now - 3600, now - 3600))
        cmd = ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
               str(ROOT / "scripts/windows/shotttl.ps1"), "-TargetDir", str(source), "-CopyTo", str(target)]
        subprocess.run(cmd + ["-WatchCopy", "-DryRun"], check=True, timeout=15)
        assert not list(target.iterdir())
        target.rmdir()
        watcher = subprocess.Popen(cmd + ["-WatchCopy"])
        try:
            time.sleep(3)
            assert watcher.poll() is None
            target.mkdir()
            for _ in range(30):
                copies = list(target.glob("shotttl-*.png"))
                if copies:
                    break
                time.sleep(0.5)
            assert len(copies) == 1 and copies[0].read_bytes() == b"fixture"
            subprocess.run(cmd, check=True, timeout=15)
            assert len(list(target.iterdir())) == 1
        finally:
            watcher.terminate()
            watcher.wait(timeout=10)
        manual = target / "manual.png"
        manual.write_bytes(b"keep")
        expired = copies[0].with_name("shotttl-20010101T0000000000000Z-" + "A" * 24 + ".png")
        expired.write_bytes(b"expired")
        expire = [sys.executable, str(ROOT / "scripts/unix/expire-copies.py"), str(target.resolve())]
        subprocess.run(expire, check=True)
        assert expired.exists()
        subprocess.run(expire + ["--apply"], check=True)
        assert not expired.exists()
        assert manual.exists() and copies[0].exists() and fresh.exists() and old.exists()


if __name__ == "__main__":
    main()
