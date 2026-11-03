#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parent.parent
stage = root / '.build/disconnect-protection-mutations'
stage.mkdir(parents=True, exist_ok=True)
files = ['DisconnectProtectionPolicy.swift', 'DisconnectProtectionFirewall.swift']
originals = {name: (root / 'Sources/QingzhouKit' / name).read_text() for name in files}
checks = (root / 'Sources/QingzhouChecks/DisconnectProtectionTests.swift').read_text().replace('PolicyValidator.validate(', 'DisconnectProtectionPolicy.validate(')
(stage / 'Checks.swift').write_text(checks)
(stage / 'Assertions.swift').write_text((root / 'Sources/QingzhouChecks/Assertions.swift').read_text())
(stage / 'Entry.swift').write_text('''import Foundation
@main struct ProtectionChecks {
    static func main() throws {
        let t=DisconnectProtectionTests()
        try t.testPolicy();try t.testLifecycle();try t.testFailureAndRestart()
        print("RESULT assertions=\\(CheckHarness.assertions) failures=\\(CheckHarness.failures)")
        exit(CheckHarness.failures==0 ? 0:1)
    }
}
''')
objects = []
for pattern in ['QingzhouKit.build/*.o', 'CQingzhouRoute.build/*.o', 'Yams.build/*.o', 'CYaml.build/src/*.o']:
    objects.extend(str(p) for p in (root / '.build/debug').glob(pattern))
command = ['swiftc', '-parse-as-library', '-swift-version', '5', '-profile-generate', '-profile-coverage-mapping', '-I', str(root / '.build/debug/Modules'), '-I', str(root / 'Vendor/Yams/Sources/CYaml/include'), '-Xcc', '-fmodule-map-file=' + str(root / '.build/debug/CQingzhouRoute.build/module.modulemap'), '-module-cache-path', str(root / '.build/module-cache')]
command += [str(stage / name) for name in files] + [str(stage / name) for name in ['Checks.swift', 'Assertions.swift', 'Entry.swift']] + objects + ['-o', str(stage / 'checks')]
mutants = [
    ('允许系统代理', files[0], 'state.captureMode.usesTunnel,', 'true,'),
    ('允许直连模式', files[0], 'state.mode == .global,', 'true,'),
    ('允许系统 DNS', files[0], 'state.dnsPreference == .httpsProxy,', 'true,'),
    ('允许 DNS 回退', files[0], 'state.strictDNS==true,', 'true,'),
    ('允许 HTTP 兼容', files[0], '!state.httpCompatibilityEnabled else', 'true else'),
    ('接受任意节点地址', files[0], 'guard publicEndpoint(node.server) else', 'guard true else'),
    ('保留其他节点', files[0], 'next.nodes=state.nodes.filter{$0.id==id}', 'next.nodes=state.nodes'),
    ('保留用户直连规则', files[0], 'next.rules=[]', 'next.rules=state.rules'),
    ('允许公网 DNS 直连', files[0], 'infrastructure+[endpoint]+corporate', 'infrastructure+[endpoint,"1.1.1.1/32"]+corporate'),
    ('移除 IPv6 阻断', files[0], '" inet6 from any to ! <qz_disconnect_allowed>\\n"', '"\\n"'),
    ('不接入隧道规则', files[0], 'let scope=tunnel.map{" on ! "+$0} ?? ""', 'let scope=""'),
    ('不检查企业防火墙', files[1], 'do {try PinnedBypassPolicy.validateFirewallRoot(command(["-sr"]))}', 'do {try PinnedBypassPolicy.validateFirewallRoot("anchor \\"com.apple/*\\" all\\n")}'),
    ('不检查外部规则改写', files[1], 'try command(["-a",lease.anchor,"-sr"])==expected', 'true'),
    ('允许保护期间换出口', files[1], 'guard lease.allowed==normalized else', 'guard true else'),
    ('暂停时不收紧规则', files[1], 'if lease?.tunnel != nil {try apply(tunnel:nil,first:false)}', 'if false {try apply(tunnel:nil,first:false)}'),
    ('不清理 IPv6 旧状态', files[1], '_=try command(["-k","::/0"])', '_=0'),
    ('不清理 IPv4 旧状态', files[1], '_=try command(["-k","0.0.0.0/0"])', '_=0'),
    ('错误解除时删除恢复记录', files[1], 'if !current.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {try verify()}', 'if false {try verify()}'),
]

def run(name, mutation=None):
    for file, source in originals.items():
        if mutation and file == mutation[0]:
            assert mutation[1] in source, (name, mutation[1])
            source = source.replace(mutation[1], mutation[2], 1)
        (stage / file).write_text('import QingzhouKit\n' + source)
    with (stage / (name + '-build.log')).open('wb') as output:
        build = subprocess.run(command, cwd=root, stdout=output, stderr=output)
    if build.returncode:
        return 'BUILD_ERROR'
    env = os.environ.copy()
    env['LLVM_PROFILE_FILE'] = str(stage / (name + '.profraw'))
    with (stage / (name + '-test.log')).open('wb') as output:
        result = subprocess.run([str(stage / 'checks')], cwd=root, stdout=output, stderr=output, env=env, timeout=30)
    return 'KILLED' if result.returncode else 'SURVIVED'

baseline = run('baseline')
if baseline != 'SURVIVED':
    raise SystemExit('基线未通过：' + baseline)
# 保存基线二进制，避免变异结果污染覆盖率。
import shutil
shutil.copy2(stage / 'checks', stage / 'baseline-checks')
results = []
for index, (name, file, old, new) in enumerate(mutants):
    status = run('mutation-' + str(index), (file, old, new))
    results.append({'name': name, 'status': status})
    print(status, name, flush=True)
summary = {'scope': '两个新增保护模块的定向变异，不代表全应用变异覆盖', 'results': results, 'killed': sum(r['status'] == 'KILLED' for r in results), 'survived': sum(r['status'] == 'SURVIVED' for r in results), 'buildErrors': sum(r['status'] == 'BUILD_ERROR' for r in results)}
(stage / 'results.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2))
for name, source in originals.items():
    (stage / name).write_text('import QingzhouKit\n' + source)
subprocess.run(['xcrun', 'llvm-profdata', 'merge', '-sparse', str(stage / 'baseline.profraw'), '-o', str(stage / 'baseline.profdata')], check=True)
with (stage / 'coverage.txt').open('w') as output:
    subprocess.run(['xcrun', 'llvm-cov', 'report', str(stage / 'baseline-checks'), '-instr-profile=' + str(stage / 'baseline.profdata')] + [str(stage / file) for file in files], stdout=output, check=True)
with (stage / 'coverage.json').open('w') as output:
    subprocess.run(['xcrun', 'llvm-cov', 'export', str(stage / 'baseline-checks'), '-instr-profile=' + str(stage / 'baseline.profdata')] + [str(stage / file) for file in files], stdout=output, check=True)
print('RESULT', json.dumps({k: v for k, v in summary.items() if k != 'results'}, ensure_ascii=False))
if summary['buildErrors'] or summary['killed'] / len(mutants) < 0.8:
    raise SystemExit(1)
