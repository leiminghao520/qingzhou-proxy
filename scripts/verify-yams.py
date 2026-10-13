#!/usr/bin/env python3
import hashlib,json,pathlib,tarfile
root=pathlib.Path(__file__).resolve().parent.parent/'Vendor'
lock=json.loads((root/'yams-lock.json').read_text());archive=root/'yams-6.2.2-source.tar.gz'
if hashlib.sha256(archive.read_bytes()).hexdigest()!=lock['archiveSHA256']:raise SystemExit('Yams 官方归档校验失败')
with tarfile.open(archive) as source:
    for member in source:
        if not member.isfile():continue
        parts=pathlib.PurePosixPath(member.name).parts
        if len(parts)<2 or '..' in parts:raise SystemExit('Yams 归档路径无效')
        local=root/'Yams'/pathlib.Path(*parts[1:])
        if not local.is_file() or hashlib.sha256(local.read_bytes()).digest()!=hashlib.sha256(source.extractfile(member).read()).digest():raise SystemExit('Yams 源文件校验失败')
print('YAMS_6.2.2_VERIFY_OK')
