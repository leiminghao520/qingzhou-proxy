#!/usr/bin/env python3
import pathlib,re
root=pathlib.Path(__file__).resolve().parents[3]
client=pathlib.Path(__file__).resolve().parent.parent
text=(root/'Sources/QingzhouKit/BuildVersion.swift').read_text()
version=re.search(r'current\s*=\s*"([^"]+)"',text)[1]
build=re.search(r'build\s*=\s*(\d+)',text)[1]
p=client/'pubspec.yaml';p.write_text(re.sub(r'^version:.*$',f'version: {version}+{build}',p.read_text(),flags=re.M))
(client/'ios/Version.xcconfig').write_text(f'QINGZHOU_VERSION={version}\nQINGZHOU_BUILD={build}\n')
