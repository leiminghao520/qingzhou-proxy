#!/usr/bin/env python3
"""独立 Darwin ABI 参考编码；只使用标准库，可在 Windows 运行，不执行系统路由命令。"""
import argparse
import ipaddress
import json
import struct
from pathlib import Path

# 参考：Apple network_cmds route.c 的 rtmsg/NEXTADDR 与 xnu-12377.1.9 route.h。
# 不调用待测 C 编码器或解析器；Darwin ABI 固定，宿主平台不参与解释。
CASES = {
    'ipv4-host': ('192.0.2.7', 32, '127.0.0.1', 1, False, False),
    'ipv4-network': ('192.0.2.0', 24, '127.0.0.1', 1, False, False),
    'ipv4-scoped': ('192.0.2.0', 24, '127.0.0.1', 1, True, False),
    'ipv6-host': ('2001:db8::7', 128, '::1', 1, False, False),
    'ipv6-network': ('2001:db8::', 64, '::1', 1, False, False),
    'default-get': ('0.0.0.0', 0, '', 4, False, False),
    'ipv6-get': ('2001:db8::7', 128, '', 4, False, False),
    'linklocal-get': ('fe80::', 128, '', 4, False, False),
    'linklocal-scoped': ('fe80::', 128, '', 4, True, False),
    'legacy-delete': ('2001:db8::7', 128, '::1', 2, False, True),
    'host-delete': ('192.0.2.7', 32, '127.0.0.1', 2, False, False),
    'ipv6-direct': ('2001:db8::7', 128, 'link', 1, False, False),
    'ipv6-scoped-write': ('2001:db8::', 64, 'fe80::1', 1, True, False),
    'ipv6-default-get': ('::', 0, '', 4, False, False),
    'ipv4-default-add': ('0.0.0.0', 0, '127.0.0.1', 1, False, False),
    'ipv6-default-add': ('::', 0, 'fe80::1', 1, False, False),
    'ipv6-scoped-delete': ('fe80::7', 128, 'fe80::1', 2, True, False),
    'direct': ('192.0.2.7', 32, 'link', 1, True, False),
}


def ip_sockaddr(text, index=0):
    address = ipaddress.ip_address(text)
    if address.version == 4:
        return bytes([16, 2, 0, 0]) + address.packed + bytes(8)
    packed = bytearray(address.packed)
    if address.is_link_local:
        packed[2:4] = index.to_bytes(2, 'big')
    return bytes([28, 30]) + bytes(6) + packed + struct.pack('<I', index if address.is_link_local else 0)


def reference(name, index):
    destination, bits, gateway, operation, scoped, legacy = CASES[name]
    maximum = ipaddress.ip_address(destination).max_prefixlen
    flags = 1 | (0x1000000 if scoped else 0)
    addresses = {1: ip_sockaddr(destination, index if scoped else 0)}
    if operation == 4:
        addresses[16] = bytes([20, 18]) + bytes(18)
        if bits < maximum:
            addresses[4] = ip_sockaddr(str(ipaddress.ip_network(destination + '/' + str(bits)).netmask))
    else:
        flags |= 0x800
        if bits == maximum and not legacy:
            flags |= 4
        else:
            mask = '::' if legacy else str(ipaddress.ip_network(destination + '/' + str(bits)).netmask)
            addresses[4] = ip_sockaddr(mask)
        if gateway == 'link':
            addresses[2] = struct.pack('<BBHBBBB', 20, 18, index, 24, 3, 0, 0) + b'lo0' + bytes(9)
        else:
            flags |= 2
            addresses[2] = ip_sockaddr(gateway, index)
    body = b''.join(addresses[key] + bytes((-len(addresses[key])) % 4) for key in sorted(addresses))
    header = bytearray(92)
    struct.pack_into('<HBBH', header, 0, len(header) + len(body), 5, operation, index if scoped else 0)
    struct.pack_into('<iiii', header, 8, flags, sum(addresses), 123, 456)
    return bytes(header) + body


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('corpus', type=Path)
    args = parser.parse_args()
    rows = [json.loads(line) for line in args.corpus.read_text().splitlines()]
    assert {row['name'] for row in rows} == set(CASES)
    for row in rows:
        expected = reference(row['name'], row['index'])
        actual = bytes.fromhex(row['hex'])
        assert actual == expected, '独立参考报文不一致：' + row['name']
    print('ROUTE_PROTOCOL_ORACLE_OK cases=' + str(len(rows)) + ' exactBytes=true kernelCalls=0')


if __name__ == '__main__':
    main()
