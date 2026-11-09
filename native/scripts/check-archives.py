#!/usr/bin/env python3
"""Compile the shipped libarchive helper and exercise only disposable fixtures."""
import pathlib
import platform
import stat
import subprocess
import tarfile
import tempfile
import warnings
import zipfile

root = pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="explorer-native-archives-") as temporary:
    fixtures = pathlib.Path(temporary)
    helper = fixtures / "archive-reader"
    executable = fixtures / "ArchiveChecks"
    subprocess.run(["xcrun", "clang", "-target", f"{platform.machine()}-apple-macos13.0", "-O2", "-Wall", "-Wextra", str(root / "Helpers" / "ArchiveReader.c"), "-larchive.2", "-liconv", "-o", str(helper)], check=True)
    class EncodedName(zipfile.ZipInfo):
        def __init__(self, name, encoding, flags=0):
            super().__init__(name)
            self.encoding, self.flags = encoding, flags
        def _encodeFilenameFlags(self):
            return self.filename.encode(self.encoding), self.flags
    with zipfile.ZipFile(fixtures / "encodings.zip", "w") as archive:
        archive.writestr("资料/标记.txt", "flagged UTF-8")
        archive.writestr(EncodedName("资料/未标记.txt", "utf-8"), "unflagged UTF-8")
        archive.writestr("UTF8/élève.txt", "accented UTF-8")
        archive.writestr(EncodedName("UTF8/naïve.txt", "utf-8"), "unflagged accented UTF-8")
        archive.writestr(EncodedName("données/café.txt", "cp437"), "CP437")
    for filename, member in {"legacy-traversal.zip": "../café.txt", "legacy-absolute.zip": "/tmp/café.txt", "legacy-backslash.zip": r"..\café.txt", "legacy-colon.zip": "disk:café.txt"}.items():
        with zipfile.ZipFile(fixtures / filename, "w") as archive:
            archive.writestr(EncodedName(member, "cp437"), "unsafe")
    with zipfile.ZipFile(fixtures / "legacy-duplicate.zip", "w") as archive:
        archive.writestr(EncodedName("café.txt", "cp437"), "first")
        archive.writestr("cafe\u0301.txt", "second")
    with zipfile.ZipFile(fixtures / "unicode-duplicate.zip", "w") as archive:
        archive.writestr("café.txt", "first")
        archive.writestr("cafe\u0301.txt", "second")
    with zipfile.ZipFile(fixtures / "invalid-utf8.zip", "w") as archive:
        archive.writestr(EncodedName("café.txt", "cp437", 0x800), "invalid UTF-8 flag")
    encrypted_source = fixtures / "password.txt"
    encrypted_source.write_text("encrypted fixture")
    subprocess.run(["/usr/bin/zip", "-q", "-j", "-P", "fixture-only", str(fixtures / "encrypted.zip"), str(encrypted_source)], check=True)
    for filename, member in {"traversal.zip": "../escape", "absolute.zip": "/tmp/escape", "backslash.zip": r"..\escape", "colon.zip": "disk:escape"}.items():
        with zipfile.ZipFile(fixtures / filename, "w") as archive:
            archive.writestr(member, "unsafe")
    with zipfile.ZipFile(fixtures / "symlink.zip", "w") as archive:
        member = zipfile.ZipInfo("link"); member.create_system = 3
        member.external_attr = (stat.S_IFLNK | 0o777) << 16
        archive.writestr(member, "../escape")
    with zipfile.ZipFile(fixtures / "duplicate.zip", "w") as archive:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            archive.writestr("duplicate.txt", "first")
            archive.writestr("duplicate.txt", "second")
    with zipfile.ZipFile(fixtures / "partial.zip", "w") as archive:
        archive.writestr("keep.txt", "replacement")
        archive.writestr("new.txt", "new")
    with zipfile.ZipFile(fixtures / "too-many.zip", "w") as archive:
        for index in range(10_001): archive.writestr(f"item-{index}", "")
    member = tarfile.TarInfo("large"); member.size = 21 * 1024 ** 3
    (fixtures / "too-large.tar").write_bytes(member.tobuf() + b"\0" * 1024)
    (fixtures / "corrupt.zip").write_bytes(b"invalid archive")
    sources = [root / "Sources" / "ExplorerCore" / name for name in ["FileActions.swift", "VerifiedTransfer.swift", "FileTransferControl.swift", "TransferTelemetry.swift", "ServerSideTransfer.swift", "AppleDoubleCompanion.swift", "NativeCommand.swift", "NativeArchives.swift", "Localization.swift"]]
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-O", "-target", f"{platform.machine()}-apple-macos13.0", *map(str, sources), str(root / "scripts" / "ArchiveChecks.swift"), "-o", str(executable)], check=True)
    import os
    subprocess.run([str(executable), str(fixtures)], env={**os.environ, "MAC_EXPLORER_ARCHIVE_READER": str(helper)}, check=True)
