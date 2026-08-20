#!/usr/bin/env python3
"""Identify the foreground Claude/Codex session in a local tmux session.

The tool deliberately uses live process-owned state:

* tmux identifies the pane and its process tree.
* the kernel process table identifies the agent process and its argv.
* Codex is identified through the rollout JSONL file held open by that process.
* Claude is identified through its PID-scoped active-session registry, with the
  PID start time checked to reject stale files and PID reuse.

It never guesses from the newest transcript in a working directory.
"""

from __future__ import annotations

import argparse
import ctypes
import dataclasses
import datetime
import json
import os
import pathlib
import platform
import re
import shlex
import struct
import subprocess
import sys
import time
from typing import Iterable


UUID_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)


class InspectionError(RuntimeError):
    """A result cannot be established from authoritative live state."""


@dataclasses.dataclass(frozen=True)
class Pane:
    session: str
    pane_id: str
    pane_pid: int
    tty: str
    cwd: str


@dataclasses.dataclass(frozen=True)
class Process:
    pid: int
    ppid: int
    pgid: int
    tpgid: int
    tty: str
    comm: str


@dataclasses.dataclass
class Result:
    tmux_session: str
    pane_id: str
    pane_pid: int
    cwd: str
    agent: str | None = None
    agent_pid: int | None = None
    executable: str | None = None
    argv: list[str] | None = None
    command: str | None = None
    session_id: str | None = None
    evidence: str | None = None
    error: str | None = None


def run(command: list[str]) -> str:
    environment = os.environ.copy()
    environment.pop("LC_ALL", None)
    environment["LC_CTYPE"] = "C.UTF-8"
    try:
        completed = subprocess.run(
            command,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=environment,
        )
    except FileNotFoundError as exc:
        raise InspectionError(f"required command not found: {command[0]}") from exc
    except subprocess.CalledProcessError as exc:
        detail = exc.stderr.strip() or exc.stdout.strip() or f"exit {exc.returncode}"
        raise InspectionError(f"{' '.join(command)} failed: {detail}") from exc
    return completed.stdout


def list_panes(socket_name: str, session_name: str) -> list[Pane]:
    output = run(
        [
            "tmux",
            "-L",
            socket_name,
            "list-panes",
            "-a",
            "-F",
            "#{session_name}\t#{pane_id}\t#{pane_pid}\t#{pane_tty}\t#{pane_current_path}",
        ]
    )
    panes: list[Pane] = []
    for line in output.splitlines():
        fields = line.split("\t", 4)
        if len(fields) != 5 or fields[0] != session_name:
            continue
        try:
            pane_pid = int(fields[2])
        except ValueError as exc:
            raise InspectionError(f"tmux returned an invalid pane PID: {fields[2]!r}") from exc
        panes.append(Pane(fields[0], fields[1], pane_pid, fields[3], fields[4]))
    if not panes:
        raise InspectionError(
            f"no exact tmux session named {session_name!r} on socket {socket_name!r}"
        )
    return panes


def process_table() -> dict[int, Process]:
    output = run(
        ["ps", "-axo", "pid=,ppid=,pgid=,tpgid=,tty=,comm="]
    )
    processes: dict[int, Process] = {}
    for line in output.splitlines():
        fields = line.strip().split(None, 5)
        if len(fields) != 6:
            continue
        try:
            process = Process(
                pid=int(fields[0]),
                ppid=int(fields[1]),
                pgid=int(fields[2]),
                tpgid=int(fields[3]),
                tty=fields[4],
                comm=fields[5],
            )
        except ValueError:
            continue
        processes[process.pid] = process
    return processes


def descendants(root_pid: int, processes: dict[int, Process]) -> dict[int, int]:
    """Return descendant PID -> distance from root, including root at zero."""
    children: dict[int, list[int]] = {}
    for process in processes.values():
        children.setdefault(process.ppid, []).append(process.pid)

    depths = {root_pid: 0}
    pending = [root_pid]
    while pending:
        parent = pending.pop()
        for child in children.get(parent, []):
            if child in depths:
                continue
            depths[child] = depths[parent] + 1
            pending.append(child)
    return depths


