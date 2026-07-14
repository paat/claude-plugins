#!/usr/bin/env python3
"""Run a disposable proof command in a fail-closed Landlock domain."""

from __future__ import annotations

import argparse
import ctypes
import errno
import os
import platform
import re
import resource
import stat
import sys
from dataclasses import dataclass
from typing import Iterable, Sequence


EXIT_POLICY = 2
MIN_ABI = 5
MAX_ABI = 10

LANDLOCK_CREATE_RULESET_VERSION = 1
LANDLOCK_RULE_PATH_BENEATH = 1
PR_SET_NO_NEW_PRIVS = 38

FS_EXECUTE = 1 << 0
FS_WRITE_FILE = 1 << 1
FS_READ_FILE = 1 << 2
FS_READ_DIR = 1 << 3
FS_REMOVE_DIR = 1 << 4
FS_REMOVE_FILE = 1 << 5
FS_MAKE_CHAR = 1 << 6
FS_MAKE_DIR = 1 << 7
FS_MAKE_REG = 1 << 8
FS_MAKE_SOCK = 1 << 9
FS_MAKE_FIFO = 1 << 10
FS_MAKE_BLOCK = 1 << 11
FS_MAKE_SYM = 1 << 12
FS_REFER = 1 << 13
FS_TRUNCATE = 1 << 14
FS_IOCTL_DEV = 1 << 15
FS_RESOLVE_UNIX = 1 << 16

BASE_FS_ACCESS = (
    FS_EXECUTE
    | FS_WRITE_FILE
    | FS_READ_FILE
    | FS_READ_DIR
    | FS_REMOVE_DIR
    | FS_REMOVE_FILE
    | FS_MAKE_CHAR
    | FS_MAKE_DIR
    | FS_MAKE_REG
    | FS_MAKE_SOCK
    | FS_MAKE_FIFO
    | FS_MAKE_BLOCK
    | FS_MAKE_SYM
)
READ_ACCESS = FS_READ_FILE | FS_READ_DIR
READ_EXEC_ACCESS = READ_ACCESS | FS_EXECUTE

# Runtime code is executable; configuration and trust stores are readable only.
SYSTEM_EXEC_TREES = (
    "/usr",
    "/bin",
    "/sbin",
    "/lib",
    "/lib64",
    "/lib32",
    "/libx32",
)
SYSTEM_READ_TREES = (
    "/etc/ssl",
    "/etc/pki",
    "/etc/ca-certificates",
    "/etc/ld.so.conf.d",
    "/var/lib/ca-certificates",
)
SYSTEM_READ_FILES = (
    "/etc/hosts",
    "/etc/resolv.conf",
    "/etc/nsswitch.conf",
    "/etc/host.conf",
    "/etc/gai.conf",
    "/etc/services",
    "/etc/protocols",
    "/etc/passwd",
    "/etc/group",
    "/etc/localtime",
    "/etc/ld.so.cache",
    "/etc/ld.so.conf",
    "/etc/machine-id",
    "/var/lib/dbus/machine-id",
)
SYSTEM_DEVICES = (
    ("/dev/null", FS_READ_FILE | FS_WRITE_FILE),
    ("/dev/urandom", FS_READ_FILE),
)

ENV_NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
FORBIDDEN_ENV_NAMES = {
    "BASH_ENV",
    "CDPATH",
    "ENV",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_CEILING_DIRECTORIES",
    "GIT_CONFIG",
    "GIT_CONFIG_COUNT",
    "GIT_CONFIG_GLOBAL",
    "GIT_CONFIG_NOSYSTEM",
    "GIT_CONFIG_SYSTEM",
    "GIT_DIR",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_WORK_TREE",
    "HOME",
    "IFS",
    "LD_AUDIT",
    "LD_LIBRARY_PATH",
    "LD_PRELOAD",
    "NODE_OPTIONS",
    "OLDPWD",
    "PATH",
    "PERL5LIB",
    "PWD",
    "PYTHONHOME",
    "PYTHONPATH",
    "RUBYLIB",
    "SHELLOPTS",
    "TEMP",
    "TMP",
    "TMPDIR",
    "XDG_CACHE_HOME",
    "XDG_CONFIG_HOME",
    "XDG_DATA_HOME",
}
FORBIDDEN_ENV_PREFIXES = ("DYLD_", "GIT_CONFIG_KEY_", "GIT_CONFIG_VALUE_")


