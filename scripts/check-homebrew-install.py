#!/usr/bin/env python3
"""Exercise the installer with isolated Homebrew/process fixtures, never real installs."""
import json
import os
import pathlib
import plistlib
import subprocess
import sys
import tempfile

source = pathlib.Path(__file__).with_name('install-homebrew.sh').read_text()
mock = r'''
import json, os, pathlib, plistlib, shutil, sys
state_path = pathlib.Path(os.environ['ME_TEST_STATE'])
state = json.loads(state_path.read_text())
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
app = pathlib.Path(state['app'])
def save(): state_path.write_text(json.dumps(state))
def make_app():
    (app / 'Contents/MacOS').mkdir(parents=True, exist_ok=True)
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'local.macexplorer.native-prototype',
        'CFBundleExecutable': 'MacExplorerNative',
        'CFBundleShortVersionString': state['latest'],
    }))
    executable = app / 'Contents/MacOS/MacExplorerNative'
    executable.write_text('fixture'); executable.chmod(0o755)
if name == 'defaults':
    print('(\n    "' + state.get('language', 'zh-Hans-CN') + '"\n)')
elif name == 'uname': print('Darwin')
elif name == 'sysctl': print('1')
elif name == 'sw_vers': print('15.0')
elif name == 'codesign': sys.exit(1 if state.get('bad_signature') else 0)
elif name == 'ps':
    if state.get('running'): print(str(app / 'Contents/MacOS/MacExplorerNative'))
elif name == 'sleep': pass
elif name == 'osascript':
    state['quit_requested'] = True
    if not state.get('refuse_quit'): state['running'] = False
    save()
elif name == 'curl':
    assert 'https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh' in args
    state['bootstrapped'] = True; save()
    output = pathlib.Path(args[args.index('-o') + 1])
    if state.get('bootstrap_fail'):
        output.write_text('#!/bin/bash\nexit 9\n')
    else:
        output.write_text('#!/bin/bash\ncp "$ME_TEST_BREW_SOURCE" "$ME_TEST_FALLBACK"\nchmod +x "$ME_TEST_FALLBACK"\n')
elif name == 'brew':
    state.setdefault('commands', []).append(args); save()
    action = args[0]
    if state.get('fail') == action:
        print('fixture Homebrew failure', file=sys.stderr); sys.exit(7)
    if action == 'command':
        assert args == ['command', 'trust']
        if state.get('old_brew'): sys.exit(1)
        print('/opt/homebrew/Library/Homebrew/cmd/trust.rb')
    elif action == 'trust':
        assert args == ['trust', '--cask', 'qixiaoyu27/tap/mac-explorer']
        assert ['tap', 'qixiaoyu27/tap'] in state['commands']
        state['trusted'] = True; save()
    elif action == 'info':
        if not state.get('old_brew') and not state.get('trusted'):
            print('Refusing to load the untrusted cask', file=sys.stderr); sys.exit(1)
        print(json.dumps({'casks': [{
            'version': state['latest'], 'installed': state.get('registered'),
            'sha256': state.get('checksum', 'a' * 64),
            'pinned': state.get('pinned', False),
            'artifacts': [{'app': ['Mac Explorer.app']} if state.get('omit_target') else
                          {'app': ['Mac Explorer.app'], 'target': state.get('target', str(app))}],
        }]}))
    elif action in ('install', 'reinstall', 'upgrade'):
        assert '--no-ask' in args
        assert '--force' not in args and '--zap' not in args
        if '--adopt' not in args and not state.get('wrong_result'): make_app()
        state['registered'] = state['latest']; save()
        print('Homebrew caveat 🌟 Star (must not duplicate the final invitation)')
    elif action == 'fetch':
        assert args == ['fetch', '--cask', 'qixiaoyu27/tap/mac-explorer']
        if state.get('change_on_fetch'):
            info = app / 'Contents/Info.plist'
            changed = plistlib.loads(info.read_bytes()); changed['CFBundleIdentifier'] = 'example.changed'
            info.write_bytes(plistlib.dumps(changed))
    elif action not in ('update', 'tap'): raise AssertionError(args)
else: raise AssertionError(name)
'''

