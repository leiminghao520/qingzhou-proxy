import sys
import runpy
from types import SimpleNamespace
from unittest.mock import Mock

import pytest
import privileged_helper as helper


def test_status_generation_and_subprocess_arguments(monkeypatch):
    process=Mock(return_value=SimpleNamespace(returncode=0,stdout='active\n',stderr=''))
    monkeypatch.setattr(helper.subprocess,'run',process)
    result=helper.status()
    assert result['ok'] and result['generation']=='active'
    assert process.call_args.args[0][-2:]==['--property=InvocationID','--value']
    process.return_value=SimpleNamespace(returncode=1,stdout='inactive\n',stderr='')
    assert helper.status()['generation'] is None


def test_root_only_allowlist_and_reload_failure(monkeypatch,capsys):
    monkeypatch.setattr(helper.os,'geteuid',lambda:1000)
    with pytest.raises(SystemExit):helper.main()
    monkeypatch.setattr(helper.os,'geteuid',lambda:0)
    monkeypatch.setattr(sys,'argv',['helper'])
    with pytest.raises(SystemExit):helper.main()
    monkeypatch.setattr(sys,'argv',['helper','rollback'])
    with pytest.raises(SystemExit):helper.main()
    monkeypatch.setattr(sys,'argv',['helper','status'])
    monkeypatch.setattr(helper,'run',lambda *a:SimpleNamespace(returncode=0,stdout='active\n'))
    helper.main();assert '"ok": true' in capsys.readouterr().out
    monkeypatch.setattr(sys,'argv',['helper','reload'])
    helper.main();assert '"ok": true' in capsys.readouterr().out
    monkeypatch.setattr(helper,'run',lambda *a:SimpleNamespace(returncode=1,stdout=''))
    with pytest.raises(RuntimeError,match='validation'):helper.main()
    results=iter([SimpleNamespace(returncode=0),SimpleNamespace(returncode=1)])
    monkeypatch.setattr(helper,'run',lambda *a:next(results))
    with pytest.raises(RuntimeError,match='reload'):helper.main()


def test_cli_failure_returns_nonzero(monkeypatch,capsys):
    monkeypatch.setattr(helper.os,'geteuid',lambda:0)
    monkeypatch.setattr(sys,'argv',['helper','reload'])
    monkeypatch.setattr(helper.subprocess,'run',lambda *a,**kw:SimpleNamespace(returncode=1,stdout='',stderr=''))
    with pytest.raises(SystemExit) as error:runpy.run_module('privileged_helper',run_name='__main__')
    assert error.value.code==1 and 'validation failed' in capsys.readouterr().err
