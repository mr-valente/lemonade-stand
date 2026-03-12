#!/usr/bin/env python3
"""
Polished Textual/Rich TUI monitor for AMD Ryzen AI NPU activity via:
    xrt-smi examine --report aie-partitions --verbose

Features:
- Textual-based full-screen TUI
- Polls xrt-smi on an interval
- Parses HW contexts from AIE Partitions
- Live summary header
- Per-context activity table
- Rolling activity sparkline / mini graph
- Optional process-name resolution from /proc/<pid>

Requirements:
    pip install textual rich

Usage:
    python npu_top.py
    python npu_top.py --interval 0.5
    python npu_top.py --sudo
    python npu_top.py --command "sudo xrt-smi examine --report aie-partitions --verbose"

Keys:
    q           Quit
    p           Pause / resume polling
    r           Reset history
    n           Toggle process-name lookup
    + / -       Decrease / increase poll interval
"""

from __future__ import annotations

import argparse
import os
import re
import shlex
import subprocess
import time
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple

from rich.table import Table
from rich.text import Text
from textual import events
from textual.app import App, ComposeResult
from textual.containers import Container, Horizontal, Vertical
from textual.reactive import reactive
from textual.timer import Timer
from textual.widgets import Footer, Header, Static

DEFAULT_COMMAND = "xrt-smi examine --report aie-partitions --verbose"
SPARK_CHARS = "▁▂▃▄▅▆▇█"


@dataclass
class ContextStats:
    pid: int
    ctx_id: int
    submissions: int
    completions: int
    migrations: int
    suspensions: int
    err: int
    status: str
    priority: str
    process_name: str = ""


@dataclass
class Sample:
    timestamp: float
    contexts: Dict[Tuple[int, int], ContextStats]
    raw_text: str
    meta: Dict[str, str]


CONTEXT_HEADER_RE = re.compile(
    r"^\s*\|(?P<pid>\d+)\s*\|(?P<ctx>\d+)\s*\|(?P<sub>\d+)\s*\|(?P<mig>\d+)\s*\|(?P<err>\d+)\s*\|(?P<prio>[^|]+)\|\s*$"
)
CONTEXT_STATUS_RE = re.compile(
    r"^\s*\|(?P<proc>[^|]*)\|(?P<status>[^|]*)\|(?P<comp>\d+)\s*\|(?P<susp>\d+)\s*\|(?P<blank>[^|]*)\|(?P<metric>[^|]*)\|\s*$"
)
DEVICE_RE = re.compile(r"^\[(?P<pci>[^\]]+)\]\s*:\s*(?P<platform>.+)$")
COLUMNS_RE = re.compile(r"^\s*Columns:\s*\[(?P<cols>[^\]]+)\]")
PARTITION_RE = re.compile(r"^\s*Partition Index\s*:\s*(?P<idx>\d+)")


def run_command(command: str, timeout: float = 5.0) -> str:
    proc = subprocess.run(
        shlex.split(command),
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )
    if proc.returncode != 0:
        stderr = proc.stderr.strip()
        stdout = proc.stdout.strip()
        msg = stderr or stdout or f"command exited with {proc.returncode}"
        raise RuntimeError(msg)
    return proc.stdout


def get_process_name(pid: int) -> str:
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            raw = f.read().replace(b"\x00", b" ").decode(errors="replace").strip()
        if raw:
            return os.path.basename(raw.split()[0])
    except Exception:
        pass
    try:
        with open(f"/proc/{pid}/comm", "r", encoding="utf-8", errors="replace") as f:
            return f.read().strip()
    except Exception:
        return "?"


