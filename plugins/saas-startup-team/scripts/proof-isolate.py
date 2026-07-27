#!/usr/bin/env python3
"""Apply Landlock write isolation then exec a proof command.

Only the listed --allow-write roots may be mutated. Everything else stays
readable/executable so the archived proof tree can run system tools, but the
primary checkout and control-plane paths cannot be altered. Fail closed when
Landlock is unavailable.
"""
from __future__ import annotations

import argparse
import ctypes
import ctypes.util
import os
import sys

SYS_landlock_create_ruleset = 444
SYS_landlock_add_rule = 445
SYS_landlock_restrict_self = 446
LANDLOCK_RULE_PATH_BENEATH = 1
PR_SET_NO_NEW_PRIVS = 38

ACCESS_FS_EXECUTE = 1 << 0
ACCESS_FS_WRITE_FILE = 1 << 1
ACCESS_FS_READ_FILE = 1 << 2
ACCESS_FS_READ_DIR = 1 << 3
ACCESS_FS_REMOVE_DIR = 1 << 4
ACCESS_FS_REMOVE_FILE = 1 << 5
ACCESS_FS_MAKE_CHAR = 1 << 6
ACCESS_FS_MAKE_DIR = 1 << 7
ACCESS_FS_MAKE_REG = 1 << 8
ACCESS_FS_MAKE_SOCK = 1 << 9
ACCESS_FS_MAKE_FIFO = 1 << 10
ACCESS_FS_MAKE_BLOCK = 1 << 11
ACCESS_FS_MAKE_SYM = 1 << 12
ACCESS_FS_REFER = 1 << 13
ACCESS_FS_TRUNCATE = 1 << 14

READ_EXEC = (
    ACCESS_FS_EXECUTE
    | ACCESS_FS_READ_FILE
    | ACCESS_FS_READ_DIR
    | ACCESS_FS_REFER
)
WRITE = (
    ACCESS_FS_WRITE_FILE
    | ACCESS_FS_REMOVE_DIR
    | ACCESS_FS_REMOVE_FILE
    | ACCESS_FS_MAKE_CHAR
    | ACCESS_FS_MAKE_DIR
    | ACCESS_FS_MAKE_REG
    | ACCESS_FS_MAKE_SOCK
    | ACCESS_FS_MAKE_FIFO
    | ACCESS_FS_MAKE_BLOCK
    | ACCESS_FS_MAKE_SYM
    | ACCESS_FS_TRUNCATE
)
ALL = READ_EXEC | WRITE


class RulesetAttr(ctypes.Structure):
    _fields_ = [("handled_access_fs", ctypes.c_uint64)]


class PathBeneath(ctypes.Structure):
    _fields_ = [
        ("allowed_access", ctypes.c_uint64),
        ("parent_fd", ctypes.c_int32),
    ]


def die(msg: str, code: int = 1) -> None:
    print(f"proof-isolate: {msg}", file=sys.stderr)
    raise SystemExit(code)


def main(argv: list[str]) -> None:
    parser = argparse.ArgumentParser(prog="proof-isolate")
    parser.add_argument(
        "--allow-write",
        action="append",
        default=[],
        metavar="DIR",
        help="directory root where writes remain allowed (repeatable)",
    )
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    command = list(args.command)
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        die("command is required", 2)
    if not args.allow_write:
        die("at least one --allow-write root is required", 2)

    write_roots: list[str] = []
    for raw in args.allow_write:
        if not raw or not os.path.isabs(raw):
            die(f"allow-write root must be an absolute path: {raw!r}", 2)
        if not os.path.isdir(raw) or os.path.islink(raw):
            die(f"allow-write root missing or unsafe: {raw}", 1)
        resolved = os.path.realpath(raw)
        if resolved != raw:
            die(f"allow-write root must be canonical: {raw}", 1)
        write_roots.append(resolved)

    libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
    attr = RulesetAttr(ALL)
    ruleset = libc.syscall(
        SYS_landlock_create_ruleset, ctypes.byref(attr), ctypes.sizeof(attr), 0
    )
    if ruleset < 0:
        die("Landlock is required for proof filesystem isolation", 1)

    def add_rule(path: str, access: int) -> None:
        fd = os.open(path, os.O_PATH | os.O_CLOEXEC)
        try:
            rule = PathBeneath(access, fd)
            rc = libc.syscall(
                SYS_landlock_add_rule,
                ruleset,
                LANDLOCK_RULE_PATH_BENEATH,
                ctypes.byref(rule),
                0,
            )
            if rc != 0:
                die(f"cannot add Landlock rule for {path}", 1)
        finally:
            os.close(fd)

    # Deny-by-default for handled accesses: read/exec everywhere, write only on
    # allow-list roots. /dev keeps write so /dev/null and similar nodes work.
    add_rule("/", READ_EXEC)
    if os.path.isdir("/dev"):
        add_rule(
            "/dev",
            READ_EXEC | ACCESS_FS_WRITE_FILE | ACCESS_FS_TRUNCATE,
        )
    for root in write_roots:
        add_rule(root, ALL)

    if libc.prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0:
        die("cannot set no_new_privs for Landlock", 1)
    if libc.syscall(SYS_landlock_restrict_self, ruleset, 0) != 0:
        die("cannot apply Landlock restriction", 1)
    os.close(ruleset)

    try:
        os.execvpe(command[0], command, os.environ)
    except OSError as exc:
        die(f"cannot exec proof command: {exc}", 1)


if __name__ == "__main__":
    main(sys.argv[1:])
