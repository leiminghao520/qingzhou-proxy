#!/usr/bin/env python3
import json,pathlib,socket,subprocess,sys,tempfile,time,os,signal
root=pathlib.Path(__file__).resolve().parent.parent
runner=root/'.build/debug/QingzhouRunner';core=root/'Vendor/sing-box'
with tempfile.TemporaryDirectory(prefix='qingzhou-supervisor-') as tmp:
    d=pathlib.Path(tmp)
    with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
    config=d/'runtime.json';config.write_text(json.dumps({'inbounds':[{'type':'mixed','listen':'127.0.0.1','listen_port':port}],'outbounds':[{'type':'direct'}]}));config.chmod(0o600)
    info=d/'pid.txt'
    parent_code="import subprocess,pathlib,time,sys; p=subprocess.Popen(sys.argv[1:4]+['run','-c',sys.argv[4]],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL);pathlib.Path(sys.argv[5]).write_text(str(p.pid));time.sleep(60)"
    # 子父进程仅用于模拟主应用被强制结束。
    parent_code="import subprocess,pathlib,time,sys;p=subprocess.Popen([sys.argv[1],sys.argv[2],'run','-c',sys.argv[3]],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL);pathlib.Path(sys.argv[4]).write_text(str(p.pid));time.sleep(60)"
    parent=subprocess.Popen([sys.executable,'-c',parent_code,str(runner),str(core),str(config),str(info)])
    try:
        for _ in range(80):
            try:
                with socket.create_connection(('127.0.0.1',port),.1):break
            except OSError:time.sleep(.05)
        else:raise RuntimeError('监护测试核心没有启动')
        wrapper_pid=int(info.read_text());result=subprocess.run(['pgrep','-P',str(wrapper_pid)],capture_output=True,text=True)
        child_pids=[int(x) for x in result.stdout.split()];assert len(child_pids)==1
        parent.kill();parent.wait(timeout=3)
        for _ in range(100):
            result=subprocess.run(['ps','-p',str(child_pids[0]),'-o','stat='],capture_output=True,text=True)
            if not result.stdout.strip() or result.stdout.strip().startswith('Z'):break
            time.sleep(.05)
        else:raise RuntimeError('父进程退出后核心仍运行')
        with socket.socket() as s:s.bind(('127.0.0.1',port))
        print('PASS SupervisorTests.parentExitStopsCoreAndReleasesPort')
    finally:
        if parent.poll() is None:parent.terminate();parent.wait(timeout=4)
print('RESULT supervisor_failures=0')