def agent_kind(process: Process) -> str | None:
    name = pathlib.Path(process.comm).name.lower()
    if name == "codex" or name.startswith("codex-"):
        return "codex"
    if name in {"claude", "claude.exe"} or name.startswith("claude-"):
        return "claude"
    return None


def find_agent(pane: Pane, processes: dict[int, Process]) -> tuple[str, Process]:
    depths = descendants(pane.pane_pid, processes)
    candidates: list[tuple[int, str, Process]] = []
    for pid, depth in depths.items():
        process = processes.get(pid)
        if process is None:
            continue
        kind = agent_kind(process)
        if kind is None or process.pgid != process.tpgid:
            continue
        # Only the pane's foreground job is its interactive agent. A detached
        # `codex exec` in the same process tree is background work, not the TUI
        # that should replace the shell after a reboot.
        candidates.append((depth, kind, process))

    if not candidates:
        raise InspectionError("no running Claude or Codex process in this pane")
    candidates.sort(key=lambda item: (item[0], item[2].pid))
    best = candidates[0]
    tied = [item for item in candidates if item[0] == best[0]]
    if len(tied) > 1:
        pids = ", ".join(str(item[2].pid) for item in tied)
        raise InspectionError(f"multiple equally plausible agent processes: {pids}")
    return best[1], best[2]


def parse_nul_strings(raw: bytes, start: int) -> tuple[list[bytes], int]:
    values: list[bytes] = []
    position = start
    while position < len(raw):
        end = raw.find(b"\0", position)
        if end < 0:
            end = len(raw)
        values.append(raw[position:end])
        position = end + 1
        if end == len(raw):
            break
    return values, position


def macos_procargs(pid: int) -> tuple[str, list[str], dict[str, str]]:
    """Read executable, argv, and environment from macOS KERN_PROCARGS2."""
    ctl_kern = 1
    kern_procargs2 = 49
    libc = ctypes.CDLL(None, use_errno=True)
    mib = (ctypes.c_int * 3)(ctl_kern, kern_procargs2, pid)
    size = ctypes.c_size_t()
    if libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0) != 0:
        errno = ctypes.get_errno()
        raise InspectionError(f"cannot size argv for PID {pid}: errno {errno}")
    buffer = ctypes.create_string_buffer(size.value)
    if libc.sysctl(mib, 3, buffer, ctypes.byref(size), None, 0) != 0:
        errno = ctypes.get_errno()
        raise InspectionError(f"cannot read argv for PID {pid}: errno {errno}")

    raw = buffer.raw[: size.value]
    if len(raw) < struct.calcsize("i"):
        raise InspectionError(f"kernel returned truncated argv for PID {pid}")
    argc = struct.unpack_from("i", raw)[0]
    position = struct.calcsize("i")
    executable_end = raw.find(b"\0", position)
    if executable_end < 0:
        raise InspectionError(f"kernel returned malformed argv for PID {pid}")
    executable = os.fsdecode(raw[position:executable_end])
    position = executable_end + 1
    while position < len(raw) and raw[position] == 0:
        position += 1

    values, _ = parse_nul_strings(raw, position)
    if len(values) < argc:
        raise InspectionError(f"kernel returned only {len(values)} of {argc} args for PID {pid}")
    argv = [os.fsdecode(value) for value in values[:argc]]
    environment: dict[str, str] = {}
    for value in values[argc:]:
        decoded = os.fsdecode(value)
        if "=" not in decoded:
            continue
        key, item = decoded.split("=", 1)
        environment[key] = item
    return executable, argv, environment