def parse_output(text: str, resolve_names: bool = True) -> Tuple[Dict[Tuple[int, int], ContextStats], Dict[str, str]]:
    lines = text.splitlines()
    contexts: Dict[Tuple[int, int], ContextStats] = {}
    meta: Dict[str, str] = {
        "device": "Unknown",
        "platform": "Unknown",
        "partition": "?",
        "columns": "?",
    }
    pid_name_cache: Dict[int, str] = {}

    for i, line in enumerate(lines):
        stripped = line.strip()

        m = DEVICE_RE.match(stripped)
        if m:
            meta["device"] = m.group("pci")
            meta["platform"] = m.group("platform")
            continue

        m = PARTITION_RE.match(line)
        if m:
            meta["partition"] = m.group("idx")
            continue

        m = COLUMNS_RE.match(line)
        if m:
            meta["columns"] = m.group("cols").replace(" ", "")
            continue

        m1 = CONTEXT_HEADER_RE.match(line)
        if not m1 or i + 1 >= len(lines):
            continue
        m2 = CONTEXT_STATUS_RE.match(lines[i + 1])
        if not m2:
            continue

        pid = int(m1.group("pid"))
        ctx_id = int(m1.group("ctx"))
        name = ""
        if resolve_names:
            if pid not in pid_name_cache:
                pid_name_cache[pid] = get_process_name(pid)
            name = pid_name_cache[pid]

        stat = ContextStats(
            pid=pid,
            ctx_id=ctx_id,
            submissions=int(m1.group("sub")),
            completions=int(m2.group("comp")),
            migrations=int(m1.group("mig")),
            suspensions=int(m2.group("susp")),
            err=int(m1.group("err")),
            status=m2.group("status").strip() or "?",
            priority=m1.group("prio").strip() or "?",
            process_name=name,
        )
        contexts[(pid, ctx_id)] = stat

    return contexts, meta


def compute_deltas(prev: Optional[Sample], cur: Sample) -> Dict[Tuple[int, int], Tuple[float, float]]:
    result: Dict[Tuple[int, int], Tuple[float, float]] = {}
    if prev is None:
        return {key: (0.0, 0.0) for key in cur.contexts}

    dt = max(cur.timestamp - prev.timestamp, 1e-6)
    for key, cur_stat in cur.contexts.items():
        prev_stat = prev.contexts.get(key)
        if prev_stat is None:
            result[key] = (0.0, 0.0)
            continue
        ds = max(0, cur_stat.submissions - prev_stat.submissions)
        dc = max(0, cur_stat.completions - prev_stat.completions)
        result[key] = (ds / dt, dc / dt)
    return result


def sparkline(values: List[float], width: int) -> str:
    if width <= 0:
        return ""
    if not values:
        return " " * width
    vals = values[-width:]
    maxv = max(vals) if max(vals) > 0 else 1.0
    chars = []
    for v in vals:
        idx = int(round((len(SPARK_CHARS) - 1) * (v / maxv)))
        idx = max(0, min(len(SPARK_CHARS) - 1, idx))
        chars.append(SPARK_CHARS[idx])
    if len(chars) < width:
        chars = [" "] * (width - len(chars)) + chars
    return "".join(chars)


class SummaryWidget(Static):
    def update_summary(self, sample: Optional[Sample], history: List[float], paused: bool, interval: float, error: str) -> None:
        if sample is None:
            self.update("[b]Waiting for first sample...[/b]")
            return

        active = sum(1 for c in sample.contexts.values() if c.status.lower() == "active")
        total = len(sample.contexts)
        cur_rate = history[-1] if history else 0.0
        peak = max(history) if history else 0.0

        text = Text()
        text.append("Device: ", style="bold cyan")
        text.append(sample.meta.get("device", "?"))
        text.append("   Platform: ", style="bold cyan")
        text.append(sample.meta.get("platform", "?"))
        text.append("   Partition: ", style="bold cyan")
        text.append(sample.meta.get("partition", "?"))
        text.append("   Columns: ", style="bold cyan")
        text.append(sample.meta.get("columns", "?"))
        text.append("\n")
        text.append("Contexts: ", style="bold green")
        text.append(f"{active}/{total} active")
        text.append("   Poll: ", style="bold green")
        text.append(f"{interval:.1f}s")
        text.append("   State: ", style="bold green")
        text.append("paused" if paused else "running", style="yellow" if paused else "green")
        text.append("   Completion rate: ", style="bold green")
        text.append(f"{cur_rate:.1f}/s")
        text.append("   Peak: ", style="bold green")
        text.append(f"{peak:.1f}/s")
        if error:
            text.append("\nError: ", style="bold red")
            text.append(error, style="red")
        self.update(text)


