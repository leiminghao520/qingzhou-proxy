#!/usr/bin/env python3
import datetime,hashlib,json,pathlib,secrets,shutil,subprocess,sys
client=pathlib.Path(__file__).resolve().parent.parent
root=client.parents[1]
platform=sys.argv[1];source=pathlib.Path(sys.argv[2]).resolve()
if not source.is_file():raise SystemExit('构建产物不存在')
output=root/'outputs'/('crossplatform-'+platform+'-'+datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8))).strftime('%Y%m%d-%H%M%S')+'-'+secrets.token_hex(4));output.mkdir(parents=True,exist_ok=False)
destination=output/source.name;shutil.copy2(source,destination)
shutil.copy2(root/'LICENSE',output/'LICENSE')
native=client/'build/runtime'/f'{platform}-manifest.json'
if native.exists():shutil.copy2(native,output/native.name)
shutil.copy2(client/'runtime/core-source-lock.json',output/'core-source-lock.json')
shutil.copy2(client/'README.md',output/'BUILD-README.md')
record=root/'docs/verification-crossplatform.md'
if record.exists():shutil.copy2(record,output/'VERIFICATION.md')
module=subprocess.check_output(['go','list','-m','-json','github.com/sagernet/sing-box'],cwd=client/'runtime',text=True)
snapshot=root/'source-snapshot.json'
if snapshot.exists():
 revision=json.loads(snapshot.read_text(encoding='utf-8'));git=revision['git'];dirty=revision['dirty']
else:
 git=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()
 dirty=bool(subprocess.check_output(['git','status','--porcelain'],cwd=root,text=True))
kind='windows-service-only' if source.name=='qingzhou-service.exe' else 'client-test-package'
manifest={'platform':platform,'artifactKind':kind,'git':git,'dirty':dirty,'core':json.loads(module),'artifact':destination.name,'size':destination.stat().st_size,'sha256':hashlib.sha256(destination.read_bytes()).hexdigest(),'verification':{'installed':'未验证','realNetwork':'未验证','stability2h':'未验证','strictQualityGate':'未验证'}}
(output/'artifact-manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n');print(output)
