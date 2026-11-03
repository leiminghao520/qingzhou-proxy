#!/usr/bin/env python3
import datetime,hashlib,json,pathlib,secrets,subprocess,zipfile

client=pathlib.Path(__file__).resolve().parent.parent
root=client.parents[1]
prefixes=['clients/qingzhou','tools/httpcompat','Sources/QingzhouKit/BuildVersion.swift','Vendor/core-lock.json','LICENSE','docs/verification-crossplatform.md','docs/windows-build.md']
listed=subprocess.check_output(['git','ls-files','-z','--cached','--others','--exclude-standard','--',*prefixes],cwd=root).decode('utf-8').split('\0')
files=[]
for name in sorted(set(listed)):
 if not name:continue
 path=root/name
 if path.is_file() and not path.is_symlink():files.append((name,path.read_bytes()))
record={'git':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),'dirty':bool(subprocess.check_output(['git','status','--porcelain'],cwd=root,text=True)),'files':[{'path':name,'sha256':hashlib.sha256(data).hexdigest()}for name,data in files]}
output=root/'outputs'/('windows-source-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S')+'-'+secrets.token_hex(4));output.mkdir(parents=True,exist_ok=False)
archive=output/'qingzhou-windows-source.zip'
with zipfile.ZipFile(archive,'w',compression=zipfile.ZIP_DEFLATED)as z:
 for name,data in files:z.writestr('qingzhou-proxy/'+name,data)
 z.writestr('qingzhou-proxy/source-snapshot.json',json.dumps(record,ensure_ascii=False,indent=2)+'\n')
 z.writestr('qingzhou-proxy/build-windows.cmd','@echo off\r\nchcp 65001 >nul\r\npowershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0clients\\qingzhou\\tool\\build_windows.ps1"\r\nif errorlevel 1 pause\r\n')
(output/'sha256.txt').write_text(hashlib.sha256(archive.read_bytes()).hexdigest()+'  '+archive.name+'\n',encoding='utf-8')
print(archive)