class GraphWidget(Static):
    def update_graph(self, history: List[float], width: int = 80) -> None:
        if width < 10:
            width = 10
        current = history[-1] if history else 0.0
        peak = max(history) if history else 0.0
        line = sparkline(history, width)
        self.update(
            Text.from_markup(
                f"[b cyan]Activity[/b cyan]  current=[green]{current:.1f}[/green]/s  peak=[yellow]{peak:.1f}[/yellow]/s\n"
                f"[magenta]{line}[/magenta]"
            )
        )


class ContextTableWidget(Static):
    def update_table(self, sample: Optional[Sample], deltas: Dict[Tuple[int, int], Tuple[float, float]]) -> None:
        table = Table(expand=True)
        table.add_column("PID", justify="right", no_wrap=True)
        table.add_column("CTX", justify="right", no_wrap=True)
        table.add_column("Status", no_wrap=True)
        table.add_column("Submissions", justify="right")
        table.add_column("Completions", justify="right")
        table.add_column("Sub/s", justify="right")
        table.add_column("Cmp/s", justify="right")
        table.add_column("Err", justify="right")
        table.add_column("Process", overflow="fold")

        if sample is None:
            table.add_row("-", "-", "Waiting", "-", "-", "-", "-", "-", "-")
            self.update(table)
            return

        items = sorted(
            sample.contexts.values(),
            key=lambda s: (s.status.lower() != "active", -s.completions, s.pid, s.ctx_id),
        )
        for stat in items:
            sub_rate, cmp_rate = deltas.get((stat.pid, stat.ctx_id), (0.0, 0.0))
            status_style = "bold green" if stat.status.lower() == "active" else "white"
            err_style = "bold red" if stat.err > 0 else "white"
            proc = stat.process_name or "N/A"
            table.add_row(
                str(stat.pid),
                str(stat.ctx_id),
                Text(stat.status, style=status_style),
                str(stat.submissions),
                str(stat.completions),
                f"{sub_rate:.1f}",
                f"{cmp_rate:.1f}",
                Text(str(stat.err), style=err_style),
                proc,
            )

        self.update(table)


class HelpWidget(Static):
    def on_mount(self) -> None:
        self.update(
            "[b]Keys[/b]: [cyan]q[/cyan] quit   [cyan]p[/cyan] pause   [cyan]r[/cyan] reset   "
            "[cyan]n[/cyan] toggle names   [cyan]+/-[/cyan] adjust poll interval"
        )


