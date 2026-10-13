#!/usr/bin/env python3
import pathlib,struct,sys
source=pathlib.Path(sys.argv[1]);chunks=[]
for size,kind in [(16,b'icp4'),(32,b'icp5'),(64,b'icp6'),(128,b'ic07'),(256,b'ic08'),(512,b'ic09'),(1024,b'ic10')]:
    data=(source/f'size-{size}.png').read_bytes();chunks.append(kind+struct.pack('>I',len(data)+8)+data)
body=b''.join(chunks)
pathlib.Path(sys.argv[2]).write_bytes(b'icns'+struct.pack('>I',len(body)+8)+body)
