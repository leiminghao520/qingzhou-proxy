#!/usr/bin/env python3
import pathlib,subprocess
client=pathlib.Path(__file__).resolve().parent.parent
root=client.parents[1]
build=client/'build/interop';build.mkdir(parents=True,exist_ok=True)
subprocess.run(['dart','run','tool/backup_interop.dart',str(build/'dart.qzb')],cwd=client,check=True)
objects=[]
for name in ['QingzhouKit','Yams','CYaml']:
 objects.extend(str(p) for p in (root/'.build/debug'/f'{name}.build').rglob('*.o'))
if not objects:raise SystemExit('请先执行 scripts/swift-local.sh run QingzhouChecks')
command=['swiftc','-I',str(root/'.build/debug/Modules'),'-Xcc','-fmodule-map-file='+str(root/'Vendor/Yams/Sources/CYaml/include/module.modulemap'),'-I',str(root/'Vendor/Yams/Sources/CYaml/include'),str(client/'tool/backup_interop.swift'),*objects,'-o',str(build/'verify')]
subprocess.run(command,cwd=root,check=True)
subprocess.run([str(build/'verify'),str(build/'dart.qzb')],check=True)
