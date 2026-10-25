#!/usr/bin/env python3
"""Run the M v9 suites in an isolated original-path Godot project.

Python standard library only. A missing/zero summary, timeout, fatal diagnostic,
or mismatching replay is a failure, regardless of the Godot process exit status.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import signal
import subprocess
import sys
import time

VERSION = "4.6.3.stable.official.7d41c59c4"
FATAL = re.compile(r"(?im)^ERROR:|SCRIPT ERROR|Parse Error|Failed to load script|Assertion failed|^FAIL(?:\b|:)")
LOG_LIMIT = 16 * 1024 * 1024
OUTPUT_LIMIT = 256 * 1024 * 1024
SUITES = [
    ("resolver", "tests.gd", "War resolver", []),
    ("roles", "role_tests.gd", "Role overrides", []),
    ("attachment-tactical", "attachment_continuity/tests.gd", "Tactical continuity local", ["--", "--tactical-continuity"]),
]
PROBES = [
    ("resolver", "replay_probe.gd", "REPLAY_SHA256", 180),
    ("roles", "role_replay_probe.gd", "ROLE_REPLAY_SHA256", 240),
]


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def disk_bytes(root: Path) -> int:
    total = 0
    for path in root.rglob("*"):
        try:
            if path.is_file():
                total += path.stat().st_size
        except FileNotFoundError:
            # Godot may atomically replace an editor cache during import.
            continue
    return total


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--work-dir", type=Path, required=True)
    parser.add_argument("--test-timeout", type=int, default=900)
    parser.add_argument("--suite", action="append", choices=[row[0] for row in SUITES],
                        help="Run only selected original suites; omitted suites/replays are NOT_RUN")
    parser.add_argument("--case", help="Select an original test function (requires one --suite)")
    parser.add_argument("--replays", action="store_true", help="Include original replay pairs with a suite selection")
    args = parser.parse_args()
    if args.case is not None:
        if not args.case:
            parser.error("--case must not be empty")
        if not args.suite or len(args.suite) != 1:
            parser.error("--case requires exactly one --suite")
    selected = set(args.suite or [row[0] for row in SUITES])
    replay_selected = not args.suite or args.replays
    partial = bool(args.suite or args.case)
    if args.test_timeout <= 0:
        parser.error("test-timeout must be positive")
    repo = Path(__file__).resolve().parents[2]
    output, work = args.output.resolve(), args.work_dir.resolve()
    # Never let temporary project assembly overwrite a checkout or old evidence.
    if output == work or output in work.parents or work in output.parents:
        parser.error("output and work-dir must be separate directories")
    if repo == work or repo in work.parents or repo == output or repo in output.parents:
        parser.error("output and work-dir must be outside the repository")
    if output.exists() and any(output.iterdir()) or work.exists():
        parser.error("use fresh output/work-dir paths for each run")
    output.mkdir(parents=True, exist_ok=True)
    work.mkdir(parents=True)
    env = os.environ.copy()
    for kind in ("DATA", "CONFIG", "CACHE"):
        directory = work / "xdg" / kind.lower()
        directory.mkdir(parents=True)
        env[f"XDG_{kind}_HOME"] = str(directory)
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    executable = shutil.which(args.godot)
    report = {
        "schema": "military-ci-v1", "development_phase": "M v9",
        "runtime_format": "war-environment-runtime-v8",
        "source_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip(),
        "python": sys.version, "platform": sys.platform, "expected_godot": VERSION,
        "engine_binary_sha256": sha(Path(executable)) if executable else None,
        "scope": "isolated research; no formal host, GUI, Android or full regressions",
        "steps": [], "replays": [], "complete": False,
        "selection": {"suites": sorted(selected), "case": args.case, "replays": replay_selected},
        "full_validation": not partial,
        "excluded": [{"name": "formal-host-regressions", "status": "NOT_RUN",
                      "reason": "Original host owners, resources and regression fixtures are excluded; inert provenance snapshots are never loaded."}],
    }

    def save() -> None:
        (output / "results.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf8")

    def run(name: str, arguments: list[str], timeout: int, summary: str | None = None) -> dict:
        command = [executable or args.godot, *arguments]
        started = time.monotonic()
        raw = bytearray()
        aborted = None
        code = None
        try:
            proc = subprocess.Popen(command, cwd=work, env=env, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, start_new_session=True)
            with selectors.DefaultSelector() as selector:
                selector.register(proc.stdout, selectors.EVENT_READ)
                while selector.get_map():
                    if time.monotonic() - started > timeout:
                        aborted = "TIMEOUT"
                        break
                    for key, _ in selector.select(0.2):
                        chunk = os.read(key.fd, 65536)
                        if not chunk:
                            selector.unregister(key.fileobj)
                            continue
                        room = LOG_LIMIT - len(raw)
                        raw.extend(chunk[:room])
                        if len(chunk) > room:
                            aborted = "LOG_LIMIT"
                            break
                    if aborted:
                        break
                    if disk_bytes(work) > OUTPUT_LIMIT:
                        aborted = "WORK_DISK_LIMIT"
                        break
            if aborted:
                os.killpg(proc.pid, signal.SIGKILL)
            code = proc.wait(timeout=5)
            proc.stdout.close()
        except OSError as exc:
            raw.extend(f"Runner launch error: {exc}\n".encode())
            aborted = "EXECUTABLE_UNAVAILABLE"
        log = raw.decode("utf8", errors="replace")
        (output / f"{name}.log").write_text(log, encoding="utf8")
        fatal = FATAL.search(log)
        row = {"name": name, "command": command, "cwd": str(work), "exit_code": code,
               "abort_reason": aborted, "wall_seconds": round(time.monotonic() - started, 3),
               "log": f"{name}.log",
               "fatal": fatal.group(0) if fatal else None, "checks": None, "failures": None}
        if summary:
            matches = re.findall(re.escape(summary) + r": (\d+) checks, (\d+) failures", log)
            if len(matches) == 1:
                row["checks"], row["failures"] = map(int, matches[0])
        passed = code == 0 and aborted is None and fatal is None
        if summary:
            passed = passed and row["checks"] is not None and row["checks"] > 0 and row["failures"] == 0
        row["status"] = "PASSED" if passed else "FAILED"
        missing = []
        for resource in re.findall(r"res://[^\s\"'()]+", log):
            resource = resource.rstrip(".,:")
            if not (work / resource.removeprefix("res://")).exists():
                missing.append(resource)
        if not passed and (aborted == "EXECUTABLE_UNAVAILABLE" or missing and re.search(r"not found|does not exist|doesn't exist|Could not find|Cannot open", log, re.I)):
            row["status"] = "BLOCKED_BY_DEPENDENCY"
            row["missing_resources"] = sorted(set(missing))
        report["steps"].append(row)
        save()
        print(f"{row['status']} {name}: checks={row['checks']} failures={row['failures']} exit={code} abort={aborted}", flush=True)
        return row

    def not_run(name: str, reason: str) -> None:
        report["steps"].append({"name": name, "status": "NOT_RUN", "reason": reason,
                                "checks": None, "failures": None, "exit_code": None})
        save()

    save()
    source = repo / "research/m-v9"
    target = work / "experiments/war_resolver"
    # Only executable research sources and their scene/resource metadata are needed.
    paths = sorted(p for p in source.rglob("*") if p.is_file() and p.suffix in {".gd", ".uid", ".tscn", ".tres"})
    source_bytes = {}
    for path in paths:
        relative = path.relative_to(source)
        dest = target / relative
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, dest)
        source_bytes[relative.as_posix()] = path.read_bytes()
        assert source_bytes[relative.as_posix()] == dest.read_bytes()
    if not source_bytes:
        raise RuntimeError("No research source files selected; refusing an empty validation")
    report["source_file_count"] = len(source_bytes)
    (work / "project.godot").write_text('config_version=5\n\n[application]\nconfig/name="WWO isolated M v9 CI"\n\n[rendering]\nrenderer/rendering_method="gl_compatibility"\n', encoding="utf8")
    version = run("engine-version", ["--headless", "--version"], 20)
    report["actual_godot"] = (output / "engine-version.log").read_text().strip()
    if report["actual_godot"] != VERSION:
        version["status"] = "FAILED" if executable else "BLOCKED_BY_DEPENDENCY"
        version["reason"] = "Pinned full engine version required"
    ready = version["status"] == "PASSED"
    if ready:
        ready = run("import", ["--headless", "--editor", "--path", str(work), "--quit"], 90)["status"] == "PASSED"
    else:
        not_run("import", "Engine prerequisite failed")
    headless = ["--headless", "--path", str(work), "--script"]
    for name, script, summary, extra in SUITES:
        if name not in selected:
            not_run(name, "Outside explicit local selection")
        elif ready:
            case_extra = ["--", "--case=" + args.case] if args.case else extra
            run(name, [*headless, "res://experiments/war_resolver/" + script, *case_extra],
                min(args.test_timeout, 240) if extra else args.test_timeout, summary)
        else:
            not_run(name, "Engine/import prerequisite failed")
    for name, script, prefix, timeout in PROBES:
        if not replay_selected:
            for suffix in ("a", "b"):
                not_run(f"{name}-replay-{suffix}", "Outside explicit local selection")
            report["replays"].append({"name": name, "hashes": [], "status": "NOT_RUN"})
            continue
        hashes = []
        rows = []
        for suffix in ("a", "b"):
            label = f"{name}-replay-{suffix}"
            if not ready:
                not_run(label, "Engine/import prerequisite failed")
                continue
            row = run(label, [*headless, "res://experiments/war_resolver/" + script], timeout)
            rows.append(row)
            matches = re.findall(r"(?m)^" + prefix + r"=([a-f0-9]{64})$", (output / row["log"]).read_text())
            hashes.append(matches[0] if len(matches) == 1 and row["status"] == "PASSED" else None)
        same = len(hashes) == 2 and hashes[0] is not None and hashes[0] == hashes[1]
        report["replays"].append({"name": name, "hashes": hashes, "status": "PASSED" if same else "FAILED" if ready else "NOT_RUN",
                                  "scope": "These exact probe inputs in two independent processes only"})
        save()
    report["source_bytes_unchanged"] = all((source / p).read_bytes() == data and (target / p).read_bytes() == data for p, data in source_bytes.items())
    report["complete"] = True
    passed = ready and report["source_bytes_unchanged"] and all(
        r["status"] == "PASSED" or r["status"] == "NOT_RUN" and r.get("reason") == "Outside explicit local selection"
        for r in report["steps"]) and all(
        r["status"] == "PASSED" or not replay_selected and r["status"] == "NOT_RUN" for r in report["replays"])
    report["status"] = ("PARTIAL_PASSED" if partial else "PASSED") if passed else "FAILED"
    save()
    lines = ["# Military CI", "", f"Commit: `{report['source_commit']}`", f"Godot: `{report['actual_godot']}`", "", "| Step | Status | Checks | Failures | Exit |", "| --- | --- | ---: | ---: | ---: |"]
    for row in report["steps"]:
        lines.append(f"| {row['name']} | {row['status']} | {row.get('checks')} | {row.get('failures')} | {row.get('exit_code')} |")
    lines.extend(["", *[f"Replay {r['name']}: {r['status']} {r['hashes']}" for r in report["replays"]], "", "Formal host regressions: NOT_RUN; external host and original fixtures are excluded."])
    (output / "summary.md").write_text("\n".join(lines) + "\n", encoding="utf8")
    print(f"Military CI: {report['status']}; evidence: {output}", flush=True)
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
