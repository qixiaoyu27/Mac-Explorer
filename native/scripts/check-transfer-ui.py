#!/usr/bin/env python3
"""Exercise transfer dialogs and collection drops without displaying windows."""
import json
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
build_command = ["swift", "build", "--package-path", str(root), "-c", "release"]
# The harness links individual SwiftPM objects from the native build layout.
if "--build-system" in subprocess.check_output(["swift", "build", "--help"], text=True):
    build_command += ["--build-system", "native"]
subprocess.run(build_command, check=True)
build = pathlib.Path(subprocess.check_output(build_command + ["--show-bin-path"], text=True).strip())
output = root / "output" / "transfer-ui-checks"
output.mkdir(parents=True, exist_ok=True)
report = output / "report.json"
report.unlink(missing_ok=True)
with tempfile.TemporaryDirectory(prefix="native-transfer-ui-") as temporary:
    temporary = pathlib.Path(temporary)
    sources = sorted((root / "Sources/MacExplorerNative").glob("*.swift"))
    application = root / "Sources/MacExplorerNative/Application.swift"
    source = application.read_text()
    assert source.count("@main\n") == 1
    entry = temporary / "Application.swift"
    entry.write_text(source.replace("@main\n", "", 1))
    sources[sources.index(application)] = entry
    objects = [item for target in ["ExplorerCore", "SMBTransport", "CSMB2"] for item in sorted((build / (target + ".build")).rglob("*.o"))]
    executable = temporary / "transfer-ui-checks"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-I", str(build / "Modules"),
        "-Xcc", "-fmodule-map-file=" + str(build / "SMBTransport.build/module.modulemap"),
        "-Xcc", "-I" + str(root / "Sources/SMBTransport/include"),
        "-Xcc", "-fmodule-map-file=" + str(root / "Vendor/libsmb2/include/module.modulemap"),
        "-Xcc", "-I" + str(root / "Vendor/libsmb2/include"),
        *map(str, sources), str(root / "scripts/TransferUIChecks.swift"), *map(str, objects), "-o", str(executable),
    ], check=True)
    subprocess.run([str(executable), str(root / "Resources/locales"), str(output)], check=True, timeout=60)
data = json.loads(report.read_text())
assert data["passed"]
print(f"Transfer AppKit: {len(data['checks'])} checks passed; no windows displayed.")