checks = 0
with tempfile.TemporaryDirectory(prefix='me-brew-checks-') as temporary:
    root = pathlib.Path(temporary)

    def check(name, *, version=None, registered=None, language='zh-Hans-CN',
              actions=(), success=True, expected='', bootstrap=False, fallback=False,
              identity='local.macexplorer.native-prototype', symlink=False, legacy=False,
              **extra):
        global checks
        folder = root / name; folder.mkdir()
        commands = folder / 'bin'; commands.mkdir()
        homebrew = folder / 'homebrew/bin'; homebrew.mkdir(parents=True)
        default_app = folder / 'Applications/Mac Explorer.app'
        personal_app = folder / 'Personal Applications/Mac Explorer.app'
        app = personal_app if legacy else default_app
        state = dict(app=str(app), target=str(default_app), latest='1.2.3',
                     registered=registered, language=language, **extra)
        if version:
            (app / 'Contents/MacOS').mkdir(parents=True)
            executable = 'Mac Explorer' if identity == 'local.macexplorer.desktop' else 'MacExplorerNative'
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
                'CFBundleIdentifier': identity, 'CFBundleExecutable': executable,
                'CFBundleShortVersionString': version,
            }))
            binary = app / 'Contents/MacOS' / executable
            binary.write_text('existing app'); binary.chmod(0o755)
        if symlink:
            held = app.with_name('held.app'); app.rename(held); app.symlink_to(held)
        before = (app / 'Contents/Info.plist').read_bytes() if version else None
        preferences = folder / 'preferences'; preferences.write_text('preserved user preferences')
        state_path = folder / 'state.json'; state_path.write_text(json.dumps(state))
        mock_path = folder / 'mock.py'
        mock_path.write_text(f'#!{sys.executable}\n' + mock); mock_path.chmod(0o755)
        for tool in ['defaults', 'uname', 'sysctl', 'sw_vers', 'codesign', 'ps', 'osascript', 'sleep', 'curl']:
            (commands / tool).symlink_to(mock_path)
        if not bootstrap:
            (homebrew / 'brew' if fallback else commands / 'brew').symlink_to(mock_path)
        script = source.replace('/opt/homebrew/bin/brew', str(homebrew / 'brew'))
        script = script.replace('/Applications/Mac Explorer.app', str(default_app))
        script = script.replace('$HOME' + str(default_app), str(personal_app))
        for tool, original in [('codesign', '/usr/bin/codesign'), ('ps', '/bin/ps'), ('osascript', '/usr/bin/osascript')]:
            script = script.replace(original, str(commands / tool))
        installer = folder / 'install.sh'; installer.write_text(script)
        env = dict(os.environ, PATH=f'{commands}:/usr/bin:/bin:/usr/sbin:/sbin',
                   ME_TEST_STATE=str(state_path), ME_TEST_BREW_SOURCE=str(mock_path),
                   ME_TEST_FALLBACK=str(homebrew / 'brew'))
        result = subprocess.run(['/bin/bash', str(installer)], env=env, capture_output=True, text=True, timeout=20)
        output = result.stdout + result.stderr
        assert (result.returncode == 0) == success, (name, output)
        assert expected in output, (name, output)
        assert output.count('🌟 Star') == 1, (name, output)
        assert 'https://github.com/qixiaoyu27/Mac-Explorer' in output
        assert '\x1b[' not in output
        final = json.loads(state_path.read_text())
        mutations = [args[0] + ('-adopt' if '--adopt' in args else '') for args in final.get('commands', [])
                     if args[0] in ('install', 'reinstall', 'upgrade')]
        assert mutations == list(actions), (name, mutations, output)
        assert preferences.read_text() == 'preserved user preferences'
        if not success or (version and all(action == 'install-adopt' for action in actions)):
            if before and not extra.get('change_on_fetch'):
                assert (app / 'Contents/Info.plist').read_bytes() == before, name
        if bootstrap: assert final.get('bootstrapped'), name
        if extra.get('running') and actions and success: assert final.get('quit_requested'), name
        checks += 1

    check('fresh', actions=['install'], expected='已安装 Mac Explorer 1.2.3')
    check('old-brew', old_brew=True, actions=['install'], expected='已安装')
    check('trust-failure', fail='trust', success=False, expected='fixture Homebrew failure')
    check('older-metadata', omit_target=True, actions=['install'], expected='已安装')
    check('bootstrap', bootstrap=True, actions=['install'], expected='已安装')
    check('bootstrap-failure', bootstrap=True, bootstrap_fail=True, success=False, expected='未完成')
    check('brew-outside-path', fallback=True, actions=['install'], expected='已安装')
    check('latest', version='1.2.3', registered='1.2.3', expected='已是最新版')
    check('adopt', version='1.2.3', actions=['install-adopt'], expected='已是最新版')
    check('adopt-old', version='0.1.9', actions=['install-adopt', 'reinstall'], expected='0.1.9 → 1.2.3')
    check('upgrade', version='1.2.2', registered='1.2.2', actions=['upgrade'], expected='1.2.2 → 1.2.3')
    check('old-app-current-receipt', version='1.2.2', registered='1.2.3', actions=['reinstall'], expected='已更新')
    check('self-updated', version='1.2.3', registered='1.2.2', expected='已是最新版')
    check('newer', version='1.10.0', registered='1.2.3', expected='保留较新版本')
    check('adopt-newer', version='1.10.0', actions=['install-adopt'], expected='保留较新版本')
    check('missing-app', registered='1.2.3', actions=['reinstall'], expected='已安装')
    check('legacy', version='1.2.3', identity='local.macexplorer.desktop', actions=['install-adopt', 'reinstall'], expected='已更新')
    check('personal-app', legacy=True, version='1.2.2', actions=['install-adopt', 'reinstall'], expected='已更新')
    check('running', version='1.2.2', registered='1.2.2', running=True, actions=['upgrade'], expected='已更新')
    check('refuses-quit', version='1.2.2', registered='1.2.2', running=True, refuse_quit=True, success=False, expected='尚未退出')
    check('pinned', version='1.2.2', registered='1.2.2', pinned=True, success=False, expected='固定版本')
    check('symlink', version='1.2.3', symlink=True, success=False, expected='路径无效')
    check('unrelated-app', version='1.2.3', identity='example.unrelated', success=False, expected='不是 Mac Explorer')
    check('bad-signature', version='1.2.3', bad_signature=True, success=False, expected='未完成')
    check('changed-app', version='1.2.2', registered='1.2.2', change_on_fetch=True, success=False, expected='不是 Mac Explorer')
    check('update-failure', fail='update', success=False, expected='未完成')
    check('missing-checksum', checksum='no_check', success=False, expected='安装信息无效')
    check('fetch-failure', version='1.2.2', registered='1.2.2', fail='fetch', success=False, expected='未完成')
    check('upgrade-failure', version='1.2.2', registered='1.2.2', fail='upgrade', actions=['upgrade'], success=False, expected='未完成')
    check('adopt-failure', version='1.2.3', fail='install', actions=['install-adopt'], success=False, expected='未完成')
    check('wrong-installed-version', version='1.2.2', registered='1.2.2', wrong_result=True, actions=['upgrade'], success=False, expected='版本与目标版本不符')
    check('traditional', version='1.2.3', registered='1.2.3', language='zh-Hant-TW', expected='喜歡 Mac Explorer')
    check('english', version='1.2.3', registered='1.2.3', language='en-US', expected='is up to date')
    check('fallback-language', version='1.2.3', registered='1.2.3', language='ja-JP', expected='is up to date')

print(f'Homebrew installer checks passed: {checks}; isolated command fixtures, no real installations.')
