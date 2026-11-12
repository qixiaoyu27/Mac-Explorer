#!/usr/bin/env python3
"""Exercise desktop windows with disposable files/preferences and no visible overlays."""
import json
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
for target in ["ExplorerCore", "SMBTransport"]:
    subprocess.run(["swift", "build", "--package-path", str(root), "-c", "release", "--target", target], check=True)
build = pathlib.Path(subprocess.check_output([
    "swift", "build", "--package-path", str(root), "-c", "release", "--show-bin-path",
], text=True).strip())
output = root / "output" / "desktop-checks"
output.mkdir(parents=True, exist_ok=True)
report = output / "report.json"
report.unlink(missing_ok=True)
with tempfile.TemporaryDirectory(prefix="native-desktop-checks-") as temporary:
    temporary = pathlib.Path(temporary)
    sources = sorted((root / "Sources" / "MacExplorerNative").glob("*.swift"))
    application = root / "Sources" / "MacExplorerNative" / "Application.swift"
    source = application.read_text()
    assert source.count("@main\n") == 1
    entry = temporary / "Application.swift"
    entry.write_text(source.replace("@main\n", "", 1))
    sources[sources.index(application)] = entry
    executable = output / "desktop-checks"
    objects = [item for target in ["ExplorerCore", "SMBTransport", "CSMB2"] for item in sorted((build / (target + ".build")).rglob("*.o"))]
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
        "-I", str(build / "Modules"),
        "-Xcc", "-fmodule-map-file=" + str(build / "SMBTransport.build/module.modulemap"),
        "-Xcc", "-I" + str(root / "Sources/SMBTransport/include"),
        "-Xcc", "-fmodule-map-file=" + str(root / "Vendor/libsmb2/include/module.modulemap"),
        "-Xcc", "-I" + str(root / "Vendor/libsmb2/include"), *map(str, sources),
        str(root / "scripts" / "DesktopChecks.swift"),
        *map(str, objects),
        "-o", str(executable),
    ], check=True)
    subprocess.run([str(executable), str(root / "Resources" / "locales"), str(output)], check=True, timeout=60)
data = json.loads(report.read_text())
assert data["passed"]
print(f"Desktop: {len(data['checks'])} checks passed; {report}")
