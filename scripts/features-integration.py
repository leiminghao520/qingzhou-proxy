#!/usr/bin/env python3
import http.server,json,pathlib,secrets,socket,subprocess,threading,time,urllib.request,urllib.error
ROOT=pathlib.Path(__file__).resolve().parent.parent
CORE=ROOT/'Vendor/sing-box';CHECKS=ROOT/'.build/debug/QingzhouChecks'

def port():
    with socket.socket() as s:s.bind(('127.0.0.1',0));return s.getsockname()[1]
def write(path,value):
    path.write_text(json.dumps(value) if not isinstance(value,str) else value);path.chmod(0o600)
def stop(process):
    if process.poll() is None:
        process.terminate()
        try:process.wait(timeout=4)
        except subprocess.TimeoutExpired:process.kill();process.wait()
def wait(p,process):
    for _ in range(100):
        if process.poll() is not None:raise RuntimeError('测试核心提前退出，请查看测试日志')
        try:
            with socket.create_connection(('127.0.0.1',p),.1):return
        except OSError:time.sleep(.05)
    raise RuntimeError('监听超时')
class Origin(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        if not self.path.startswith('/stream'):self.send_header('Content-Length','19')
        self.end_headers()
        try:
            if self.path.startswith('/stream'):
                for _ in range(300):self.wfile.write(b'QINGZHOU_STREAM\n'*100);self.wfile.flush();time.sleep(.2)
            else:self.wfile.write(b'QINGZHOU_FORWARD_OK')
        except (BrokenPipeError,ConnectionResetError):pass
    def log_message(self,*args):pass

def main():
    d=ROOT/'.build/features';d.mkdir(parents=True,exist_ok=True);d.chmod(0o700)
    origin=http.server.ThreadingHTTPServer(('127.0.0.1',0),Origin);threading.Thread(target=origin.serve_forever,daemon=True).start()
    a,b,dead,mixed,api,hung=[port() for _ in range(6)]
    stalled=socket.socket();stalled.bind(("127.0.0.1",hung));stalled.listen(30);held=[]
    def accept_stalled():
        while True:
            try:connection,_=stalled.accept();held.append(connection)
            except OSError:return
    threading.Thread(target=accept_stalled,daemon=True).start();secret=secrets.token_hex(32)
    context={'port':api,'secret':secret};write(d/'context.json',context)
    gateway={'log':{'level':'info'},'inbounds':[{'type':'shadowsocks','tag':tag,'listen':'127.0.0.1','listen_port':p,'method':'aes-128-gcm','password':'controlled-password'} for tag,p in [('gateway-a',a),('gateway-b',b)]],'outbounds':[{'type':'direct','tag':'direct'}]}
    write(d/'gateway.json',gateway)
    yaml='proxies:\n'+''.join(f'  - {{name: {name}, type: ss, server: 127.0.0.1, port: {p}, cipher: aes-128-gcm, password: controlled-password}}\n' for name,p in [('A',a),('B',b),('Dead',dead),('Hung',hung)])+'proxy-groups:\n  - {name: Manual, type: select, proxies: [A, B]}\nrules:\n  - DOMAIN,reject.test,REJECT\n  - MATCH,Manual\n'
    write(d/'profile.yaml',yaml)
    subprocess.run([str(CHECKS),'v02-config',str(d/'profile.yaml'),str(d/'client.json'),str(mixed),str(d/'context.json'),str(d/'fixture.json'),'global'],check=True)
    fixture=json.loads((d/'fixture.json').read_text());tags=['node-'+x.lower() for x in fixture['nodes']]
    processes=[];streams=[];logs=[];scenarios=[]
    def passed(name):scenarios.append(name);print('PASS FeatureRouting.'+name,flush=True)
    def api_request(path,method='GET',body=None,auth=True):
        request=urllib.request.Request(f'http://127.0.0.1:{api}'+path,data=json.dumps(body).encode() if body is not None else None,method=method,headers={'Authorization':'Bearer '+secret,'Content-Type':'application/json'} if auth else {})
        with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request,timeout=10) as response:return response.read()
    def count(tag):return (d/'gateway.log').read_text().count('inbound/shadowsocks['+tag+']')
    def request(host='127.0.0.1'):
        return subprocess.run(['curl','--silent','--show-error','--fail','--max-time','8','--noproxy','','--proxy',f'http://127.0.0.1:{mixed}',f'http://{host}:{origin.server_port}/probe'],capture_output=True)
    try:
        for name in ['gateway','client']:
            subprocess.run([str(CORE),'check','-c',str(d/(name+'.json'))],check=True,capture_output=True)
            log=open(d/(name+'.log'),'wb');logs.append(log);p=subprocess.Popen([str(CORE),'run','-c',str(d/(name+'.json'))],stdout=log,stderr=log);processes.append(p);wait(a if name=='gateway' else mixed,p)
        try:api_request('/proxies',auth=False);raise AssertionError('无密钥访问成功')
        except urllib.error.HTTPError as error:assert error.code==401
        passed('noAuthenticationRejected')
        for tag,gateway_tag in zip(tags[:2],['gateway-a','gateway-b']):
            api_request('/proxies/proxy','PUT',{'name':tag});before=count(gateway_tag);result=request();assert result.returncode==0 and result.stdout==b'QINGZHOU_FORWARD_OK',(result.returncode,result.stdout,result.stderr);assert count(gateway_tag)>before;passed('hotSelectionRoutesThrough'+gateway_tag)
        api_request('/configs','PATCH',{'mode':'direct'});before=(count('gateway-a'),count('gateway-b'));assert request().returncode==0;assert before==(count('gateway-a'),count('gateway-b'));passed('directModeBypassesGateways')
        api_request('/configs','PATCH',{'mode':'rule'});assert request('reject.test').returncode!=0;passed('ruleDomainRejects')
        before=(count('gateway-a'),count('gateway-b'));assert request().returncode==0;assert before==(count('gateway-a'),count('gateway-b'));passed('rulePrivateAddressDirect')
        api_request('/configs','PATCH',{'mode':'global'})
        for i in range(2):streams.append(subprocess.Popen(['curl','--silent','--max-time','60','--noproxy','','--proxy',f'http://127.0.0.1:{mixed}',f'http://127.0.0.1:{origin.server_port}/stream{i}'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL))
        time.sleep(1)
        subprocess.run([str(CHECKS),'api-checks',str(d/'context.json'),str(d/'fixture.json')],check=True,timeout=50)
        passed('nativeAPIBehavior')
        api_request('/proxies/proxy','PUT',{'name':tags[2]});assert request().returncode!=0;passed('failedSelectionDoesNotFallbackDirect')
    finally:
        for p in streams+processes:stop(p)
        for log in logs:log.close()
        origin.shutdown();stalled.close()
        for connection in held:connection.close()
        for name in ['context.json','client.json','gateway.json','profile.yaml','fixture.json']:(d/name).unlink(missing_ok=True)
    print('RESULT feature_routing_scenarios='+str(len(scenarios))+' failures=0')
if __name__=='__main__':main()
