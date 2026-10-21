from pathlib import Path
import http.server,json,socket,struct,subprocess,tempfile,threading,time,os,select
ROOT=Path(__file__).resolve().parent.parent

def port():
    with socket.socket() as s:s.bind(('127.0.0.1',0));return s.getsockname()[1]
def stop(p):
    if p.poll() is None:
        p.terminate()
        try:p.wait(timeout=4)
        except subprocess.TimeoutExpired:p.kill();p.wait()
def wait(port,p):
    for _ in range(100):
        if p.poll() is not None:raise RuntimeError('隔离组件提前退出')
        try:
            with socket.create_connection(('127.0.0.1',port),.1):return
        except OSError:time.sleep(.03)
    raise RuntimeError('隔离监听未就绪')
class Origin(http.server.BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def do_GET(self):
        data=b'DYNAMIC_VPN_OK';self.send_response(200);self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
    def log_message(self,*args):pass
origin=http.server.ThreadingHTTPServer(('127.0.0.1',0),Origin)
threading.Thread(target=origin.serve_forever,daemon=True).start()
processes=[]
try:
    for initiallyCorporate in [False,True]:
        with tempfile.TemporaryDirectory(prefix='qz-dynamic-vpn-') as folder:
            path=Path(folder);ports={name:port() for name in ['server','core','control']};ports['initialCorporate']=int(initiallyCorporate)
            with (path/'fixture.log').open('w') as fixturelog,(path/'core.log').open('w') as corelog,(path/'server.log').open('w') as serverlog:
                fixture=subprocess.Popen([str(ROOT/'.build/network-monitor-checks'),'--dynamic-fixture',folder,json.dumps(ports)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=fixturelog,text=True,bufsize=1);processes.append(fixture)
                def read():
                    if not select.select([fixture.stdout],[],[],10)[0]:raise RuntimeError('监控夹具超时')
                    line=fixture.stdout.readline().strip()
                    if not line:raise RuntimeError('监控夹具退出：'+(path/'fixture.log').read_text())
                    return line
                assert read()=='READY'
                server={'inbounds':[{'type':'shadowsocks','listen':'127.0.0.1','listen_port':ports['server'],'method':'aes-128-gcm','password':'synthetic'}],'outbounds':[{'type':'direct'}]}
                (path/'server.json').write_text(json.dumps(server))
                for name,log in [('server',serverlog),('core',corelog)]:
                    checked=subprocess.run([str(ROOT/'Vendor/sing-box'),'check','-c',str(path/(name+'.json'))],capture_output=True,text=True)
                    if checked.returncode:raise RuntimeError(checked.stderr)
                    p=subprocess.Popen([str(ROOT/'Vendor/sing-box'),'run','-c',str(path/(name+'.json'))],stdout=log,stderr=log);processes.append(p);wait(ports[name],p)
                core=processes[-1];pid=core.pid
                def command(value):
                    fixture.stdin.write(value+'\n');fixture.stdin.flush();state=read()
                    assert 'starts=0 stops=0' in state,state
                    return state
                def request(name):
                    return subprocess.run(['/usr/bin/curl','--silent','--show-error','--fail','--max-time','2','--noproxy','','--proxy',f'http://127.0.0.1:{ports["core"]}',f'http://{name}:{origin.server_port}/'],capture_output=True)
                # 保留经过核心的 SOCKS 长连接，所有更新期间同一个 TCP 通道持续可用。
                stream=socket.create_connection(('127.0.0.1',ports['core']),2);stream.settimeout(3)
                stream.sendall(b'\x05\x01\x00');assert stream.recv(2)==b'\x05\x00'
                stream.sendall(b'\x05\x01\x00\x01'+socket.inet_aton('127.0.0.1')+struct.pack('!H',origin.server_port))
                response=stream.recv(32);assert response[1]==0
                buffer=b''
                def stream_request():
                    global buffer
                    stream.sendall(b'GET / HTTP/1.1\r\nHost: stream.test\r\nConnection: keep-alive\r\n\r\n')
                    while b'\r\n\r\n' not in buffer:buffer+=stream.recv(4096)
                    headers,buffer=buffer.split(b'\r\n\r\n',1)
                    length=int(next(line.split(b':',1)[1] for line in headers.split(b'\r\n') if line.lower().startswith(b'content-length:')))
                    while len(buffer)<length:buffer+=stream.recv(4096)
                    body,buffer=buffer[:length],buffer[length:];assert body==b'DYNAMIC_VPN_OK'
                backgroundStop=threading.Event();failures=[];publicCount=[0]
                def traffic():
                    while not backgroundStop.is_set():
                        r=request('public.test')
                        if r.returncode or r.stdout!=b'DYNAMIC_VPN_OK':failures.append(r.stderr.decode())
                        publicCount[0]+=1;time.sleep(.03)
                thread=threading.Thread(target=traffic,daemon=True);thread.start()
                if initiallyCorporate:
                    assert request('initial.corp.test').stdout==b'DYNAMIC_VPN_OK'
                    print('PASS enterprise_vpn_before_core_start',flush=True)
                else:
                    assert request('offline.private.test').returncode!=0
                    print('PASS offline_corporate_dns_does_not_block_public',flush=True)
                stream_request()
                for order in [('dns','up'),('route','up'),('up',)]:
                    for event in order:
                        state=command(event);stream_request()
                        if event=='dns':
                            time.sleep(.15)
                            assert request('pending.corp.test').returncode!=0
                            assert request('public.test').stdout==b'DYNAMIC_VPN_OK'
                            print('PASS dns_first_pauses_only_corporate_queries',flush=True)
                    command('tick')
                    for retry in range(40):
                        r=request(f'up{retry}.corp.test')
                        if r.returncode==0:break
                        time.sleep(.05)
                    assert r.returncode==0 and r.stdout==b'DYNAMIC_VPN_OK',(r.stderr,(path/'core.log').read_text()[-2000:])
                    stream_request();print('PASS hot_vpn_attach_'+order[0],flush=True)
                    command('down');command('tick');time.sleep(.15)
                    assert request('gone.corp.test').returncode!=0
                    stream_request();print('PASS hot_vpn_detach_preserves_stream',flush=True)
                command('interface');command('tick');time.sleep(.15)
                assert request('renumbered.corp.test').stdout==b'DYNAMIC_VPN_OK'
                stream_request();print('PASS interface_number_changes_without_restart',flush=True)
                command('refuse')
                assert request('unavailable.corp.test').returncode!=0
                stream_request();assert request('public.test').stdout==b'DYNAMIC_VPN_OK'
                command('recover');assert request('recovered.corp.test').stdout==b'DYNAMIC_VPN_OK'
                print('PASS corporate_dns_failure_is_local_and_recovers',flush=True)
                soak=float(os.environ.get('QZ_DYNAMIC_SOAK_SECONDS','0'))
                until=time.monotonic()+soak;nextChange=time.monotonic();changes=0
                while time.monotonic()<until:
                    if time.monotonic()>=nextChange:
                        command('down' if changes%2==0 else 'up');command('tick');changes+=1;nextChange=time.monotonic()+2
                    stream_request();time.sleep(.05)
                if soak:print('PASS sustained_dynamic_updates seconds='+str(soak)+' changes='+str(changes),flush=True)
                backgroundStop.set();thread.join(timeout=5)
                assert not failures,failures
                assert publicCount[0]>0 and core.poll() is None and core.pid==pid
                records=(path/'queries.log').read_text().splitlines()
                corporate=[line for line in records if '.corp.test' in line]
                assert corporate and all('10.20.0.53@utun6' in line or '10.20.0.53@utun7' in line for line in corporate),corporate
                assert 'reload rule-set' not in (path/'core.log').read_text(),(path/'core.log').read_text()[-2000:]
                stream.close();print('RESULT dynamic_vpn_live_sequences=3 public_requests='+str(publicCount[0])+' public_failures=0 stream_reconnects=0 core_restarts=0 dns_leaks=0',flush=True)
                fixture.stdin.write('stop\n');fixture.stdin.flush();read()
                for process in reversed(processes):stop(process)
                processes.clear()
except Exception:
    try:
        print('CORE_LOG', (path/'core.log').read_text()[-4000:],flush=True)
    except Exception:pass
    raise
finally:
    for p in reversed(processes):stop(p)
    origin.shutdown();origin.server_close()