class PolicyError(RuntimeError):
    """A policy could not be validated or enforced."""


class RulesetAttrV4(ctypes.Structure):
    _fields_ = [
        ("handled_access_fs", ctypes.c_uint64),
        ("handled_access_net", ctypes.c_uint64),
    ]


class RulesetAttrV6(ctypes.Structure):
    _fields_ = [
        ("handled_access_fs", ctypes.c_uint64),
        ("handled_access_net", ctypes.c_uint64),
        ("scoped", ctypes.c_uint64),
    ]


class PathBeneathAttr(ctypes.Structure):
    _pack_ = 1
    _fields_ = [
        ("allowed_access", ctypes.c_uint64),
        ("parent_fd", ctypes.c_int32),
    ]


@dataclass
class Grant:
    path: str
    fd: int
    access: int


@dataclass(frozen=True)
class CheckedPath:
    path: str
    device: int
    inode: int


LIBC = ctypes.CDLL(None, use_errno=True)
LIBC.syscall.restype = ctypes.c_long
LIBC.prctl.restype = ctypes.c_int


def _syscall_numbers() -> tuple[int, int, int]:
    machine = platform.machine().lower()
    # Landlock uses the asm-generic allocation on the supported mainstream
    # Linux architectures. Unknown tables must be reviewed, not guessed.
    if machine in {
        "aarch64",
        "arm64",
        "armv7l",
        "i386",
        "i486",
        "i586",
        "i686",
        "ppc64",
        "ppc64le",
        "riscv64",
        "s390x",
        "x86_64",
    }:
        return 444, 445, 446
    raise PolicyError(f"unsupported Linux syscall table: {machine or 'unknown'}")


def _call(number: int, *args: object) -> int:
    ctypes.set_errno(0)
    result = int(LIBC.syscall(number, *args))
    if result == -1:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))
    return result


def query_abi() -> int:
    if sys.platform != "linux":
        raise PolicyError("Linux Landlock is required")
    create_ruleset, _, _ = _syscall_numbers()
    try:
        abi = _call(create_ruleset, 0, 0, LANDLOCK_CREATE_RULESET_VERSION)
    except OSError as exc:
        if exc.errno in {errno.ENOSYS, errno.EOPNOTSUPP, errno.EINVAL}:
            raise PolicyError("Linux Landlock is unavailable or disabled") from exc
        raise PolicyError(f"cannot query Linux Landlock: {exc.strerror}") from exc
    if abi < MIN_ABI:
        raise PolicyError(
            f"Linux Landlock ABI {MIN_ABI}+ is required; kernel provides ABI {abi}"
        )
    if abi > MAX_ABI:
        raise PolicyError(
            f"Linux Landlock ABI {abi} is newer than reviewed ABI {MAX_ABI}; refusing partial policy"
        )
    return abi


def handled_fs_access(abi: int) -> int:
    if abi < 1 or abi > MAX_ABI:
        raise PolicyError(f"unsupported Linux Landlock ABI: {abi}")
    access = BASE_FS_ACCESS
    if abi >= 2:
        access |= FS_REFER
    if abi >= 3:
        access |= FS_TRUNCATE
    if abi >= 5:
        access |= FS_IOCTL_DEV
    if abi >= 9:
        access |= FS_RESOLVE_UNIX
    return access


def _is_beneath(path: str, root: str) -> bool:
    try:
        return os.path.commonpath((path, root)) == root
    except ValueError:
        return False


