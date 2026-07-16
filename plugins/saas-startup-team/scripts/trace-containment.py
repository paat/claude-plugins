#!/usr/bin/env python3
"""Run a command while tracing and containing every descendant process."""

from __future__ import annotations

import ctypes
import errno
import os
import signal
import sys
import time


PTRACE_TRACEME = 0
PTRACE_CONT = 7
PTRACE_SETOPTIONS = 0x4200
PTRACE_GETEVENTMSG = 0x4201

PTRACE_O_TRACEFORK = 1 << 1
PTRACE_O_TRACEVFORK = 1 << 2
PTRACE_O_TRACECLONE = 1 << 3
PTRACE_O_TRACEEXEC = 1 << 4
PTRACE_O_EXITKILL = 1 << 20
PTRACE_OPTIONS = (
    PTRACE_O_TRACEFORK
    | PTRACE_O_TRACEVFORK
    | PTRACE_O_TRACECLONE
    | PTRACE_O_TRACEEXEC
    | PTRACE_O_EXITKILL
)

PTRACE_EVENT_FORK = 1
PTRACE_EVENT_VFORK = 2
PTRACE_EVENT_CLONE = 3
PTRACE_EVENT_EXEC = 4
FORK_EVENTS = {PTRACE_EVENT_FORK, PTRACE_EVENT_VFORK, PTRACE_EVENT_CLONE}

PR_SET_PDEATHSIG = 1
WAIT_ALL = 0x40000000
TERM_GRACE_SECONDS = 1.0
KILL_GRACE_SECONDS = 1.0

libc = ctypes.CDLL(None, use_errno=True)
libc.ptrace.restype = ctypes.c_long


class TraceError(RuntimeError):
    def __init__(self, message: str, error_number: int | None = None) -> None:
        super().__init__(message)
        self.error_number = error_number


def ptrace(request: int, pid: int, data: int = 0) -> None:
    result = libc.ptrace(request, pid, None, ctypes.c_void_p(data))
    if result == -1:
        error = ctypes.get_errno()
        raise TraceError(os.strerror(error), error)


def guard_parent(expected_parent: int) -> None:
    result = libc.prctl(PR_SET_PDEATHSIG, signal.SIGKILL, 0, 0, 0)
    if result == -1:
        error = ctypes.get_errno()
        raise TraceError(os.strerror(error), error)
    if os.getppid() != expected_parent:
        raise TraceError("containment supervisor exited during startup")


def event_pid(pid: int) -> int:
    value = ctypes.c_ulong()
    result = libc.ptrace(PTRACE_GETEVENTMSG, pid, None, ctypes.byref(value))
    if result == -1:
        error = ctypes.get_errno()
        raise TraceError(os.strerror(error), error)
    return int(value.value)


def signal_processes(pids: set[int], signum: int) -> None:
    for pid in tuple(pids):
        try:
            os.kill(pid, signum)
        except ProcessLookupError:
            pids.discard(pid)


def exit_status(status: int) -> int:
    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status)
    if os.WIFSIGNALED(status):
        return 128 + os.WTERMSIG(status)
    return 1


def run(command: list[str]) -> int:
    supervisor_pid = os.getpid()
    root_pid = os.fork()
    if root_pid == 0:
        try:
            guard_parent(supervisor_pid)
            ptrace(PTRACE_TRACEME, 0)
            os.kill(os.getpid(), signal.SIGSTOP)
            os.execvp(command[0], command)
        except (OSError, TraceError) as exc:
            os.write(2, f"trace-containment: cannot start command: {exc}\n".encode())
            os._exit(127)

    try:
        waited_pid, status = os.waitpid(root_pid, 0)
        if waited_pid != root_pid or not os.WIFSTOPPED(status):
            raise TraceError("command did not enter the traced state")
        ptrace(PTRACE_SETOPTIONS, root_pid, PTRACE_OPTIONS)
        ptrace(PTRACE_CONT, root_pid)
    except (OSError, TraceError) as exc:
        try:
            os.kill(root_pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        print(f"trace-containment: cannot establish child containment: {exc}", file=sys.stderr)
        return 1

    live = {root_pid}
    pending_new: set[int] = set()
    early_exits: set[int] = set()
    root_result: int | None = None
    cleanup_signal = 0
    cleanup_deadline = 0.0

    def forward(signum: int, _frame: object) -> None:
        signal_processes(live, signum)

    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, forward)

    while live:
        wait_flags = WAIT_ALL
        if root_result is not None:
            wait_flags |= os.WNOHANG
        try:
            pid, status = os.waitpid(-1, wait_flags)
        except ChildProcessError:
            live.clear()
            break
        except InterruptedError:
            continue

        if root_result is not None:
            now = time.monotonic()
            if cleanup_signal == signal.SIGTERM and now >= cleanup_deadline:
                cleanup_signal = signal.SIGKILL
                cleanup_deadline = now + KILL_GRACE_SECONDS
                signal_processes(live, cleanup_signal)
            elif cleanup_signal == signal.SIGKILL and now >= cleanup_deadline:
                break

        if pid == 0:
            time.sleep(0.01)
            continue

        if os.WIFEXITED(status) or os.WIFSIGNALED(status):
            was_live = pid in live
            live.discard(pid)
            pending_new.discard(pid)
            if not was_live:
                early_exits.add(pid)
            if pid == root_pid and root_result is None:
                root_result = exit_status(status)
                cleanup_signal = signal.SIGTERM
                cleanup_deadline = time.monotonic() + TERM_GRACE_SECONDS
                signal_processes(live, cleanup_signal)
            continue

        if not os.WIFSTOPPED(status):
            continue

        if pid not in live:
            live.add(pid)
            pending_new.add(pid)
        stop_signal = os.WSTOPSIG(status)
        event = status >> 16
        deliver = stop_signal
        try:
            if event in FORK_EVENTS:
                new_pid = event_pid(pid)
                if new_pid in early_exits:
                    early_exits.discard(new_pid)
                elif new_pid not in live:
                    live.add(new_pid)
                    pending_new.add(new_pid)
                deliver = 0
                if cleanup_signal and new_pid in live:
                    target = {new_pid}
                    signal_processes(target, cleanup_signal)
                    if not target:
                        live.discard(new_pid)
                        pending_new.discard(new_pid)
            elif event == PTRACE_EVENT_EXEC:
                old_pid = event_pid(pid)
                if old_pid != pid:
                    live.discard(old_pid)
                    pending_new.discard(old_pid)
                    live.add(pid)
                deliver = 0
            elif pid in pending_new:
                ptrace(PTRACE_SETOPTIONS, pid, PTRACE_OPTIONS)
                pending_new.discard(pid)
                deliver = cleanup_signal
            ptrace(PTRACE_CONT, pid, deliver)
        except TraceError as exc:
            if exc.error_number != errno.ESRCH:
                print(f"trace-containment: lost child containment: {exc}", file=sys.stderr)
                signal_processes(live, signal.SIGKILL)
                return 1

    if live:
        signal_processes(live, signal.SIGKILL)
    return 1 if root_result is None else root_result


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: trace-containment.py COMMAND...", file=sys.stderr)
        return 2
    if sys.platform != "linux":
        print("trace-containment: Linux ptrace is required", file=sys.stderr)
        return 1
    return run(sys.argv[1:])


if __name__ == "__main__":
    raise SystemExit(main())
