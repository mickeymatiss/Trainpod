#!/usr/bin/env python3
"""Small offline macOS host suite. Artifacts always go outside the checkout."""
import argparse, json, pathlib, resource, subprocess, tempfile, sys
ROOT=pathlib.Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--output',type=pathlib.Path);p.add_argument('--live',action='store_true',help='opt in to the existing public MTA network smoke test');args=p.parse_args()
out=(args.output or pathlib.Path(tempfile.mkdtemp(prefix='keytrain-tests-'))).resolve()
if out==ROOT or ROOT in out.parents: p.error('--output must be outside the checkout')
out.mkdir(parents=True,exist_ok=True)
for generated in ('platform.txt','mta.txt'):
    (out/generated).unlink(missing_ok=True)
resource.setrlimit(resource.RLIMIT_CORE,(0,0))
results=[]
compiled=[]
executed=[]
missing=[]
def run(name,command,arguments=(),execute=True):
    print(name+': PRESENT; compiling', flush=True)
    log=[];status='COMPILE FAILED'
    try:
        c=subprocess.run(command,cwd=ROOT,text=True,capture_output=True,timeout=120);log += [c.stdout,c.stderr]
        if c.returncode==0:
            compiled.append(name)
            status='COMPILED (NOT RUN)'
            if execute:
                executed.append(name)
                print(name+': RUNNING', flush=True)
                c=subprocess.run([str(out/name),*map(str,arguments)],cwd=out,text=True,capture_output=True,timeout=30);log += [c.stdout,c.stderr];status='PASS' if c.returncode==0 else 'FAIL'
    except subprocess.TimeoutExpired as e: status='TIMEOUT';log.append(str(e))
    (out/(name+'.log')).write_text(''.join(log))
    results.append(dict(test=name,status=status,command=command,arguments=list(map(str,arguments))))
    print(name+': '+status,flush=True)
    if status in ('FAIL','COMPILE FAILED','TIMEOUT'):print(''.join(log)[-2200:],flush=True)
P='Trainpod/Products/Transit/'
common=['tests/support/HostSupport.swift',P+'Data/Models/TransitModels.swift',P+'Data/MTAStationRepository.swift',P+'Data/API/MTAClient.swift',P+'Data/API/MTAGTFSRealtime.swift',P+'BLE/LiveTransitFormatter.swift',P+'BLE/TransitMessage.swift',P+'Systems/TransitSystemID.swift','Trainpod/Platform/Transport/PayloadDelivery.swift']
manifest=[P+'Models/TransitSystemManifest.swift']+[str(x.relative_to(ROOT)) for x in sorted((ROOT/P/'Manifest').glob('*.swift'))]
swift=[('platform_formatter_test',common,[out/'platform.txt']),('mta_arrivals_test',common,[out/'mta.txt']),('transit_manifest_test',common+manifest,[ROOT/'tests/fixtures/manifests'])]
extra={'nearby_arrival_identity_test':([P+'Data/Models/TransitModels.swift',P+'UI/Nearby/NearbyArrivalETA.swift'],[]), 'diagnostic_render_test':(['Trainpod/Platform/Diagnostics/DiagnosticInterleave.swift'],[out/'diagnostic-render-reports.txt']), 'diagnostic_scope_test':(['Trainpod/Platform/Transport/PayloadDelivery.swift','Trainpod/Platform/Diagnostics/PhoneDiagnosticLog.swift','Trainpod/Platform/Diagnostics/DiagnosticInterleave.swift'],[out/'diagnostic-scope-report.txt']), 'cta_cache_test':(['tests/support/HostSupport.swift',P+'Data/Models/TransitModels.swift',P+'Data/CTAStationRepository.swift'],[]), 'ble_write_wait_test':(['Trainpod/Platform/BLE/BLEWriteWait.swift'],[]), 'protocol_contract_test':(common,[ROOT/'tests/fixtures/protocol']), 'delivery_diagnostics_test':(['Trainpod/Platform/Transport/PayloadDelivery.swift','Trainpod/Platform/Transport/DeliveryAcknowledgements.swift','Trainpod/Platform/Diagnostics/PhoneDiagnosticLog.swift','Trainpod/Platform/Diagnostics/DiagnosticPacket.swift','Trainpod/Platform/Diagnostics/DiagnosticInterleave.swift'],[]),'realtime_validation_test':(common+manifest+[P+'Models/TransitRealtimeSnapshot.swift',P+'Realtime/RealtimeResolver.swift',P+'Realtime/RealtimeTransitClient.swift',P+'Realtime/RealtimeTransitService.swift'],[ROOT/'tests/fixtures/manifests'])}
for name,(sources,arguments) in extra.items():
    if (ROOT/'tests'/f'{name}.swift').exists():swift.append((name,sources,arguments))
    else: missing.append(name)
for name,sources,arguments in swift:
    run(name,['swiftc','-module-cache-path',str(out/'swift-cache'),str(ROOT/'tests'/f'{name}.swift'),*sources,'-o',str(out/name)],arguments)
run('mta_live_smoke',['swiftc','-module-cache-path',str(out/'swift-cache'),'tests/mta_live_smoke.swift',*common,'-o',str(out/'mta_live_smoke')],execute=args.live)
fw=ROOT/'arduino/sketch_cta_ble_demo'
for test in sorted((fw/'tests').glob('*_test.cpp')):
    name=test.stem
    if name=='eta_render_test':
        results.append(dict(test=name,status='MANUAL — legacy harness retained',command=[]));print(name+': PRESENT; MANUAL (not compiled or executed)',flush=True);continue
    arguments={'platform_pages_test':[out/'platform.txt'],'mta_arrivals_contract_test':[out/'mta.txt'],'protocol_contract_test':[ROOT/'tests/fixtures/protocol']}.get(name,[])
    # Prefix binary/log name to distinguish the C++ and Swift shared-contract tests.
    binary='firmware_'+name
    cmd=['clang++','-std=c++17','-Wall','-Wextra',str(test),'-o',str(out/binary)]
    if name=='receiver_test':cmd.append(str(fw/'src/platform/transport/BLETestReceiver.cpp'))
    run(binary,cmd,arguments)
(out/'results.json').write_text(json.dumps(results,indent=2)+'\n')
print('\nVerification summary', flush=True)
print(f'Registered harnesses present: {len(results)}')
print(f'Executables compiled: {len(compiled)}')
print(f'Executables run: {len(executed)}')
for label, names in [
    ('Passed', [x['test'] for x in results if x['status'] == 'PASS']),
    ('Compiled only', [x['test'] for x in results if x['status'] == 'COMPILED (NOT RUN)']),
    ('Manual', [x['test'] for x in results if x['status'].startswith('MANUAL')]),
    ('Failed', [x['test'] for x in results if x['status'] in ('FAIL', 'COMPILE FAILED', 'TIMEOUT')]),
    ('Missing optional registrations (not run)', missing),
]:
    print(f"{label} ({len(names)}): {', '.join(names) if names else 'none'}")
print('Separate harnesses (not included in counts above):')
for source, command in [
    ('tests/nearby_retry_policy_test.swift', 'tests/run_nearby_retry_policy_test.py'),
    ('tests/ios/theme_controller_test.swift', 'tests/run_theme_controller_test.py'),
]:
    presence = 'PRESENT' if (ROOT / source).exists() else 'MISSING'
    print(f'  {source}: {presence}; NOT RUN by this runner; use {command}')
print('Physical BLE/display/theme checks: MANUAL; host success is not hardware success.')
print('Artifacts: '+str(out))
sys.exit(any(x['status'] in ('FAIL','COMPILE FAILED','TIMEOUT') for x in results))