def _validate_root(raw: str, label: str) -> CheckedPath:
    if not os.path.isabs(raw):
        raise PolicyError(f"{label} must be absolute: {raw}")
    if os.path.normpath(raw) != raw or os.path.realpath(raw) != raw:
        raise PolicyError(f"{label} must be canonical and contain no symlink: {raw}")
    if raw == "/":
        raise PolicyError(f"{label} cannot be the filesystem root")
    try:
        info = os.lstat(raw)
    except OSError as exc:
        raise PolicyError(f"cannot inspect {label} {raw}: {exc.strerror}") from exc
    if not stat.S_ISDIR(info.st_mode):
        raise PolicyError(f"{label} must be a directory: {raw}")
    if info.st_uid != os.geteuid():
        raise PolicyError(f"{label} must be owned by the current user: {raw}")
    if stat.S_IMODE(info.st_mode) & 0o077:
        raise PolicyError(f"{label} must not grant group or other access: {raw}")
    return CheckedPath(raw, info.st_dev, info.st_ino)


def _validate_command(raw: str, work_root: str) -> CheckedPath:
    if not os.path.isabs(raw):
        raise PolicyError(f"command must be absolute: {raw}")
    if os.path.normpath(raw) != raw or os.path.realpath(raw) != raw:
        raise PolicyError(f"command must be canonical and contain no symlink: {raw}")
    if raw == work_root or not _is_beneath(raw, work_root):
        raise PolicyError("command must be beneath --work-root")
    try:
        info = os.lstat(raw)
    except OSError as exc:
        raise PolicyError(f"cannot inspect command {raw}: {exc.strerror}") from exc
    if not stat.S_ISREG(info.st_mode):
        raise PolicyError(f"command must be a regular file: {raw}")
    if not os.access(raw, os.X_OK):
        raise PolicyError(f"command is not executable: {raw}")
    return CheckedPath(raw, info.st_dev, info.st_ino)


def _open_grant(
    path: str,
    access: int,
    require_directory: bool,
    expected: CheckedPath | None = None,
) -> Grant:
    flags = os.O_CLOEXEC | os.O_NOFOLLOW
    flags |= getattr(os, "O_PATH", os.O_RDONLY)
    if require_directory:
        flags |= os.O_DIRECTORY
    try:
        fd = os.open(path, flags)
    except OSError as exc:
        raise PolicyError(f"cannot pin Landlock path {path}: {exc.strerror}") from exc
    info = os.fstat(fd)
    if expected is not None and (info.st_dev, info.st_ino) != (
        expected.device,
        expected.inode,
    ):
        os.close(fd)
        raise PolicyError(f"Landlock path changed while policy was prepared: {path}")
    return Grant(path=path, fd=fd, access=access)


