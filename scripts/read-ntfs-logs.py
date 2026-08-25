#!/usr/bin/env python3
"""Read Windows Setup logs from a raw disk image (GPT) via dissect.ntfs."""

import argparse
import sys


class OffsetFile:
    def __init__(self, fh, base):
        self.fh = fh
        self.base = base

    def seek(self, offset, whence=0):
        if whence == 0:
            return self.fh.seek(self.base + offset)
        return self.fh.seek(offset, whence)

    def tell(self):
        return self.fh.tell() - self.base

    def read(self, size=-1):
        return self.fh.read(size)

    def readinto(self, b):
        return self.fh.readinto(b)

    def close(self):
        self.fh.close()

    def __getattr__(self, name):
        return getattr(self.fh, name)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image", help="raw GPT disk image")
    ap.add_argument("--offset", type=lambda x: int(x, 0), default=290455552,
                    help="NTFS partition byte offset (default: win11 disk layout)")
    ap.add_argument("paths", nargs="*", help="paths inside the NTFS volume to print")
    args = ap.parse_args()

    from dissect.ntfs import NTFS

    fh = open(args.image, "rb")
    vol = OffsetFile(fh, args.offset)
    ntfs = NTFS(vol)

    mft = ntfs.mft

    def resolve(path):
        cur = mft.root
        for part in path.split("\\"):
            found = []
            for entry in cur.iterdir():
                rec = entry.dereference()
                if rec.filename == part:
                    found.append(rec)
            if not found:
                raise FileNotFoundError(path)
            # Prefer the record that actually has a data stream (long-name
            # entries can duplicate the 8.3 short name).
            cur = found[0]
            for rec in found[1:]:
                try:
                    if rec.size() > 0 and cur.size() == 0:
                        cur = rec
                except Exception:
                    pass
        return cur

    paths = args.paths or ["Windows\\Setup\\Scripts\\bootstrap.log"]
    for path in paths:
        print(f"\n===== {path} =====", file=sys.stderr)
        try:
            record = resolve(path)
            stream = record.open()
            data = stream.read()
            sys.stdout.buffer.write(data)
            if not data.endswith(b"\n"):
                sys.stdout.buffer.write(b"\n")
        except Exception as e:
            print(f"ERROR reading {path}: {e}", file=sys.stderr)


if __name__ == "__main__":
    main()
