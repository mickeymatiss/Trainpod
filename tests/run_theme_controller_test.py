#!/usr/bin/env python3
"""Focused UIKit controller harness on a supplied booted simulator; never boots/erases it."""
import argparse, pathlib, platform, plistlib, subprocess, sys
ROOT = pathlib.Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--device', required=True, help='UDID of an already booted iOS simulator')
p.add_argument('--output', required=True, type=pathlib.Path)
p.add_argument('--controller-source', type=pathlib.Path, help='Optional baseline source for a red/green comparison')
a = p.parse_args()
out = a.output.resolve()
if out == ROOT or ROOT in out.parents: p.error('--output must be outside the checkout')
out.mkdir(parents=True, exist_ok=True)
app = out/'ThemeControllerChecks.app'
app.mkdir(exist_ok=True)
bundle_id = 'org.keytrain.characterization.theme'
(app/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': bundle_id, 'CFBundleName': 'ThemeControllerChecks', 'CFBundleExecutable': 'theme_controller_test', 'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0', 'LSRequiresIPhoneOS': True, 'MinimumOSVersion': '26.5'}))
sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
controller = a.controller_source or ROOT/'Trainpod/Products/Transit/Themes/DeviceUIColor.swift'
cmd = ['xcrun', '--sdk', 'iphonesimulator', 'swiftc', '-target', platform.machine()+'-apple-ios26.5-simulator', '-sdk', sdk,
       '-module-cache-path', str(out/'swift-cache'), str(ROOT/'tests/ios/theme_controller_test.swift'),
       str(ROOT/'tests/ios/ThemeTransportSupport.swift'), str(controller),
       str(ROOT/'Trainpod/Products/Transit/Themes/Model/DeviceTheme.swift'), '-o', str(app/'theme_controller_test')]
subprocess.run(cmd, check=True, timeout=120)
subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True, timeout=30)
subprocess.run(['xcrun', 'simctl', 'install', a.device, str(app)], check=True, timeout=30)
try:
    result = subprocess.run(['xcrun', 'simctl', 'launch', '--console', a.device, bundle_id], check=True, timeout=60, text=True, capture_output=True)
    print(result.stdout, end='')
    print(result.stderr, end='', file=sys.stderr)
    # simctl may itself exit zero after the test app crashes. Require its success marker.
    if 'PASS real theme controller:' not in result.stdout:
        raise SystemExit('Theme harness did not report success')
finally:
    subprocess.run(['xcrun', 'simctl', 'uninstall', a.device, bundle_id], check=True, timeout=30)