def _open_command(command: CheckedPath) -> int:
    try:
        fd = os.open(command.path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError as exc:
        raise PolicyError(f"cannot pin proof command {command.path}: {exc.strerror}") from exc
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or (info.st_dev, info.st_ino) != (
        command.device,
        command.inode,
    ):
        os.close(fd)
        raise PolicyError("proof command changed while policy was prepared")
    os.set_inheritable(fd, True)
    return fd


def _system_grants() -> list[Grant]:
    grants: list[Grant] = []
    seen: set[tuple[int, int, int]] = set()

    def add(raw: str, access: int, require_directory: bool) -> None:
        if not os.path.exists(raw):
            return
        path = os.path.realpath(raw)
        if not os.path.isabs(path):
            raise PolicyError(f"system path did not resolve absolutely: {raw}")
        grant = _open_grant(path, access, require_directory)
        info = os.fstat(grant.fd)
        key = (info.st_dev, info.st_ino, access)
        if key in seen:
            os.close(grant.fd)
            return
        seen.add(key)
        grants.append(grant)

    for path in SYSTEM_EXEC_TREES:
        add(path, READ_EXEC_ACCESS, True)
    for path in SYSTEM_READ_TREES:
        add(path, READ_ACCESS, True)
    for path in SYSTEM_READ_FILES:
        add(path, FS_READ_FILE, False)
    for path, access in SYSTEM_DEVICES:
        add(path, access, False)
    if not grants:
        raise PolicyError("no trusted system runtime paths were found")
    return grants


def _close_extra_fds() -> None:
    try:
        names = os.listdir("/proc/self/fd")
    except OSError:
        soft_limit = resource.getrlimit(resource.RLIMIT_NOFILE)[0]
        upper = 1_048_576 if soft_limit == resource.RLIM_INFINITY else int(soft_limit)
        os.closerange(3, upper)
        return
    for name in names:
        try:
            fd = int(name)
        except ValueError:
            continue
        if fd > 2:
            try:
                os.close(fd)
            except OSError as exc:
                if exc.errno != errno.EBADF:
                    raise PolicyError(f"cannot close inherited descriptor {fd}: {exc.strerror}") from exc


def _validate_standard_fds(read_roots: Sequence[str], write_roots: Sequence[str]) -> None:
    for fd in (0, 1, 2):
        try:
            info = os.fstat(fd)
        except OSError as exc:
            if exc.errno == errno.EBADF:
                continue
            raise PolicyError(f"cannot inspect standard fd {fd}: {exc.strerror}") from exc
        if not stat.S_ISREG(info.st_mode):
            continue
        try:
            target = os.readlink(f"/proc/self/fd/{fd}")
        except OSError as exc:
            raise PolicyError(f"cannot validate regular standard fd {fd}") from exc
        if not os.path.isabs(target) or target.endswith(" (deleted)"):
            raise PolicyError(f"regular standard fd {fd} has an unsafe target")
        target = os.path.realpath(target)
        roots = read_roots if fd == 0 else write_roots
        if not any(_is_beneath(target, root) for root in roots):
            raise PolicyError(f"regular standard fd {fd} escapes disposable roots")


def _build_environment(pass_names: Iterable[str], scratch_root: str, work_root: str) -> dict[str, str]:
    environment = {
        "HOME": scratch_root,
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
        "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "PWD": work_root,
        "TEMP": scratch_root,
        "TMP": scratch_root,
        "TMPDIR": scratch_root,
        "XDG_CACHE_HOME": os.path.join(scratch_root, ".cache"),
        "XDG_CONFIG_HOME": os.path.join(scratch_root, ".config"),
        "XDG_DATA_HOME": os.path.join(scratch_root, ".local", "share"),
    }
    for name in pass_names:
        if not ENV_NAME_RE.fullmatch(name):
            raise PolicyError(f"invalid --pass-env name: {name}")
        if name in FORBIDDEN_ENV_NAMES or name.startswith(FORBIDDEN_ENV_PREFIXES):
            raise PolicyError(f"unsafe environment variable cannot be passed: {name}")
        if name not in os.environ:
            raise PolicyError(f"requested environment variable is unset: {name}")
        environment[name] = os.environ[name]
    return environment


def _create_ruleset(abi: int, handled_access: int) -> int:
    create_ruleset, _, _ = _syscall_numbers()
    if abi >= 6:
        attr: ctypes.Structure = RulesetAttrV6(handled_access, 0, 0)
    else:
        attr = RulesetAttrV4(handled_access, 0)
    try:
        return _call(create_ruleset, ctypes.byref(attr), ctypes.sizeof(attr), 0)
    except OSError as exc:
        raise PolicyError(f"cannot create Landlock ruleset: {exc.strerror}") from exc


def _add_grant(ruleset_fd: int, grant: Grant, handled_access: int) -> None:
    _, add_rule, _ = _syscall_numbers()
    attr = PathBeneathAttr(grant.access & handled_access, grant.fd)
    try:
        _call(add_rule, ruleset_fd, LANDLOCK_RULE_PATH_BENEATH, ctypes.byref(attr), 0)
    except OSError as exc:
        raise PolicyError(f"cannot add Landlock rule for {grant.path}: {exc.strerror}") from exc


def _enforce(ruleset_fd: int) -> None:
    ctypes.set_errno(0)
    if LIBC.prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0:
        error = ctypes.get_errno()
        raise PolicyError(f"cannot set no_new_privs: {os.strerror(error)}")
    _, _, restrict_self = _syscall_numbers()
    try:
        _call(restrict_self, ruleset_fd, 0)
    except OSError as exc:
        raise PolicyError(f"cannot enforce Landlock ruleset: {exc.strerror}") from exc


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run a proof command with filesystem access limited by Linux Landlock",
        usage=(
            "%(prog)s --work-root ABS --scratch-root ABS [--scratch-root ABS ...] "
            "[--pass-env NAME ...] -- COMMAND [ARG ...]"
        ),
    )
    parser.add_argument("--work-root", required=True)
    parser.add_argument("--scratch-root", action="append", required=True)
    parser.add_argument("--pass-env", action="append", default=[])
    parser.add_argument("command", nargs=argparse.REMAINDER)
    if "--" not in argv and not any(item in {"-h", "--help"} for item in argv):
        parser.error("the -- command separator is required")
    args = parser.parse_args(argv)
    if args.command and args.command[0] == "--":
        args.command = args.command[1:]
    if not args.command:
        parser.error("a command after -- is required")
    return args