def linux_procargs(pid: int) -> tuple[str, list[str], dict[str, str]]:
    proc = pathlib.Path("/proc") / str(pid)
    try:
        executable = os.readlink(proc / "exe")
        argv = [os.fsdecode(value) for value in (proc / "cmdline").read_bytes().split(b"\0") if value]
        env_values = (proc / "environ").read_bytes().split(b"\0")
    except OSError as exc:
        raise InspectionError(f"cannot read kernel process state for PID {pid}: {exc}") from exc
    environment: dict[str, str] = {}
    for value in env_values:
        decoded = os.fsdecode(value)
        if "=" in decoded:
            key, item = decoded.split("=", 1)
            environment[key] = item
    return executable, argv, environment


def process_args(pid: int) -> tuple[str, list[str], dict[str, str]]:
    system = platform.system()
    if system == "Darwin":
        return macos_procargs(pid)
    if system == "Linux":
        return linux_procargs(pid)
    raise InspectionError(f"exact argv inspection is not implemented on {system}")


def process_start(pid: int) -> tuple[datetime.datetime, datetime.datetime]:
    """Return the process start formatted in local time and UTC.

    Claude's active-session registry currently records ``procStart`` in UTC
    while macOS ``ps`` displays it in local time. Comparing the strings
    directly would therefore reject every valid record outside UTC.
    """
    value = " ".join(run(["ps", "-p", str(pid), "-o", "lstart="]).split())
    try:
        parsed = datetime.datetime.strptime(value, "%a %b %d %H:%M:%S %Y")
    except ValueError as exc:
        raise InspectionError(f"cannot parse process start time for PID {pid}: {value}") from exc
    epoch = time.mktime(parsed.timetuple())
    utc = datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).replace(tzinfo=None)
    return parsed, utc


def codex_session_id(
    pid: int, environment: dict[str, str]
) -> tuple[str, str]:
    codex_home = pathlib.Path(
        environment.get("CODEX_HOME", str(pathlib.Path.home() / ".codex"))
    ).expanduser().resolve()
    sessions_root = codex_home / "sessions"

    def is_rollout(path: pathlib.Path) -> bool:
        try:
            path.resolve().relative_to(sessions_root)
        except (OSError, ValueError):
            return False
        return path.name.startswith("rollout-") and path.name.endswith(".jsonl")

    output = run(["lsof", "-n", "-Fn", "-p", str(pid)])
    rollout_paths = sorted(
        {
            str(pathlib.Path(line[1:]))
            for line in output.splitlines()
            if line.startswith("n")
            and is_rollout(pathlib.Path(line[1:]))
        }
    )
    if not rollout_paths:
        raise InspectionError("Codex process has no open session rollout file")
    if len(rollout_paths) != 1:
        raise InspectionError(
            "Codex process has multiple open session rollout files: "
            + ", ".join(rollout_paths)
        )

    rollout = pathlib.Path(rollout_paths[0])
    try:
        with rollout.open("rb") as handle:
            first_line = handle.readline()
        record = json.loads(first_line)
    except (OSError, json.JSONDecodeError) as exc:
        raise InspectionError(f"cannot read Codex session metadata from {rollout}: {exc}") from exc
    if record.get("type") != "session_meta" or not isinstance(record.get("payload"), dict):
        raise InspectionError(f"Codex rollout lacks a session_meta first record: {rollout}")
    session_id = record["payload"].get("id") or record["payload"].get("session_id")
    if not isinstance(session_id, str) or not UUID_RE.fullmatch(session_id):
        raise InspectionError(f"Codex rollout has an invalid session ID: {rollout}")
    return session_id, f"open Codex rollout: {rollout} (session_meta.payload.id)"


