#!/usr/bin/env python3
"""Exercise signed Native installation only in a disposable directory."""
import hashlib
import os
import pathlib
import plistlib
import pty
import shutil
import subprocess
import tempfile
import zipfile

root = pathlib.Path(__file__).resolve().parents[1]
installer = root / 'scripts/install-native.sh'
checks = 0

def run(command, **kwargs):
    result = subprocess.run(command, capture_output=True, text=True, **kwargs)
    if result.returncode:
        raise AssertionError(result.stdout + result.stderr)
    return result

with tempfile.TemporaryDirectory(prefix='explorer-native-install-checks-') as temporary:
    folder = pathlib.Path(temporary).resolve()
    install = folder / 'applications with spaces'
    install.mkdir()
    electron = install / 'Mac Explorer.app'
    electron.mkdir()
    (electron / 'untouched').write_text('existing Electron user application')
    original = (electron / 'untouched').read_bytes()
    fixture_binary = folder / 'fixture-binary'
    run(['/usr/bin/clang', '-arch', 'arm64', '-x', 'c', '-', '-o', str(fixture_binary)], input='int main(void) { return 0; }\n')

    def make_app(version, identity='local.macexplorer.native-prototype'):
        directory = folder / ('source-' + version + '-' + str(len(list(folder.iterdir()))))
        app = directory / 'Mac Explorer.app'
        (app / 'Contents/MacOS').mkdir(parents=True)
        (app / 'Contents/Resources').mkdir()
        executable = 'Mac Explorer' if identity == 'local.macexplorer.desktop' else 'MacExplorerNative'
        shutil.copyfile(fixture_binary, app / 'Contents/MacOS' / executable)
        (app / 'Contents/MacOS' / executable).chmod(0o755)
        with (app / 'Contents/Info.plist').open('wb') as handle:
            plistlib.dump({'CFBundleIdentifier': identity, 'CFBundleExecutable':executable, 'CFBundleShortVersionString':version, 'CFBundlePackageType':'APPL'}, handle)
        run(['/usr/bin/codesign', '--force', '--sign', '-', str(app)])
        return app

    def prepared(version, identity='local.macexplorer.native-prototype', unsafe=False):
        source = make_app(version, identity)
        directory = source.parent / 'prepared'
        directory.mkdir()
        archive = directory / f'Mac-Explorer-Native-{version}-mac-arm64.zip'
        if unsafe:
            with zipfile.ZipFile(archive, 'w') as handle:
                handle.writestr('../escape.txt', 'must not escape')
        else:
            run(['/usr/bin/ditto', '-c', '-k', '--norsrc', '--keepParent', str(source), str(archive)])
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        (directory / 'SHA256SUMS-native.txt').write_text(f'{digest}  {archive.name}\n')
        return directory

    def install_package(directory, success=True):
        global checks
        env = dict(os.environ, MAC_EXPLORER_NATIVE_PREPARED=str(directory), MAC_EXPLORER_NATIVE_INSTALL_DIR=str(install), MAC_EXPLORER_NATIVE_NO_OPEN='1')
        result = subprocess.run(['/bin/bash', str(installer)], env=env, capture_output=True, text=True)
        assert (result.returncode == 0) == success, result.stdout + result.stderr
        assert (electron / 'untouched').read_bytes() == original
        checks += 1

    first = prepared('1.0.0')
    install_package(first, success=False)
    legacy = folder / 'legacy Electron'
    legacy.mkdir()
    electron = electron.rename(legacy / electron.name)
    install_package(first)
    destination = install / 'Mac Explorer.app'
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(destination)])
    before = (destination / 'Contents/Info.plist').read_bytes()
    install_package(prepared('0.9.0'))
    assert (destination / 'Contents/Info.plist').read_bytes() == before
    install_package(prepared('1.0.0'))
    assert (destination / 'Contents/Info.plist').read_bytes() == before

    # Exercise the README command's terminal consent and same-version repair.
    interactive_command = ['/bin/bash', '-c', installer.read_text(), '--', '--install-and-open']
    interactive_env = dict(os.environ, MAC_EXPLORER_NATIVE_PREPARED=str(first), MAC_EXPLORER_NATIVE_INSTALL_DIR=str(install), MAC_EXPLORER_NATIVE_NO_OPEN='1')

    def confirm_install(answer, env=interactive_env):
        master, terminal = pty.openpty()
        try:
            os.write(master, answer)
            return subprocess.run(interactive_command, stdin=terminal, env=env, capture_output=True, text=True, timeout=30)
        finally:
            os.close(terminal)
            os.close(master)

    quarantine = '0081;00000000;InstallerTest;'
    run(['/usr/bin/xattr', '-w', 'com.apple.quarantine', quarantine, str(destination)])
    run(['/usr/bin/xattr', '-w', 'com.apple.quarantine', quarantine, str(electron)])

    def assert_quarantined(path):
        assert run(['/usr/bin/xattr', '-p', 'com.apple.quarantine', str(path)]).stdout.strip() == quarantine

    rejected = subprocess.run(interactive_command, input='y\n', env=interactive_env, capture_output=True, text=True)
    assert rejected.returncode != 0
    canceled = confirm_install(b'\n')
    assert canceled.returncode == 0 and 'Installation canceled' in canceled.stdout
    assert_quarantined(destination)
    corrupt = prepared('1.0.0')
    (corrupt / 'SHA256SUMS-native.txt').write_text('0' * 64 + '  Mac-Explorer-Native-1.0.0-mac-arm64.zip\n')
    failed = confirm_install(b'y\n', dict(interactive_env, MAC_EXPLORER_NATIVE_PREPARED=str(corrupt)))
    assert failed.returncode != 0 and '更新包校验失败' in failed.stderr
    assert_quarantined(destination)
    installed = confirm_install(b'y\n')
    assert installed.returncode == 0, installed.stdout + installed.stderr
    assert '已安装原生版本 v1.0.0' in installed.stdout
    assert installed.stderr.count('[y/N]') == 1
    assert 'com.apple.quarantine' not in run(['/usr/bin/xattr', str(destination)]).stdout
    assert_quarantined(electron)
    assert (destination / 'Contents/Info.plist').read_bytes() == before
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(destination)])
    fresh_install = folder / 'fresh interactive install'
    installed = confirm_install(b'y\n', dict(interactive_env, MAC_EXPLORER_NATIVE_INSTALL_DIR=str(fresh_install)))
    assert installed.returncode == 0, installed.stdout + installed.stderr
    assert (fresh_install / 'Mac Explorer.app/Contents/Info.plist').read_bytes() == before
    checks += 5

    install_package(prepared('1.0.1'))
    before = (destination / 'Contents/Info.plist').read_bytes()
    assert plistlib.loads(before)['CFBundleShortVersionString'] == '1.0.1'
    install_package(prepared('1.0.2', identity='local.macexplorer.desktop'), success=False)
    assert (destination / 'Contents/Info.plist').read_bytes() == before
    invalid_checksum = prepared('1.0.2')
    (invalid_checksum / 'SHA256SUMS-native.txt').write_text('0' * 64 + '  Mac-Explorer-Native-1.0.2-mac-arm64.zip\n')
    install_package(invalid_checksum, success=False)
    install_package(prepared('1.0.2', unsafe=True), success=False)
    assert not (folder / 'escape.txt').exists()
    assert (destination / 'Contents/Info.plist').read_bytes() == before
    held = install / 'held.app'
    destination.rename(held)
    destination.symlink_to(held, target_is_directory=True)
    install_package(first, success=False)
    assert destination.is_symlink()
    destination.unlink()
    held.rename(destination)

    # Package the fixture through the actual release entrypoint; no source build or publication.
    app = make_app('1.2.3')
    artifacts = folder / 'artifacts'
    run(['python3', str(root / 'scripts/package-release.py'), '--app', str(app), '--output', str(artifacts)])
    entries = (artifacts / 'SHA256SUMS-native.txt').read_text().splitlines()
    assert len(entries) == 2
    for line in entries:
        digest, name = line.split('  ')
        assert hashlib.sha256((artifacts / name).read_bytes()).hexdigest() == digest
    install_package(artifacts)
    assert plistlib.loads((destination / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString'] == '1.2.3'
    # The real external update launcher waits for a fixture process, then upgrades only the temporary app.
    next_package = prepared('1.2.4')
    for name in ['install-native.sh', 'update-native.sh']:
        shutil.copy2(root / 'scripts' / name, next_package / name)
    sleeper = subprocess.Popen(['/bin/sleep', '0.1'])
    sleeper.wait()
    result_file = folder / 'last-install-result'
    env = dict(os.environ, MAC_EXPLORER_NATIVE_PREPARED=str(next_package), MAC_EXPLORER_NATIVE_INSTALL_DIR=str(install), MAC_EXPLORER_NATIVE_NO_OPEN='1', MAC_EXPLORER_NATIVE_WAIT_PID=str(sleeper.pid), MAC_EXPLORER_NATIVE_RESULT=str(result_file))
    run(['/bin/bash', str(next_package / 'update-native.sh')], env=env)
    assert result_file.read_text().strip() == '0'
    assert plistlib.loads((destination / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString'] == '1.2.4'
    assert (electron / 'untouched').read_bytes() == original
    checks += 2
    # Upgrade an authentic legacy identity at the same version, preserving its data.
    shutil.rmtree(destination)
    legacy_source = make_app('1.1.0', identity='local.macexplorer.desktop')
    shutil.copytree(legacy_source, destination)
    preferences = folder / 'Electron preferences.json'
    preferences.write_text('{"pins":["/example"],"theme":"dark"}')
    saved_preferences = preferences.read_bytes()
    same_version = prepared('1.1.0')
    # A failed final rename must restore the legacy bundle.
    commands = folder / 'commands'; commands.mkdir()
    fail_move = commands / 'mv'
    fail_move.write_text('#!/bin/bash\nif [[ "$1" == */.mac-explorer-native.*/"Mac Explorer.app" ]]; then exit 1; fi\nexec /bin/mv "$@"\n')
    fail_move.chmod(0o755)
    failed_env = dict(os.environ, PATH=str(commands) + ':' + os.environ['PATH'], MAC_EXPLORER_NATIVE_PREPARED=str(same_version), MAC_EXPLORER_NATIVE_INSTALL_DIR=str(install), MAC_EXPLORER_NATIVE_NO_OPEN='1')
    result = subprocess.run(['/bin/bash', str(installer)], env=failed_env, capture_output=True, text=True)
    assert result.returncode != 0
    assert plistlib.loads((destination / 'Contents/Info.plist').read_bytes())['CFBundleIdentifier'] == 'local.macexplorer.desktop'
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(destination)])
    install_package(same_version)
    assert plistlib.loads((destination / 'Contents/Info.plist').read_bytes())['CFBundleIdentifier'] == 'local.macexplorer.native-prototype'
    assert preferences.read_bytes() == saved_preferences
    # Existing public environment variable names still work.
    compat_env = dict(os.environ, MAC_EXPLORER_PREPARED_UPDATE=str(prepared('1.1.1')), MAC_EXPLORER_INSTALL_DIR=str(install), MAC_EXPLORER_NO_OPEN='1', MAC_EXPLORER_ALLOW_UNNOTARIZED='1')
    run(['/bin/bash', str(installer)], env=compat_env)
    assert plistlib.loads((destination / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString'] == '1.1.1'
    checks += 3
    print(f'Native package/install checks passed: {checks}; signed fixture bundles, temporary destinations only.')