class NPUMonitorApp(App):
    CSS = """
    Screen {
        layout: vertical;
    }

    #main {
        height: 1fr;
        layout: vertical;
    }

    #summary {
        height: 4;
        border: round $accent;
        padding: 0 1;
        margin: 0 0 1 0;
    }

    #graph {
        height: 4;
        border: round green;
        padding: 0 1;
        margin: 0 0 1 0;
    }

    #table {
        height: 1fr;
        border: round cyan;
        padding: 0 1;
        margin: 0 0 1 0;
        overflow: auto;
    }

    #help {
        height: 3;
        border: round yellow;
        padding: 0 1;
    }
    """

    BINDINGS = [
        ("q", "quit", "Quit"),
        ("p", "toggle_pause", "Pause"),
        ("r", "reset_history", "Reset"),
        ("n", "toggle_names", "Names"),
        ("+", "faster", "Faster"),
        ("-", "slower", "Slower"),
    ]

    paused = reactive(False)
    interval = reactive(0.5)
    resolve_names = reactive(True)

    def __init__(self, command: str, interval: float, resolve_names: bool) -> None:
        super().__init__()
        self.command = command
        self.interval = interval
        self.resolve_names = resolve_names
        self.prev_sample: Optional[Sample] = None
        self.current_sample: Optional[Sample] = None
        self.current_deltas: Dict[Tuple[int, int], Tuple[float, float]] = {}
        self.history: List[float] = []
        self.error: str = ""
        self.timer_handle: Optional[Timer] = None

    def compose(self) -> ComposeResult:
        yield Header(show_clock=True)
        with Container(id="main"):
            yield SummaryWidget(id="summary")
            yield GraphWidget(id="graph")
            yield ContextTableWidget(id="table")
            yield HelpWidget(id="help")
        yield Footer()

    def on_mount(self) -> None:
        self.timer_handle = self.set_interval(self.interval, self.poll_once, pause=False)
        self.poll_once()

    def poll_once(self) -> None:
        if self.paused:
            self.refresh_view()
            return

        now = time.time()
        try:
            text = run_command(self.command, timeout=max(5.0, self.interval * 4))
            contexts, meta = parse_output(text, resolve_names=self.resolve_names)
            sample = Sample(timestamp=now, contexts=contexts, raw_text=text, meta=meta)
            self.current_deltas = compute_deltas(self.prev_sample, sample)
            rate = sum(dc for _, dc in self.current_deltas.values())
            self.history.append(rate)
            self.history = self.history[-600:]
            self.prev_sample = self.current_sample
            self.current_sample = sample
            self.error = ""
        except Exception as e:
            self.error = str(e)
        self.refresh_view()

    def refresh_view(self) -> None:
        self.query_one(SummaryWidget).update_summary(
            self.current_sample, self.history, self.paused, self.interval, self.error
        )
        graph_width = max(20, self.size.width - 10)
        self.query_one(GraphWidget).update_graph(self.history, width=graph_width)
        deltas = self.current_deltas if not self.paused else {
            key: (0.0, 0.0) for key in (self.current_sample.contexts if self.current_sample else {})
        }
        self.query_one(ContextTableWidget).update_table(self.current_sample, deltas)
        self.sub_title = f"interval={self.interval:.1f}s | names={'on' if self.resolve_names else 'off'} | {'paused' if self.paused else 'running'}"

    def update_timer(self) -> None:
        if self.timer_handle is not None:
            self.timer_handle.stop()
        self.timer_handle = self.set_interval(self.interval, self.poll_once, pause=False)

    def action_toggle_pause(self) -> None:
        self.paused = not self.paused
        self.refresh_view()

    def action_reset_history(self) -> None:
        self.history.clear()
        self.prev_sample = None
        self.current_deltas = {}
        self.refresh_view()

    def action_toggle_names(self) -> None:
        self.resolve_names = not self.resolve_names
        self.prev_sample = None
        self.current_deltas = {}
        self.poll_once()

    def action_faster(self) -> None:
        self.interval = max(0.1, self.interval - 0.1)
        self.update_timer()
        self.refresh_view()

    def action_slower(self) -> None:
        self.interval = min(10.0, self.interval + 0.1)
        self.update_timer()
        self.refresh_view()

    async def on_key(self, event: events.Key) -> None:
        if event.key == "+":
            self.action_faster()
            event.stop()
        elif event.key == "-":
            self.action_slower()
            event.stop()


def main() -> None:
    parser = argparse.ArgumentParser(description="Textual/Rich TUI monitor for Ryzen AI NPU via xrt-smi")
    parser.add_argument("--interval", type=float, default=0.5, help="poll interval in seconds")
    parser.add_argument("--command", default=DEFAULT_COMMAND, help="command to poll")
    parser.add_argument("--sudo", action="store_true", help="prepend sudo to the default command")
    parser.add_argument("--no-names", action="store_true", help="disable /proc process-name resolution")
    args = parser.parse_args()

    command = args.command
    if args.sudo and command == DEFAULT_COMMAND:
        command = "sudo " + DEFAULT_COMMAND

    app = NPUMonitorApp(
        command=command,
        interval=args.interval,
        resolve_names=not args.no_names,
    )
    app.run()


if __name__ == "__main__":
    main()
