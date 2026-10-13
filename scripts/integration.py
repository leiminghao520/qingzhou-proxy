#!/usr/bin/env python3
import contextlib,http.server,json,os,pathlib,socket,ssl,subprocess,tempfile,threading,time,urllib.parse,uuid
ROOT=pathlib.Path(__file__).resolve().parent.parent
CORE=ROOT/'Vendor/sing-box'
CHECKS=ROOT/'.build/debug/QingzhouChecks'
RESULTS=[]
def reserve(udp=False):
    with socket.socket(socket.AF_INET,socket.SOCK_DGRAM if udp else socket.SOCK_STREAM) as s:s.bind(('127.0.0.1',0));return s.getsockname()[1]
def write(path,value):
    path.write_text(json.dumps(value) if not isinstance(value,str) else value);path.chmod(0o600)
def start(config,path,log):
    write(path,config)
    check=subprocess.run([str(CORE),'check','-c',str(path)],capture_output=True)
    if check.returncode:raise RuntimeError('核心配置校验失败：'+check.stderr.decode()[:1000])
    return subprocess.Popen([str(CORE),'run','-c',str(path)],stdout=log,stderr=log)
def stop(p):
    if p.poll() is None:
        p.terminate()
        try:p.wait(timeout=4)
        except subprocess.TimeoutExpired:p.kill();p.wait()
def wait_port(port,process):
    for _ in range(80):
        if process.poll() is not None:
            log=ROOT/'.build/integration/server.log'
            detail=log.read_text()[-1200:] if log.exists() else ''
            raise RuntimeError('测试核心提前退出：'+detail)
        try:
            with socket.create_connection(('127.0.0.1',port),.2):return
        except OSError:time.sleep(.05)
    raise RuntimeError('测试监听启动超时')