def run(argv: Sequence[str]) -> None:
    args = parse_args(argv)
    work_checked = _validate_root(args.work_root, "--work-root")
    scratch_checked = [
        _validate_root(path, "--scratch-root") for path in args.scratch_root
    ]
    work_root = work_checked.path
    scratch_roots = [item.path for item in scratch_checked]
    if len(set(scratch_roots)) != len(scratch_roots):
        raise PolicyError("duplicate --scratch-root")
    command = _validate_command(args.command[0], work_root)
    environment = _build_environment(args.pass_env, scratch_roots[0], work_root)
    read_roots = [work_root, *scratch_roots]
    write_roots = [work_root, *scratch_roots]
    _validate_standard_fds(read_roots, write_roots)
    _close_extra_fds()

    abi = query_abi()
    handled_access = handled_fs_access(abi)
    grants: list[Grant] = []
    ruleset_fd = -1
    command_fd = -1
    ready = False
    try:
        grants.extend(_system_grants())
        work_grant = _open_grant(
            work_root, handled_access, True, expected=work_checked
        )
        grants.append(work_grant)
        grants.extend(
            _open_grant(item.path, handled_access, True, expected=item)
            for item in scratch_checked
        )
        command_fd = _open_command(command)
        ruleset_fd = _create_ruleset(abi, handled_access)
        for grant in grants:
            _add_grant(ruleset_fd, grant, handled_access)
        _enforce(ruleset_fd)
        os.fchdir(work_grant.fd)
        ready = True
    finally:
        for grant in grants:
            try:
                os.close(grant.fd)
            except OSError as exc:
                raise PolicyError("cannot close Landlock grant descriptor") from exc
        if ruleset_fd >= 0:
            try:
                os.close(ruleset_fd)
            except OSError as exc:
                raise PolicyError("cannot close Landlock ruleset descriptor") from exc
        if not ready and command_fd >= 0:
            try:
                os.close(command_fd)
            except OSError as exc:
                raise PolicyError("cannot close proof command descriptor") from exc

    os.umask(0o077)
    try:
        os.execve(command_fd, [command.path, *args.command[1:]], environment)
    except OSError as exc:
        os.close(command_fd)
        raise PolicyError(f"cannot execute proof command: {exc.strerror}") from exc


def main() -> int:
    try:
        run(sys.argv[1:])
    except PolicyError as exc:
        print(f"proof-landlock: {exc}", file=sys.stderr)
        return EXIT_POLICY
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
