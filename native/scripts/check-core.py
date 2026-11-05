#!/usr/bin/env python3
"""Run Foundation-only assertions when the selected toolchain lacks XCTest."""
import argparse
import pathlib
import platform
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
names = ["GroupingChecks", "CoreChecks", "ColumnChecks", "NetworkDeletionChecks", "FileActionChecks", "BatchRenameChecks", "MetadataTransferChecks", "ServerSideTransferChecks", "TransferTelemetryChecks", "PropertiesChecks", "WatcherChecks", "QuickAccessChecks", "LatestCoreChecks", "NetworkChecks", "TrashChecks", "SystemChecks", "CloudDriveChecks"]
parser = argparse.ArgumentParser()
def check_name(value):
    if value not in names:
        raise argparse.ArgumentTypeError('Unknown check: ' + value)
    return value
parser.add_argument('checks', nargs='*', type=check_name, metavar='CHECK', help=', '.join(names))
selected = parser.parse_args().checks or names
with tempfile.TemporaryDirectory(prefix="explorer-native-checks-") as temporary:
    sources = sorted((root / "Sources" / "ExplorerCore").glob("*.swift"))
    for name in selected:
        extra = [root / "Sources" / "MacExplorerNative" / "QuickAccessState.swift"] if name in ["QuickAccessChecks", "LatestCoreChecks"] else []
        executable = pathlib.Path(temporary) / name
        subprocess.run([
            "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-O",
            "-target", f"{platform.machine()}-apple-macos13.0",
            *(["-D", "EXPLORER_DELETION_TESTS"] if name == "NetworkDeletionChecks" else []),
            *map(str, sources + extra), str(root / "scripts" / f"{name}.swift"), "-o", str(executable),
        ], check=True)
        subprocess.run([str(executable)] + ([str(root / "Resources" / "locales")] if name == "LatestCoreChecks" else []), check=True)

if "NetworkDeletionChecks" in selected:
    subprocess.run([sys.executable, "-I", str(root / "scripts/check-deletion-api.py")], check=True)
