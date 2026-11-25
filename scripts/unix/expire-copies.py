"""Expire ShotTTL's generated copies in one dedicated receiving directory."""
import argparse
from datetime import datetime, timedelta, timezone
from pathlib import Path
import re

IMAGE = re.compile(r"shotttl-(\d{8}T\d{6})(\d{7})Z-[0-9A-F]{24}\.(png|jpg|jpeg|webp|bmp|gif)")
PART = re.compile(r"\.shotttl-[a-f0-9]{32}\.part")


def expire(directory, minutes, apply):
    if not directory.is_absolute() or directory.resolve() != directory or directory == directory.parent:
        raise ValueError("supply an absolute dedicated directory without symbolic links")
    cutoff = datetime.now(timezone.utc) - timedelta(minutes=minutes)
    for path in directory.iterdir():
        if path.is_symlink() or not path.is_file():
            continue
        match = IMAGE.fullmatch(path.name)
        if match:
            try:
                stamp = datetime.strptime(match[1] + match[2][:6], "%Y%m%dT%H%M%S%f").replace(tzinfo=timezone.utc)
            except ValueError:
                continue
        elif PART.fullmatch(path.name):
            stamp = datetime.fromtimestamp(path.stat().st_mtime, timezone.utc)
        else:
            continue
        if stamp <= cutoff:
            if apply:
                path.unlink(missing_ok=True)
            else:
                print("Would expire:", path.name)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--minutes", type=int, default=30)
    parser.add_argument("--apply", action="store_true", help="delete expired generated copies")
    args = parser.parse_args()
    if args.minutes < 1:
        parser.error("--minutes must be positive")
    expire(args.directory, args.minutes, args.apply)
