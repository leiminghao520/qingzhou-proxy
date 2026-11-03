#!/usr/bin/env python3
"""用标准库区间差集独立核对 Swift 捕获规划，可在 Windows 运行。"""
import ipaddress
import json
import sys
from pathlib import Path

rows = json.loads(Path(sys.argv[1]).read_text())
for row in rows:
    if row['fallback']:
        assert row['prefixes'] == ['0.0.0.0/1', '128.0.0.0/1', '::/1', '8000::/1']
        assert not row['exclusions']
        continue
    remaining = [ipaddress.ip_network('0.0.0.0/0'), ipaddress.ip_network('::/0')]
    for excluded in row['exclusions']:
        target = ipaddress.ip_network(excluded)
        result = []
        for network in remaining:
            if network.version != target.version or not network.overlaps(target):
                result.append(network)
            elif target.subnet_of(network):
                result.extend(network.address_exclude(target))
        remaining = result
    subject = [ipaddress.ip_network(prefix) for prefix in row['prefixes']]
    for version in (4, 6):
        expected = list(ipaddress.collapse_addresses(n for n in remaining if n.version == version))
        actual = list(ipaddress.collapse_addresses(n for n in subject if n.version == version))
        assert expected == actual, '捕获范围不同：' + str(row)
    for index, network in enumerate(subject):
        assert all(network.version != other.version or not network.overlaps(other) for other in subject[index + 1:])
print('CAPTURE_PLAN_ORACLE_OK cases=' + str(len(rows)) + ' independentIntervalDifference=true')
