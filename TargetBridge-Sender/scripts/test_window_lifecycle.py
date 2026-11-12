#!/usr/bin/env python3
"""Exercise the actual App scene with inert collaborators and isolated URL types.

Needs a macOS graphical login, but controls only its own disposable process.
Does not open TargetBridge, send global input or request capture permissions.
Usage: test_window_lifecycle.py APP_SOURCE NEW_OUTPUT_DIRECTORY
The unchanged scene must fail; the fixed scene must pass all assertions.
"""
import hashlib
import json
import os
import platform
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import time
import uuid

if len(sys.argv) != 3:
    sys.exit("Usage: test_window_lifecycle.py APP_SOURCE NEW_OUTPUT_DIRECTORY")
source, out = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
out.mkdir(mode=0o700)
scheme = 'tb-window-fixture-' + uuid.uuid4().hex
app = out / 'WindowFixture.app'
contents = app / 'Contents'
(contents / 'MacOS').mkdir(parents=True)
fixture = Path(__file__).with_name('window_lifecycle_fixture.swift')
copied = out / 'App.swift'
copied.write_bytes(source.read_bytes())
plist = {'CFBundleIdentifier': 'org.targetbridge.tests.' + scheme,
         'CFBundleExecutable': 'WindowFixture', 'CFBundleName': 'WindowFixture',
         'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
         'LSUIElement': True, 'LSMinimumSystemVersion': '14.0',
         'CFBundleURLTypes': [{'CFBundleURLSchemes': [scheme]}]}
(contents / 'Info.plist').write_bytes(plistlib.dumps(plist))
with (out / 'build.log').open('w') as log:
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library',
                    '-target', platform.machine() + '-apple-macosx14.0', '-module-cache-path', str(out/'cache'),
                    str(copied), str(fixture), '-o', str(contents/'MacOS/WindowFixture')],
                   stdout=log, stderr=log, check=True)
subprocess.run(['codesign', '-s', '-', str(app)], check=True, capture_output=True)
pid = None
command_id = 0
urls = []
snapshots = []
runtime = tempfile.TemporaryDirectory(prefix='tb-window-fixture-')
state_root = Path(runtime.name)


def read_state():
    try:
        return json.loads((state_root/'state.json').read_text())
    except (OSError, ValueError):
        return None


def wait_for(predicate, label):
    deadline = time.monotonic() + 12
    while time.monotonic() < deadline:
        state = read_state()
        if state and predicate(state):
            snapshots.append({'label': label, **state})
            (out/'snapshots.json').write_text(json.dumps(snapshots, indent=2))
            return state
        time.sleep(0.1)
    raise AssertionError(f'{label}: timed out; last state={state}')


def command(action):
    global command_id
    command_id += 1
    temp = state_root/'command.tmp'
    temp.write_text(json.dumps({'id': command_id, 'action': action}))
    temp.replace(state_root/'command.json')
    return wait_for(lambda s: s['command'] == command_id, action)


def send(count, label, batched=False):
    new = [f'{scheme}://probe?sequence={len(urls)+i}' for i in range(count)]
    urls.extend(new)
    groups = [new] if batched else [[url] for url in new]
    for group in groups:
        subprocess.run(['/usr/bin/open', '-g', '-a', str(app), *group], check=True)
        if not batched:
            wait_for(lambda s: group[0] in s['receivedURLs'], 'URL delivered')
    state = wait_for(lambda s: len(s['receivedURLs']) >= len(urls), label)
    assert state['receivedURLs'] == urls, 'URL lost, duplicated or reordered'
    assert state['mainCount'] == 1, f"{label}: expected one window, got {state['mainCount']}"
    assert state['pid'] == pid, 'Unexpected second process'
    assert state['newWindowCommandCount'] == 0, 'New Window command still exposed'
    return state


try:
    subprocess.run(['/usr/bin/open', '-F', '-g', '-a', str(app), '--args',
                    '--fixture-state', str(state_root)], check=True)
    state = wait_for(lambda s: s['mainCount'] == 1, 'initial window')
    pid = state['pid']
    send(12, 'repeated control requests')
    send(12, 'batched control requests', batched=True)
    command('hide')
    wait_for(lambda s: s['visibleMainCount'] == 0, 'panel hidden')
    send(3, 'hidden panel')
    command('minimize')
    wait_for(lambda s: s['minimizedMainCount'] == 1, 'panel minimized')
    send(3, 'minimized panel')
    command('settings')
    wait_for(lambda s: any(w['title'] == 'Fixture settings' for w in s['windows']), 'settings open')
    send(3, 'settings do not steal control requests')
    command('close-settings')
    command('close')
    wait_for(lambda s: s['mainCount'] == 0 and s['mainCloseNotifications'] == 1,
             'closed main panel, process alive')
    os.kill(pid, 0)
    send(1, 'reopen through control URL')
    wait_for(lambda s: s['visibleMainCount'] == 1, 'reopened panel visible')
    send(12, 'repeated requests after reopen')
    for _ in range(5):
        subprocess.run(['/usr/bin/open', '-g', '-a', str(app)], check=True)
    time.sleep(0.4)
    state = read_state()
    assert state['mainCount'] == 1 and state['pid'] == pid, 'Normal reopen duplicated the app or window'
    snapshots.append({'label': 'repeated normal reopen', **state})
    (out/'snapshots.json').write_text(json.dumps(snapshots, indent=2))
    result = {'status': 'PASS', 'url_count': len(urls), 'pid': pid,
              'source_sha256': hashlib.sha256(copied.read_bytes()).hexdigest(),
              'scope': 'Actual App scene; service and control actions inert; no live capture or streaming'}
    (out/'result.json').write_text(json.dumps(result, indent=2))
    print(json.dumps(result))
finally:
    state = read_state()
    if state:
        (out/'state.json').write_text(json.dumps(state, indent=2))
        pid = state['pid']
        command_id += 1
        (state_root/'command.json').write_text(json.dumps({'id': command_id, 'action': 'quit'}))
        for _ in range(30):
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.1)
        else:
            # Exact owned fixture only; never a TargetBridge process.
            subprocess.run(['/bin/kill', '-TERM', str(pid)], check=True)
    runtime.cleanup()
