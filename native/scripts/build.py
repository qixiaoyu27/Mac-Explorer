#!/usr/bin/env python3
"""Build a separate, ad-hoc-signed development app; never install it."""
import argparse
import pathlib
import platform
import plistlib
import shutil
import subprocess
import sys

parser = argparse.ArgumentParser()
parser.add_argument("--validation", action="store_true", help="Build a separate bundle without replacing the running prototype")
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parents[1]
subprocess.run(["swift", "build", "--package-path", str(root), "-c", "release"] + (["-Xswiftc", "-DEXPLORER_DELETION_TESTS"] if args.validation else []), check=True)
bin_dir = pathlib.Path(subprocess.check_output(
    ["swift", "build", "--package-path", str(root), "-c", "release", "--show-bin-path"], text=True
).strip())
output_directory = root / "output" / "validation" if args.validation else root / "output"
app = output_directory / "Mac Explorer.app"
contents = app / "Contents"
binary_path = str(contents / "MacOS" / "MacExplorerNative")
processes = subprocess.run(["/bin/ps", "-axo", "command="], capture_output=True, text=True, check=True).stdout.splitlines()
if any(command.strip() == binary_path or command.strip().startswith(binary_path + " ") for command in processes):
    raise SystemExit("Close this application before rebuilding it, or use --validation for a separate bundle.")
(contents / "MacOS").mkdir(parents=True, exist_ok=True)
(contents / "Resources").mkdir(exist_ok=True)
subprocess.run([sys.executable, str(root / "scripts" / "make-icon.py"), "--output", str(contents / "Resources" / "AppIcon.icns")], check=True)
shutil.copytree(root / "Resources" / "locales", contents / "Resources" / "locales", dirs_exist_ok=True)
for script in ["install-native.sh", "update-native.sh"]:
    shutil.copy2(root / "scripts" / script, contents / "Resources" / script)
helpers = contents / "Helpers"
helpers.mkdir(exist_ok=True)
archive_helper = helpers / "archive-reader"
subprocess.run(["xcrun", "clang", "-target", f"{platform.machine()}-apple-macos13.0", "-O2", "-Wall", "-Wextra", str(root / "Helpers" / "ArchiveReader.c"), "-larchive.2", "-liconv", "-o", str(archive_helper)], check=True)
subprocess.run(["codesign", "--force", "--sign", "-", str(archive_helper)], check=True)

shutil.copy2(root / "Vendor" / "libsmb2" / "LICENCE-LGPL-2.1.txt", contents / "Resources" / "libsmb2-LICENSE.txt")
shutil.copy2(root / "Vendor" / "libsmb2" / "COPYING", contents / "Resources" / "libsmb2-COPYING.txt")
shutil.copy2(root / "Vendor" / "libsmb2" / "README.mac-explorer.md", contents / "Resources" / "libsmb2-SOURCE.txt")
shutil.copy2(root / "ICON-LICENSE.txt", contents / "Resources" / "ICON-LICENSE.txt")
shutil.copytree(root.parent / "electron" / "templates", contents / "Resources" / "templates", dirs_exist_ok=True)
shutil.copy2(bin_dir / "MacExplorerNative", contents / "MacOS" / "MacExplorerNative")
icon_source = root.parent / "electron" / "native" / "FileIcon.swift"
icon_binary = contents / "Resources" / "file-icon"
if not icon_binary.exists() or icon_binary.stat().st_mtime < icon_source.stat().st_mtime:
    subprocess.run(["xcrun", "swiftc", "-O", "-target", f"{platform.machine()}-apple-macos13.0", str(icon_source), "-o", str(icon_binary)], check=True)
subprocess.run(["codesign", "--force", "--sign", "-", str(icon_binary)], check=True)
info = {
    "CFBundleExecutable": "MacExplorerNative",
    "CFBundleIdentifier": "local.macexplorer.native-validation" if args.validation else "local.macexplorer.native-prototype",
    "CFBundleName": "Mac Explorer",
    "CFBundleDisplayName": "Mac Explorer",
    "CFBundlePackageType": "APPL",
    "CFBundleIconFile": "AppIcon.icns",
    "CFBundleShortVersionString": (root / "VERSION").read_text().strip(),
    "CFBundleVersion": "1",
    "LSMinimumSystemVersion": "13.0",
    "NSHighResolutionCapable": True,
    "NSPrincipalClass": "NSApplication",
    "CFBundleDocumentTypes": [{
        "CFBundleTypeName": "Files and Folders",
        "CFBundleTypeRole": "Viewer",
        "LSHandlerRank": "Alternate",
        "LSItemContentTypes": ["public.data", "public.folder", "public.volume", "public.text", "public.image", "public.audio", "public.movie", "public.archive", "com.adobe.pdf", "com.apple.package", "com.microsoft.windows-executable"],
    }],
    "NSLocalNetworkUsageDescription": "查找附近设备并连接局域网共享电脑和文件服务器。",
    "NSBonjourServices": ["_smb._tcp"],
    "NSDesktopFolderUsageDescription": "浏览桌面中的文件。",
    "NSDocumentsFolderUsageDescription": "浏览文稿中的文件。",
    "NSDownloadsFolderUsageDescription": "浏览下载中的文件。",
}
with (contents / "Info.plist").open("wb") as output:
    plistlib.dump(info, output)
subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
print(app)
