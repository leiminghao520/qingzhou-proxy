#!/usr/bin/env python3
"""生成可审阅的服务端候选包与摘要，不上传或部署。"""
from pathlib import Path
import hashlib,json,tarfile,sys
root=Path(__file__).resolve().parents[1]
folder=Path(sys.argv[1]) if len(sys.argv)>1 else root/'outputs/vps-client-0.10.0-candidate'
folder.mkdir(parents=True,exist_ok=True)
source=root/'server/hy2-admin';bundle=folder/'hy2-client-source.tar.gz';entries={}
with tarfile.open(bundle,'w:gz') as tf:
    for path in sorted(source.rglob('*')):
        relative=path.relative_to(source)
        if not path.is_file() or any(p.startswith('.') or p=='__pycache__' for p in relative.parts):continue
        if path.suffix in ['.env','.sqlite3','.pem','.key']:raise SystemExit('候选包中检测到运行期文件，已停止')
        tf.add(path,arcname='hy2-admin/'+str(relative))
        entries[str(relative)]={'size':path.stat().st_size,'sha256':hashlib.sha256(path.read_bytes()).hexdigest()}
manifest={'version':'0.10.0-candidate','deployed':False,'source':entries,
          'archive':{'name':bundle.name,'size':bundle.stat().st_size,'sha256':hashlib.sha256(bundle.read_bytes()).hexdigest()}}
(folder/'server-manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
print('SERVER_CANDIDATE_OK '+str(folder))
