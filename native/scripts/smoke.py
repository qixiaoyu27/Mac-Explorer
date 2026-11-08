#!/usr/bin/env python3
"""Drive the actual AppKit app against disposable files; retain reports/screenshots."""
import argparse
import json
import os
import pathlib
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("--skip-build", action="store_true")
parser.add_argument("--validation", action="store_true")
parser.add_argument("--desktop", action="store_true", help="Run isolated desktop takeover checks")
launch = parser.add_mutually_exclusive_group()
launch.add_argument("--foreground", dest="foreground", action="store_true", help="Use normal macOS foreground launch (default)")
launch.add_argument("--direct-launch", dest="foreground", action="store_false", help="Run the executable directly for launch diagnostics")
parser.set_defaults(foreground=True)
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parents[1]
if not args.skip_build:
    subprocess.run([sys.executable, "-I", str(root / "scripts" / "build.py")] + (["--validation"] if args.validation else []), check=True)
app_directory = root / "output" / "validation" if args.validation else root / "output"
output = app_directory / "smoke"
output.mkdir(parents=True, exist_ok=True)
report = output / "report.json"
for previous_report in [report, output / "startup-report.json"]:
    if previous_report.exists():
        previous_report.unlink()
app = app_directory / "Mac Explorer.app" / "Contents" / "MacOS" / "MacExplorerNative"
with tempfile.TemporaryDirectory(prefix="mac-explorer-native-") as temporary:
    fixture = pathlib.Path(temporary)
    for i in range(10_000):
        (fixture / f"file-{i}.txt").write_text(f"Native fixture {i}\n")
    (fixture / "Folder 2").mkdir()
    (fixture / "Folder 2" / "child.txt").write_text("preserve child\n")
    (fixture / "Folder 10").mkdir()
    (fixture / ".hidden-fixture").write_text("preserve hidden\n")
    (fixture / "Linked Folder").symlink_to("Folder 2", target_is_directory=True)
    before = {str(p.relative_to(fixture)): (p.lstat().st_size, p.lstat().st_mtime_ns, os.readlink(p) if p.is_symlink() else None) for p in fixture.rglob("*")}
    with tempfile.TemporaryDirectory(prefix="native-startup-check-") as check_directory:
        checker = pathlib.Path(check_directory) / "startup-check"
        subprocess.run([
            "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
            str(root / "scripts" / "StartupCheck.swift"), "-o", str(checker),
        ], check=True)
        startup = subprocess.run([str(checker), str(app.parents[2]), str(fixture)], capture_output=True, text=True, timeout=60)
        if startup.returncode != 0:
            raise RuntimeError(startup.stderr.strip() or "Normal app startup check failed")
        (output / "startup-report.json").write_text(startup.stdout)
        print(startup.stdout)
    with (output / "app.log").open("w") as log:
        arguments = ["--smoke-test", str(fixture), "--report", str(report)]
        if args.desktop:
            arguments.append("--smoke-desktop")
        command = [str(app)] + arguments
        if args.foreground:
            # AppKit activation assertions need a normal foreground LaunchServices launch.
            foreground_log = output / "app-foreground.log"
            command = ["/usr/bin/open", "-W", "-n", "--stdout", str(foreground_log),
                       "--stderr", str(foreground_log), str(app.parents[2]), "--args"] + arguments
        result = subprocess.run(command, stdout=log, stderr=log, timeout=120)
    if not report.exists():
        raise RuntimeError(f"App exited {result.returncode} without a report; see {output / 'app.log'}")
    data = json.loads(report.read_text())
    after = {str(p.relative_to(fixture)): (p.lstat().st_size, p.lstat().st_mtime_ns, os.readlink(p) if p.is_symlink() else None) for p in fixture.rglob("*")}
    preserved = before == after and all((fixture / f"file-{i}.txt").read_text() == f"Native fixture {i}\n" for i in range(10_000))
    preserved = preserved and (fixture / "Folder 2" / "child.txt").read_text() == "preserve child\n" and (fixture / ".hidden-fixture").read_text() == "preserve hidden\n"
    data["fixturePreserved"] = preserved
    data["passed"] = data["passed"] and result.returncode == 0 and preserved
    report.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps(data, indent=2, ensure_ascii=False))
    if not data["passed"]:
        sys.exit(1)
print(f"Screenshots and report: {output}")
