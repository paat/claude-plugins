#!/usr/bin/env python3
"""Digest a dependency tree and reject links that escape its check mount."""

import hashlib
import os
import stat
import sys


if len(sys.argv) != 3:
    raise SystemExit("usage: runtime-tree-digest.py ROOT CHECK_TARGET")

root = os.fsencode(sys.argv[1])
mount_root = b"/dev/shm/saas-check"
mount_path = os.path.normpath(os.path.join(mount_root, os.fsencode(sys.argv[2])))
digest = hashlib.sha256()


def add(value: bytes) -> None:
    digest.update(len(value).to_bytes(8, "big"))
    digest.update(value)


def walk(path: bytes, relative: bytes) -> None:
    entries = sorted(os.scandir(path), key=lambda entry: os.fsencode(entry.name))
    for entry in entries:
        name = os.fsencode(entry.name)
        child_relative = name if not relative else relative + b"/" + name
        info = entry.stat(follow_symlinks=False)
        add(child_relative)
        add(str(stat.S_IMODE(info.st_mode)).encode())
        add(str(info.st_mtime_ns).encode())
        if stat.S_ISDIR(info.st_mode):
            add(b"dir")
            walk(entry.path, child_relative)
        elif stat.S_ISREG(info.st_mode):
            add(b"file")
            add(str(info.st_size).encode())
            with open(entry.path, "rb", buffering=1024 * 1024) as handle:
                for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                    digest.update(chunk)
        elif stat.S_ISLNK(info.st_mode):
            add(b"link")
            target = os.readlink(entry.path)
            add(target)
            if os.path.isabs(target):
                normalized = os.path.normpath(target)
                system_roots = (b"/bin", b"/lib", b"/lib64", b"/usr")
                if not any(
                    normalized == base or normalized.startswith(base + b"/")
                    for base in system_roots
                ):
                    raise SystemExit(
                        "absolute runtime link escapes trusted system roots: "
                        + os.fsdecode(child_relative)
                    )
            else:
                mounted_link = os.path.join(mount_path, child_relative)
                resolved = os.path.normpath(
                    os.path.join(os.path.dirname(mounted_link), target)
                )
                if resolved != mount_root and not resolved.startswith(mount_root + b"/"):
                    raise SystemExit(
                        "relative runtime link escapes the check tree: "
                        + os.fsdecode(child_relative)
                    )
        else:
            raise SystemExit("unsupported runtime entry: " + os.fsdecode(child_relative))


root_info = os.stat(root, follow_symlinks=False)
add(str(stat.S_IMODE(root_info.st_mode)).encode())
add(str(root_info.st_mtime_ns).encode())
walk(root, b"")
print(digest.hexdigest())
