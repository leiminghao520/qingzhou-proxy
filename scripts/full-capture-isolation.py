from pathlib import Path
import http.server,json,socket,struct,subprocess,tempfile,threading,time
ROOT=Path(__file__).resolve().parent.parent
CORE=ROOT/'Vendor/sing-box'
def port():
 with socket.socket() as s:s.bind(('127.0.0.1',0));return s.getsockname()[1]
def stop(p):
 if p.poll() is None:
  p.terminate()
  try:p.wait(timeout=3)
  except subprocess.TimeoutExpired:p.kill();p.wait()
def wait(number,p):
 for _ in range(100):
  if p.poll() is not None:raise RuntimeError('核心提前退出')
  try:
   with socket.create_connection(('127.0.0.1',number),.1):return
  except OSError:time.sleep(.05)
 raise RuntimeError('核心未就绪')
class Origin(http.server.BaseHTTPRequestHandler):
 def do_GET(self):
  data=b'FULL_CAPTURE_OK';self.send_response(200);self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
 def log_message(self,*args):pass
closed=threading.Event();queries={'local':[],'remote':[]};sockets={};processes=[]
def dns(name,s):
 while not closed.is_set():
  try:packet,peer=s.recvfrom(4096)
  except socket.timeout:continue
  except OSError:return
  at=12;labels=[]
  while packet[at]:
   size=packet[at];labels.append(packet[at+1:at+1+size].decode());at+=size+1
  at+=1;kind=struct.unpack('!H',packet[at:at+2])[0];queries[name].append('.'.join(labels))
  address=socket.inet_aton('127.0.0.1') if kind==1 else socket.inet_pton(socket.AF_INET6,'::1')
  record=b'\xc0\x0c'+struct.pack('!HHIH',kind,1,30,len(address))+address
  s.sendto(packet[:2]+struct.pack('!HHHHH',0x8180,1,1,0,0)+packet[12:at+4]+record,peer)
origin=http.server.ThreadingHTTPServer(('127.0.0.1',0),Origin);threading.Thread(target=origin.serve_forever,daemon=True).start()
try:
 with tempfile.TemporaryDirectory(prefix='qz-fullcapture-') as folder:
  target=Path(folder);target.chmod(0o700)
  ports={name:port() for name in ['server','core','control','http','gateway']}
  for name in queries:
   s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.bind(('127.0.0.1',0));s.settimeout(.2);sockets[name]=s;ports[name+'DNS']=s.getsockname()[1];threading.Thread(target=dns,args=(name,s),daemon=True).start()
  subprocess.run([str(ROOT/'.build/debug/QingzhouChecks'),'full-capture-fixture',folder,json.dumps(ports)],check=True)
  (target/'server.json').write_text(json.dumps({'log':{'level':'info'},'inbounds':[{'type':'shadowsocks','listen':'127.0.0.1','listen_port':ports['server'],'method':'aes-128-gcm','password':'synthetic'}],'outbounds':[{'type':'direct','tag':'direct'}],'route':{'final':'direct'}}))
  with (target/'server.log').open('wb') as serverlog,(target/'core.log').open('wb') as corelog:
   try:
    for name,log in [('server',serverlog),('core',corelog)]:
     subprocess.run([str(CORE),'check','-c',str(target/(name+'.json'))],check=True,capture_output=True)
     p=subprocess.Popen([str(CORE),'run','-c',str(target/(name+'.json'))],stdout=log,stderr=log);processes.append(p);wait(ports[name],p)
    gateway=subprocess.Popen([str(ROOT/'.build/httpcompat/qzhttp')],stdin=subprocess.PIPE,stdout=corelog,stderr=corelog);processes.append(gateway)
    gateway.stdin.write((target/'gateway.json').read_bytes());gateway.stdin.close();wait(ports['gateway'],gateway)
    entry=ports['core']
    def request(host,protocol):
     option='--proxy' if protocol=='HTTP' else '--socks5-hostname';proxy=f'http://127.0.0.1:{entry}' if protocol=='HTTP' else f'127.0.0.1:{entry}'
     return subprocess.run(['curl','--silent','--show-error','--fail','--max-time','3','--noproxy','',option,proxy,f'http://{host}:{origin.server_port}/'],capture_output=True)
    def count():return (target/'server.log').read_text().count('inbound connection to')
    for entrance in ['core','gateway']:
     entry=ports[entrance]
     for protocol in ['HTTP','SOCKS']:
      for host,proxied in [('baidu.com',False),('foreign.test',True),('qq.com',True),('override.test',False)]:
       before=count();r=request(host,protocol);time.sleep(.05)
       assert r.returncode==0 and r.stdout==b'FULL_CAPTURE_OK',(entrance,protocol,host,r.stderr)
       assert (count()>before)==proxied,(entrance,protocol,host,count(),before)
       print('PASS',entrance,protocol,host,'proxy' if proxied else 'direct',flush=True)
    assert 'baidu.com' in queries['local'] and 'baidu.com' not in queries['remote'],queries
    assert all(h in queries['remote'] for h in ['foreign.test','qq.com']),queries
    print('PASS DNS.localDomesticAndRemoteProxy',flush=True)
    stop(processes[0]);r=request('foreign.test','HTTP');assert r.returncode!=0
    print('PASS NodeFailure.noSilentDirectFallback',flush=True)
    r=request('baidu.com','HTTP');assert r.returncode==0 and r.stdout==b'FULL_CAPTURE_OK'
    print('PASS NodeFailure.domesticDirectUnaffected',flush=True)
    print('RESULT full_capture_isolated_scenarios=19 failures=0',flush=True)
   except BaseException:
    print((target/'core.log').read_text()[-4000:]);print((target/'server.log').read_text()[-2000:]);raise
   finally:
    for p in reversed(processes):stop(p)
finally:
 closed.set()
 for s in sockets.values():s.close()
 origin.shutdown();origin.server_close()