def claude_session_id(
    pid: int, environment: dict[str, str]
) -> tuple[str, str]:
    config_dir = pathlib.Path(
        environment.get("CLAUDE_CONFIG_DIR", str(pathlib.Path.home() / ".claude"))
    ).expanduser()
    registry = config_dir / "sessions" / f"{pid}.json"
    try:
        record = json.loads(registry.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise InspectionError(f"cannot read Claude active-session record {registry}: {exc}") from exc

    if record.get("pid") != pid:
        raise InspectionError(f"Claude active-session record has the wrong PID: {registry}")
    recorded_start = record.get("procStart")
    live_start_local, live_start_utc = process_start(pid)
    try:
        parsed_recorded_start = datetime.datetime.strptime(
            " ".join(recorded_start.split()), "%a %b %d %H:%M:%S %Y"
        )
    except (AttributeError, ValueError) as exc:
        raise InspectionError(
            f"Claude active-session record has an invalid process start: {registry}"
        ) from exc
    if parsed_recorded_start not in {live_start_local, live_start_utc}:
        raise InspectionError(
            f"Claude active-session record is stale (process start mismatch): {registry}"
        )
    session_id = record.get("sessionId")
    if not isinstance(session_id, str) or not UUID_RE.fullmatch(session_id):
        raise InspectionError(f"Claude active-session record has an invalid session ID: {registry}")
    return session_id, f"Claude active-session registry: {registry} (PID + procStart verified)"


def inspect_pane(pane: Pane, processes: dict[int, Process]) -> Result:
    result = Result(
        tmux_session=pane.session,
        pane_id=pane.pane_id,
        pane_pid=pane.pane_pid,
        cwd=pane.cwd,
    )
    try:
        kind, process = find_agent(pane, processes)
        executable, argv, environment = process_args(process.pid)
        result.agent = kind
        result.agent_pid = process.pid
        result.executable = executable
        result.argv = argv
        result.command = shlex.join(argv)
        if kind == "codex":
            result.session_id, result.evidence = codex_session_id(
                process.pid, environment
            )
        else:
            result.session_id, result.evidence = claude_session_id(
                process.pid, environment
            )
    except InspectionError as exc:
        result.error = str(exc)
    return result


def print_human(results: Iterable[Result]) -> None:
    for index, result in enumerate(results):
        if index:
            print()
        print(f"tmux session : {result.tmux_session}")
        print(f"pane         : {result.pane_id} (root PID {result.pane_pid})")
        print(f"directory    : {result.cwd}")
        if result.error:
            print(f"error        : {result.error}")
            continue
        print(f"agent        : {result.agent} (PID {result.agent_pid})")
        print(f"executable   : {result.executable}")
        print(f"argv         : {json.dumps(result.argv, ensure_ascii=False)}")
        print(f"command      : {result.command}")
        print(f"session ID   : {result.session_id}")
        print(f"evidence     : {result.evidence}")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Report the live Claude/Codex command and session ID in a tmux session."
    )
    parser.add_argument("session", help="exact tmux session name")
    parser.add_argument(
        "--socket",
        default=os.environ.get("UT_TMUX_SOCKET", "ut"),
        help="tmux socket name (default: %(default)s)",
    )
    parser.add_argument("--pane", help="inspect only this pane ID (for multi-pane sessions)")
    parser.add_argument("--json", action="store_true", help="emit machine-readable JSON")
    arguments = parser.parse_args()

    try:
        panes = list_panes(arguments.socket, arguments.session)
        if arguments.pane:
            panes = [pane for pane in panes if pane.pane_id == arguments.pane]
            if not panes:
                raise InspectionError(
                    f"session {arguments.session!r} has no pane {arguments.pane!r}"
                )
        processes = process_table()
        results = [inspect_pane(pane, processes) for pane in panes]
    except InspectionError as exc:
        if arguments.json:
            print(json.dumps({"error": str(exc)}, indent=2))
        else:
            print(f"error: {exc}", file=sys.stderr)
        return 2

    if arguments.json:
        payload: object = dataclasses.asdict(results[0]) if len(results) == 1 else [
            dataclasses.asdict(result) for result in results
        ]
        print(json.dumps(payload, indent=2, ensure_ascii=False))
    else:
        print_human(results)
    return 1 if any(result.error for result in results) else 0


if __name__ == "__main__":
    raise SystemExit(main())
