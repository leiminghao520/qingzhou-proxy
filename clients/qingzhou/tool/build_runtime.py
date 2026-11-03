#!/usr/bin/env python3
import argparse,hashlib,json,os,pathlib,platform,shutil,subprocess
client=pathlib.Path(__file__).resolve().parent.parent
root=client.parents[1]
parser=argparse.ArgumentParser();parser.add_argument('platform',choices=['android','ios','windows']);args=parser.parse_args()
env=os.environ.copy();go_bin=pathlib.Path(subprocess.check_output(['go','env','GOPATH'],text=True).strip())/'bin';env['PATH']=str(go_bin)+os.pathsep+env['PATH']
lock=json.loads((root/'Vendor/core-lock.json').read_text());version=lock['version']
source_lock=json.loads((client/'runtime/core-source-lock.json').read_text())
module=json.loads(subprocess.check_output(['go','mod','download','-json',source_lock['module']],cwd=client/'runtime',text=True))
origin=json.loads(pathlib.Path(module['Info']).read_text()).get('Origin',{})
if module['Version']!='v'+version or module['Sum']!=source_lock['sum'] or origin.get('Hash')!=source_lock['commit']:
 raise SystemExit('核心源码与锁定记录不一致')
tags=source_lock['tags']
flags=f'-s -w -checklinkname=0 -X github.com/sagernet/sing-box/constant.Version={version}'
def run(command):subprocess.run(command,cwd=client/'runtime',env=env,check=True)
run(['go','mod','verify'])
if args.platform=='android':
 if not env.get('ANDROID_HOME'):raise SystemExit('请设置 ANDROID_HOME 到 Android SDK')
 env['ANDROID_NDK_HOME']=env.get('ANDROID_NDK_HOME',str(pathlib.Path(env['ANDROID_HOME'])/'ndk/28.2.13676358'))
 output=client/'android/app/libs/qingzhou.aar';output.parent.mkdir(parents=True,exist_ok=True)
 run(['gomobile','bind','-target=android/arm64','-androidapi=29','-javapkg=cn.qingzhou.bridge','-libname=qzcore','-tags',tags,'-ldflags',flags,'-o',str(output),'./mobile'])
elif args.platform=='ios':
 if platform.system()!='Darwin':raise SystemExit('iOS 构建需要 macOS 和完整 Xcode')
 subprocess.run(['xcrun','--sdk','iphoneos','--show-sdk-path'],check=True,stdout=subprocess.DEVNULL)
 output=client/'ios/Frameworks/Mobile.xcframework';output.parent.mkdir(parents=True,exist_ok=True)
 run(['gomobile','bind','-target=ios,iossimulator','-iosversion=16.0','-prefix=QZ','-libname=qzcore','-tags',tags,'-ldflags',flags,'-o',str(output),'./mobile'])
else:
 env.update(GOOS='windows',GOARCH='amd64',CGO_ENABLED='0')
 output=client/'build/runtime/qingzhou-service.exe';output.parent.mkdir(parents=True,exist_ok=True)
 run(['go','build','-trimpath','-tags',tags,'-ldflags',flags,'-o',str(output),'./cmd/qingzhou-service'])
files=[output] if output.is_file() else sorted(p for p in output.rglob('*') if p.is_file())
metadata={'platform':args.platform,'coreVersion':version,'go':subprocess.check_output(['go','version'],text=True).strip(),'gomobile':'v0.1.12','tags':tags,'source':subprocess.check_output(['go','list','-m','-json','github.com/sagernet/sing-box'],cwd=client/'runtime',text=True),'files':[{'path':str(p.relative_to(client)),'size':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()}for p in files]}
metadata.update(sourceCommit=source_lock['commit'],sourceSum=source_lock['sum'],license=source_lock['license'],linkFlags=flags)
manifest=client/'build/runtime'/f'{args.platform}-manifest.json';manifest.parent.mkdir(parents=True,exist_ok=True);manifest.write_text(json.dumps(metadata,ensure_ascii=False,indent=2)+'\n');print(manifest)
