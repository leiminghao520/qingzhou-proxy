#!/usr/bin/env python3
"""只在临时目录和模拟命令中核验恢复工具，不访问系统防火墙。"""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('rescue', Path(__file__).with_name('restore-normal-network.py'))
rescue = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rescue)
anchor = 'qingzhou-lock-e018f7bc-974e-44b5-8125-24d7464b3cb0'
original = 'anchor "com.sangfor.vpn" all\n'
count = 0
for case in ('detached', 'attached', 'changed_root', 'changed_rules', 'children', 'no_record', 'no_record_owned_root', 'references_unreadable', 'service_exiting', 'service_stuck', 'takeover_pending'):
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory) / 'helper'
        root.mkdir()
        expected_root = 'anchor "' + anchor + '" quick all\n' + original
        state = {'root': expected_root if case in ('attached', 'no_record_owned_root') else original,
                 'rules': 'block drop all\n' if case in ('attached', 'changed_rules', 'children') else '', 'prints': 0}
        if case == 'changed_root':
            state['root'] += 'block all\n'
        if case == 'changed_rules':
            state['rules'] = 'pass all\n'
        if case not in ('no_record', 'no_record_owned_root'):
            (root / 'disconnect-protection.json').write_text(json.dumps({'anchor': anchor, 'rootBefore': original, 'rootExpected': expected_root, 'expected': 'block drop all\n'}))
        if case == 'takeover_pending':
            (root / 'recovery.json').write_text('{}')
        commands = []
        def fake_pf(*args, **kwargs):
            if args == ('-sr',):
                return state['root']
            if args == ('-s', 'References'):
                if case == 'references_unreadable':
                    raise RuntimeError('引用不可读')
                return ''
            if args == ('-s', 'Anchors'):
                return anchor if state['rules'] else ''
            if args[-2:] == ('-s', 'Anchors'):
                return 'foreign' if case == 'children' else ''
            if args[-1] == '-sr':
                return state['rules']
            raise AssertionError(args)
        def fake_run(args, allowed=(0,)):
            commands.append(args)
            if '-R' in args and '-n' not in args:
                state['root'] = original
            if '-F' in args:
                assert args == ['/sbin/pfctl', '-a', anchor, '-F', 'rules']
                state['rules'] = ''
            return subprocess.CompletedProcess(args, 0, '', '')
        def fake_process(args, **kwargs):
            assert args[:2] == ['/bin/launchctl', 'print']
            state['prints'] += 1
            alive = case == 'service_stuck' or case == 'service_exiting' and state['prints'] < 4
            return subprocess.CompletedProcess(args, 0 if alive else 1, '', '')
        with patch.object(rescue, 'ROOT', root), patch.object(rescue.os, 'geteuid', return_value=0), patch.object(rescue, 'pf', side_effect=fake_pf), patch.object(rescue, 'run', side_effect=fake_run), patch.object(rescue.subprocess, 'run', side_effect=fake_process), patch.object(rescue.time, 'sleep'), contextlib.redirect_stdout(io.StringIO()):
            try:
                rescue.main()
                success = True
            except RuntimeError:
                success = False
        assert success == (case in ('attached', 'detached', 'no_record', 'references_unreadable', 'service_exiting')), case
        assert not any('-X' in cmd or '-d' in cmd or '-k' in cmd for cmd in commands), case
        if case in ('changed_root', 'changed_rules', 'children', 'service_stuck', 'takeover_pending'):
            assert not any('-R' in cmd or '-F' in cmd for cmd in commands), case
        if success:
            assert state['root'] == original and state['rules'] == '', case
        count += 1
print(f'RESULT normal_network_rescue_scenarios={count} failures=0 kernelWrites=0')