class Origin(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body=b'QINGZHOU_FORWARD_OK'
        self.send_response(200);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
    def log_message(self,*args):pass
def request(url,port,cert):
    return subprocess.run(['curl','--fail','--silent','--show-error','--max-time','12','--noproxy','','--proxy',f'http://127.0.0.1:{port}','--cacert',str(cert),url],capture_output=True)
def passed(name):RESULTS.append(name);print('PASS',name,flush=True)
with contextlib.nullcontext(str(ROOT/'.build/integration')) as tmp:
    d=pathlib.Path(tmp);d.mkdir(parents=True,exist_ok=True);d.chmod(0o700);cert=d/'cert.pem';key=d/'key.pem'
    subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(key),'-out',str(cert),'-days','1','-subj','/CN=localhost','-addext','subjectAltName=DNS:localhost,IP:127.0.0.1'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True);key.chmod(0o600)
    origin_http=http.server.ThreadingHTTPServer(('127.0.0.1',0),Origin);origin_https=http.server.ThreadingHTTPServer(('127.0.0.1',0),Origin)
    tls=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);tls.load_cert_chain(cert,key);origin_https.socket=tls.wrap_socket(origin_https.socket,server_side=True)
    for server in [origin_http,origin_https]:threading.Thread(target=server.serve_forever,daemon=True).start()
    ports={kind:reserve(kind=='hysteria2') for kind in ['hysteria2','shadowsocks','trojan','vless','vless-ws']}
    secret='controlled-test-password';obfs='controlled-obfs';vid=str(uuid.uuid4())
    tls_config={'enabled':True,'server_name':'localhost','certificate_path':str(cert),'key_path':str(key)}
    inbounds=[
        {'type':'hysteria2','tag':'hy2-server','listen':'127.0.0.1','listen_port':ports['hysteria2'],'users':[{'name':'test','password':secret}],'obfs':{'type':'salamander','password':obfs},'tls':tls_config},
        {'type':'shadowsocks','tag':'ss-server','listen':'127.0.0.1','listen_port':ports['shadowsocks'],'method':'aes-128-gcm','password':secret},
        {'type':'trojan','tag':'trojan-server','listen':'127.0.0.1','listen_port':ports['trojan'],'users':[{'name':'test','password':secret}],'tls':tls_config},
        {'type':'vless','tag':'vless-server','listen':'127.0.0.1','listen_port':ports['vless'],'users':[{'name':'test','uuid':vid}],'tls':tls_config},
        {'type':'vless','tag':'vless-ws-server','listen':'127.0.0.1','listen_port':ports['vless-ws'],'users':[{'name':'test','uuid':vid}],'tls':tls_config,'transport':{'type':'ws','path':'/ws'}}]
    gateway={'log':{'level':'info','timestamp':True},'inbounds':inbounds,'outbounds':[{'type':'direct','tag':'direct'}],'route':{'final':'direct'}}
    uris={
        'hysteria2':f'hy2://{secret}@127.0.0.1:{ports["hysteria2"]}/?sni=localhost&obfs=salamander&obfs-password={obfs}',
        'shadowsocks':f'ss://aes-128-gcm:{secret}@127.0.0.1:{ports["shadowsocks"]}',
        'trojan':f'trojan://{secret}@127.0.0.1:{ports["trojan"]}?sni=localhost',
        'vless':f'vless://{vid}@127.0.0.1:{ports["vless"]}?security=tls&sni=localhost',
        'vless-ws':f'vless://{vid}@127.0.0.1:{ports["vless-ws"]}?security=tls&sni=localhost&type=ws&path=%2Fws'}
    gateway_log=open(d/'server.log','wb');gateway_process=start(gateway,d/'server.json',gateway_log)
    clients=[]
    try:
        wait_port(ports['shadowsocks'],gateway_process)
        for kind,uri in uris.items():
            uri_path=d/'node.txt';write(uri_path,uri);client_file=d/(kind+'.json');local_port=reserve()
            subprocess.run([str(CHECKS),'config',str(uri_path),str(client_file),str(local_port)],stdout=subprocess.DEVNULL,check=True)
            config=json.loads(client_file.read_text())
            if 'tls' in config['outbounds'][0]:config['outbounds'][0]['tls']['certificate_path']=str(cert)
            log=open(d/(kind+'.log'),'wb');client=start(config,client_file,log);clients.append(client);wait_port(local_port,client)
            try:
                for protocol,origin in [('http',origin_http),('https',origin_https)]:
                    result=request(f'{protocol}://127.0.0.1:{origin.server_port}/probe',local_port,cert)
                    if result.returncode or result.stdout!=b'QINGZHOU_FORWARD_OK':raise RuntimeError(kind+' '+protocol+' 实际转发失败：'+result.stderr.decode()[:500])
                    passed(kind+'.'+protocol)
            finally:stop(client);log.close()
        # 证书验证错误必须导致连接失败。
        local_port=reserve();write(d/'node.txt',uris['trojan']);bad_file=d/'bad-tls.json'
        subprocess.run([str(CHECKS),'config',str(d/'node.txt'),str(bad_file),str(local_port)],stdout=subprocess.DEVNULL,check=True)
        log=open(d/'bad-tls.log','wb');bad=start(json.loads(bad_file.read_text()),bad_file,log);clients.append(bad);wait_port(local_port,bad)
        assert request(f'http://127.0.0.1:{origin_http.server_port}/',local_port,cert).returncode!=0
        passed('tls.untrustedCertificateRejected');stop(bad);log.close()
        # 在网关停止后验证私网直连，并验证域名拒绝规则。
        stop(gateway_process)
        local_port=reserve();write(d/'node.txt',uris['shadowsocks']);rules_file=d/'rules.json'
        subprocess.run([str(CHECKS),'config',str(d/'node.txt'),str(rules_file),str(local_port),'rules'],stdout=subprocess.DEVNULL,check=True)
        log=open(d/'rules.log','wb');client=start(json.loads(rules_file.read_text()),rules_file,log);clients.append(client);wait_port(local_port,client)
        result=request(f'http://127.0.0.1:{origin_http.server_port}/direct',local_port,cert);assert result.returncode==0 and result.stdout==b'QINGZHOU_FORWARD_OK';passed('rules.privateDirectWithGatewayStopped')
        result=request(f'http://reject.test:{origin_http.server_port}/',local_port,cert);assert result.returncode!=0;passed('rules.domainReject')
        stop(client);log.close()
        assert b'inbound/hysteria2[hy2-server]' in (d/'server.log').read_bytes()
        passed('server.observedHysteria2Traffic')
    finally:
        for p in clients:stop(p)
        stop(gateway_process);gateway_log.close()
        origin_http.shutdown();origin_https.shutdown()
print('RESULT integration_scenarios='+str(len(RESULTS))+' failures=0')
