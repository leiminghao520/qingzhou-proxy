import socket,struct,threading,http.server,tempfile,pathlib,json,subprocess,time,contextlib
R=pathlib.Path(__file__).resolve().parent.parent
queries=[]
remote_queries=[]
remote_dns=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);remote_dns.bind(('127.0.0.1',0));remote_dns.settimeout(.3)
dns=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);dns.bind(('127.0.0.1',0));dns.settimeout(.3)
closed=threading.Event()
def serve_dns(server,record):
 while not closed.is_set():
  try: packet,address=server.recvfrom(4096)
  except socket.timeout:continue
  except OSError:return
  i=12;labels=[]
  while packet[i]:
   n=packet[i];labels.append(packet[i+1:i+1+n].decode());i+=n+1
  i+=1;kind,cls=struct.unpack('!HH',packet[i:i+4]);name='.'.join(labels);record.append((name,kind));question=packet[12:i+4]
  data=(socket.inet_aton('127.0.0.1') if kind==1 else socket.inet_pton(socket.AF_INET6,'2001:db8::1'))
  records=b'' if name=='only-v6.test' and kind==1 else b'\xc0\x0c'+struct.pack('!HHIH',kind,1,30,len(data))+data
  reply=packet[:2]+struct.pack('!HHHHH',0x8180,1,bool(records),0,0)+question+records
  if name=="blocked.corp.test":reply=packet[:2]+struct.pack("!HHHHH",0x8182,1,0,0,0)+question
  server.sendto(reply,address)
threading.Thread(target=serve_dns,args=(dns,queries),daemon=True).start()
threading.Thread(target=serve_dns,args=(remote_dns,remote_queries),daemon=True).start()
class Origin(http.server.BaseHTTPRequestHandler):
 def do_GET(self):
  data=b'IPv4-FORWARD-OK';self.send_response(200);self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
 def log_message(self,*args):pass
origin=http.server.ThreadingHTTPServer(('127.0.0.1',0),Origin);threading.Thread(target=origin.serve_forever,daemon=True).start()
with tempfile.TemporaryDirectory(prefix='qz-runtime-') as folder:
 d=pathlib.Path(folder);source=d/'node.txt';source.write_text('hy2://synthetic@127.0.0.1:19999')
 with socket.socket() as reserve:reserve.bind(('127.0.0.1',0));port=reserve.getsockname()[1]
 config=d/'core.json';subprocess.run([str(R/'.build/debug/QingzhouChecks'),'config',str(source),str(config),str(port),'rules','https-dns'],check=True,stdout=subprocess.DEVNULL)
 obj=json.loads(config.read_text());obj['outbounds']=[{'type':'direct','tag':'proxy','domain_resolver':{'server':'remote','strategy':'ipv4_only'}},next(item for item in obj['outbounds'] if item['tag']=='direct')]
 obj['dns']['servers']=[{'type':'udp','tag':tag,'server':'127.0.0.1','server_port':(dns if tag=='local' else remote_dns).getsockname()[1]} for tag in ['local','remote']]
 config.write_text(json.dumps(obj));config.chmod(0o600)
 with (d/'core.log').open('w') as log:
  core=subprocess.Popen([str(R/'Vendor/sing-box'),'run','-c',str(config)],stdout=log,stderr=log)
  try:
   for _ in range(60):
    try:
     with socket.create_connection(('127.0.0.1',port),.1):break
    except OSError:time.sleep(.05)
   if core.poll() is not None:
    log.flush();raise RuntimeError((d/'core.log').read_text())
   def request(host):return subprocess.run(['curl','-sS','--fail','--max-time','3','--noproxy','','--proxy',f'http://127.0.0.1:{port}',f'http://{host}:{origin.server_port}/'],capture_output=True)
   direct=request('direct.test');assert direct.returncode==0,direct.stderr
   assert any(q[0]=='direct.test' for q in queries),queries
   assert not any(q[0]=='direct.test' for q in remote_queries),remote_queries
   proxied=request('proxy.test');assert proxied.returncode==0,proxied.stderr
   assert any(q[0]=='proxy.test' for q in remote_queries),remote_queries
   assert not any(q[0]=='proxy.test' for q in queries),queries
   blocked=request('blocked.corp.test');assert blocked.returncode!=0,'corporate DNS failure must fail closed'
   assert any(q[0]=='blocked.corp.test' for q in queries),queries
   assert not any(q[0]=='blocked.corp.test' for q in remote_queries),remote_queries
   print('PASS runtime.corporateDNSFailureDoesNotFallBackToPublic')
   good=request('dual.test');assert good.returncode==0 and good.stdout==b'IPv4-FORWARD-OK',(good.returncode,good.stderr)
   bad=request('only-v6.test');assert bad.returncode!=0,'AAAA-only silently accepted'
   literal=request('[2001:db8::1]');assert literal.returncode!=0,'IPv6 literal silently accepted'
   assert remote_queries and all(q[1]==1 for q in queries+remote_queries),(queries,remote_queries)
   print('PASS runtime.directDomainUsesLocalDNSOnly')
   print('PASS runtime.proxyDomainUsesRemoteDNSOnly')
   print('PASS runtime.dualStackDNSUsesAOnly')
   print('PASS runtime.AAAAOnlyRejected')
   print('PASS runtime.IPv6LiteralRejected')
   print('RESULT runtime_network_scenarios=6 failures=0')
  finally:
   core.terminate();core.wait(timeout=5)
closed.set();dns.close();remote_dns.close();origin.shutdown();origin.server_close()
