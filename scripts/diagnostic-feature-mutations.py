#!/usr/bin/env python3
"""在独立源码副本运行定向变异；编译失败和超时不计为检出。"""
from pathlib import Path
import subprocess, shutil, json, os
root=Path(__file__).resolve().parent.parent
stage=root/'.build/diagnostic-feature-mutations'
stage.mkdir(parents=True,exist_ok=True)
for name in ['QingzhouKit','CQingzhouRoute']:
    shutil.copytree(root/'Sources'/name,stage/'Sources'/name,dirs_exist_ok=True)
(stage/'Sources/FeatureChecks').mkdir(exist_ok=True)
shutil.copy2(root/'scripts/diagnostics-history-events-checks.swift',stage/'Sources/FeatureChecks/main.swift')
manifest='''// swift-tools-version: 6.0
import PackageDescription
let package=Package(name:"FeatureMutations",platforms:[.macOS(.v14)],dependencies:[.package(path:"VENDOR")],targets:[.target(name:"CQingzhouRoute",publicHeadersPath:"include"),.target(name:"QingzhouKit",dependencies:["CQingzhouRoute",.product(name:"Yams",package:"Yams")]),.executableTarget(name:"FeatureChecks",dependencies:["QingzhouKit"])],swiftLanguageModes:[.v5])
'''.replace('VENDOR',str(root/'Vendor/Yams'))
(stage/'Package.swift').write_text(manifest)
# 独立源文件带显式入口，文件名不能触发顶层入口推断。
(stage/'Sources/FeatureChecks/main.swift').rename(stage/'Sources/FeatureChecks/FeatureChecks.swift')
def build(name):
    with (stage/(name+'-build.log')).open('w') as out:
        return subprocess.run(['bash',str(root/'scripts/swift-local.sh'),'build','--package-path',str(stage),'--build-path',str(stage/'build'),'--product','FeatureChecks'],cwd=root,stdout=out,stderr=subprocess.STDOUT).returncode

def run(name):
    try:
        p=subprocess.run([str(stage/'build/debug/FeatureChecks')],cwd=root,text=True,capture_output=True,timeout=30)
        (stage/(name+'-run.log')).write_text(p.stdout+p.stderr)
        return p.returncode,p.stdout
    except subprocess.TimeoutExpired:
        return None,'timeout'
if build('baseline')!=0:raise SystemExit('BASELINE_BUILD_FAILED')
code,output=run('baseline')
if code!=0:raise SystemExit('BASELINE_CHECKS_FAILED '+output[-400:])
mutations=[
 ('dns-release-early','DiagnosticSession.swift','active+=1;return true','return true'),
 ('dns-unbounded','DiagnosticSession.swift','guard active<limit else{return false}','guard active<limit+10 else{return false}'),
 ('cancel-ignored','DiagnosticSession.swift','onCancel:{pending.finish(code:"cancelled",status:"已取消")}','onCancel:{}'),
 ('history-keeps-retired-ref','NodeStore.swift','profile.configuration.nodes[i].credentialRef=mapping[profile.configuration.nodes[i].credentialRef]!','profile.configuration.nodes[i].credentialRef=profile.configuration.nodes[i].credentialRef'),
 ('history-no-credential-capture','ProfileHistoryStore.swift','secrets[ref]=try credentials.get(ref)','_ = ref'),
 ('history-no-transaction-marker','NodeStore.swift','if let id=tx.historyTransactionID {root.lastHistoryTransactionID=id}','if tx.historyTransactionID != nil {root.lastHistoryTransactionID=nil}'),
 ('history-no-pause','NodeStore.swift','profile.configuration.subscriptions[i].autoUpdate=false','profile.configuration.subscriptions[i].autoUpdate=true'),
 ('history-runtime-history','ProfileHistoryStore.swift','state.latency=[:];state.recentUse=[:]','state.latency=[:]'),
 ('event-cross-session-merge','NetworkEventStore.swift','last.sessionID==event.sessionID,',''),
 ('event-no-budget','NetworkEventStore.swift','guard size+line.count<=maximumBytes else{break}','guard size+line.count<=maximumBytes*100 else{break}'),
 ('event-keep-expired','NetworkEventStore.swift','next.removeAll{$0.time<now().addingTimeInterval(-retention)}','next.removeAll{_ in false}'),
 ('port-false-ownership','DiagnosticService.swift','available ? "通过":"未验证"','available || connected ? "通过":"未验证"'),
]
results=[]
for name,file,old,new in mutations:
    path=stage/'Sources/QingzhouKit'/file;original=path.read_text()
    if old not in original:raise SystemExit('MUTATION_TARGET_MISSING '+name)
    path.write_text(original.replace(old,new,1))
    try:
        if build(name)!=0:result='build_failed'
        else:
            code,output=run(name)
            result='timeout' if code is None else 'survived' if code==0 else 'detected' if 'FEATURE_CHECKS_FAILED' in output else 'crashed'
        results.append(dict(name=name,result=result));print(name,result,flush=True)
    finally:path.write_text(original)
(stage/'results.json').write_text(json.dumps(results,indent=2))
print('TARGETED_MUTATIONS',sum(x['result']=='detected' for x in results),'/',len(results))
