#!/usr/bin/env python3
"""Host characterization: production VM control flow with test-only stepped timer."""
import argparse, pathlib, subprocess
root = pathlib.Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--output', type=pathlib.Path, required=True)
a = p.parse_args()
out = a.output.resolve()
if out == root or root in out.parents:
    p.error('output must be outside checkout')
out.mkdir(parents=True, exist_ok=True)
binary = out / 'nearby_retry_policy_test'
source = root / 'Trainpod/Products/Transit/UI/Nearby/NearbyStationsViewModel.swift'
original = source.read_text()
needle = 'try await Task.sleep(for: .seconds(60))'
assert original.count(needle) == 1, 'Review fixture if production timer shape changes'
generated = out / 'NearbyStationsViewModel-policy-test.swift'
generated.write_text(original.replace(needle, 'try await RetryTestClock.sleep()'))
subprocess.run(['swiftc', '-module-cache-path', str(out / 'swift-cache'),
    str(root / 'tests/nearby_retry_policy_test.swift'),
    str(root / 'Trainpod/Products/Transit/Data/Models/TransitModels.swift'),
    str(generated),
    '-o', str(binary)], check=True, timeout=120)
subprocess.run([str(binary)], check=True, timeout=15)
