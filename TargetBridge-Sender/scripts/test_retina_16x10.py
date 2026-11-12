#!/usr/bin/env python3
"""Compile production geometry/profile declarations without opening an app.

Usage: python3 test_retina_16x10.py REPOSITORY OUTPUT [--presets-only]
The preset-only check also compiles on the original source and fails because
the two selectable profiles are absent. Full checks require the new geometry.
"""
import argparse
import json
import subprocess
from pathlib import Path


def declaration(text, marker):
    start = text.index(marker)
    begin = text.index('{', start)
    depth = 0
    for i in range(begin, len(text)):
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
            if not depth:
                return text[start:i + 1]
    raise ValueError('Unterminated declaration: ' + marker)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('repository', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--presets-only', action='store_true')
    args = parser.parse_args()
    sender = args.repository.resolve() / 'TargetBridge-Sender'
    source = sender / 'TBDisplaySender'
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    geometry = (source / 'ReceiverBackedVirtualDisplaySession.swift').read_text()
    swift = 'import Foundation\nimport CoreMedia\nimport ScreenCaptureKit\n'
    swift += declaration(geometry, 'struct TBVirtualDisplayModeSize:') + '\n'
    swift += declaration((source / 'TBDisplaySenderService.swift').read_text(),
                         'enum TBDisplayCapturePreset:') + '\n'
    swift += '''
var failures = 0
@MainActor func check(_ value: Bool, _ message: String) {
    if !value { print("FAIL: \\(message)"); failures += 1 }
}
for (raw, width, height) in [("retina16x10", 3072, 1920),
                              ("retina16x10MoreSpace", 3584, 2240)] {
    if let preset = TBDisplayCapturePreset(rawValue: raw) {
        check(TBDisplayCapturePreset.allCases.contains(preset), "selectable profile")
        check(preset.width == width && preset.height == height, "stream dimensions")
        check(preset.renderMatchedDisplayMode.backingWidth == width &&
              preset.renderMatchedDisplayMode.backingHeight == height, "2x Retina backing")
    } else { check(false, "missing 16:10 profile: \\(raw)") }
}
'''
    if not args.presets_only:
        swift += declaration((sender / 'TBDisplayShared/TBMonitorProtocol.swift').read_text(),
                             'struct TBMonitorDisplayProfile:') + '\n'
        swift += declaration(geometry, 'struct TBVirtualDisplayGeometry {') + '\n'
        swift += '''
let profile = TBMonitorDisplayProfile(receiverName: "fixture", panelWidth: 3072,
    panelHeight: 1920, modeWidth: 1536, modeHeight: 960, refreshRate: 60,
    hiDPI: true, captureWidth: 3072, captureHeight: 1920)
let requested = TBVirtualDisplayModeSize(width: 1792, height: 1120)
let actual = TBVirtualDisplayGeometry(profile: profile, modeOverride: requested,
                                    allow16x10Supersampling: true)
check(actual.mode == requested, "1792 x 1120 HiDPI is not discarded")
check(actual.maxPixelsWide == 3584 && actual.maxPixelsHigh == 2240,
      "descriptor accommodates full HiDPI backing")
let legacy = TBVirtualDisplayGeometry(profile: profile, modeOverride: requested)
check(legacy.mode == TBVirtualDisplayModeSize(width: 1536, height: 960),
      "legacy panel bound is preserved without opt-in")
'''
    swift += '\nprint("FAILURES=\\(failures)")\nexit(failures == 0 ? 0 : 1)\n'
    fixture = output / 'main.swift'
    fixture.write_text(swift)
    binary = output / 'geometry-tests'
    command = ['xcrun', 'swiftc', '-swift-version', '6', '-module-cache-path',
               str(output / 'cache'), str(fixture), '-o', str(binary)]
    with (output / 'build.log').open('w') as log:
        build = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
    if build.returncode:
        raise SystemExit(build.returncode)
    run = subprocess.run([str(binary)], capture_output=True, text=True)
    (output / 'tests.log').write_text(run.stdout + run.stderr)
    print(json.dumps({'exit': run.returncode, 'presets_only': args.presets_only,
                      'output': run.stdout.strip()}))
    raise SystemExit(run.returncode)


if __name__ == '__main__':
    main()
