#!/usr/bin/env python3
import hashlib,json,pathlib,subprocess,tempfile,tarfile
root=pathlib.Path(__file__).resolve().parent.parent
lock=json.loads((root/'Vendor/core-lock.json').read_text())
binary=root/'Vendor/sing-box'
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
if binary.exists() and digest(binary)==lock['binarySHA256']:
    print('CORE_VERIFIED');raise SystemExit(0)
with tempfile.TemporaryDirectory() as d:
    archive=pathlib.Path(d)/'core.tar.gz'
    subprocess.run(['curl','-fL','--retry','2',lock['archiveURL'],'-o',str(archive)],check=True)
    if digest(archive)!=lock['archiveSHA256']:raise SystemExit('核心压缩包 SHA-256 不匹配')
    with tarfile.open(archive) as t:
        member=next(m for m in t.getmembers() if m.name.endswith('/sing-box') and m.isfile())
        binary.write_bytes(t.extractfile(member).read())
    binary.chmod(0o755)
    if digest(binary)!=lock['binarySHA256']:raise SystemExit('核心可执行文件 SHA-256 不匹配')
print('CORE_VERIFIED')
