from pathlib import Path
import contextlib,http.server,json,socket,ssl,struct,subprocess,tempfile,threading,time,os
ROOT=Path(__file__).resolve().parent.parent
CORE=ROOT/'Vendor/sing-box'
def reserve():
 with socket.socket() as sock:sock.bind(('127.0.0.1',0));return sock.getsockname()[1]
def stop(process):
 if process.poll() is None:
  process.terminate()
  try:process.wait(timeout=4)
  except subprocess.TimeoutExpired:process.kill();process.wait()
def wait(port,process):
 for _ in range(80):
  if process.poll() is not None:raise RuntimeError('合成组件提前退出')
  try:
   with socket.create_connection(('127.0.0.1',port),.1):return
  except OSError:time.sleep(.05)
 raise RuntimeError('合成监听启动超时')
class Origin(http.server.BaseHTTPRequestHandler):
 def do_GET(self):
  self.send_response(200)
  if self.path=='/stream':
   self.send_header('Content-Type','text/event-stream');self.end_headers()
   with contextlib.suppress(BrokenPipeError,ConnectionResetError):
    for _ in range(20):self.wfile.write(b'data: synthetic\n\n');self.wfile.flush();time.sleep(.1)
  else:
   data=b'COMBINED_FORWARD_OK';self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
 def log_message(self,*args):pass

dns=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);dns.bind(('127.0.0.1',0));dns.settimeout(.2)
queries=[];closed=threading.Event()
def serve_dns():
 while not closed.is_set():
  try:packet,address=dns.recvfrom(4096)
  except socket.timeout:continue
  except OSError:return
  index=12
  while packet[index]:index+=packet[index]+1
  index+=1;kind=struct.unpack('!H',packet[index:index+2])[0];queries.append(kind)
  answer=socket.inet_aton('127.0.0.1') if kind==1 else socket.inet_pton(socket.AF_INET6,'2001:db8::1')
  record=b'\xc0\x0c'+struct.pack('!HHIH',kind,1,30,len(answer))+answer
  dns.sendto(packet[:2]+struct.pack('!HHHHH',0x8180,1,1,0,0)+packet[12:index+4]+record,address)
threading.Thread(target=serve_dns,daemon=True).start()
servers=[];processes=[]
try:
 with tempfile.TemporaryDirectory(prefix='qz-combined-') as folder:
  target=Path(folder);target.chmod(0o700)
  cert=target/'cert.pem';key=target/'key.pem'
  subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(key),'-out',str(cert),'-days','1','-subj','/CN=origin.example','-addext','subjectAltName=DNS:origin.example'],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL);key.chmod(0o600)
  origin=http.server.ThreadingHTTPServer(('127.0.0.1',0),Origin);secure=http.server.ThreadingHTTPServer(('127.0.0.1',0),Origin)
  tls=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);tls.load_cert_chain(cert,key);secure.socket=tls.wrap_socket(secure.socket,server_side=True)
  for server in [origin,secure]:servers.append(server);threading.Thread(target=server.serve_forever,daemon=True).start()
  ports={name:reserve() for name in ['server','core','http','control','gateway']};ports['dns']=dns.getsockname()[1]
  subprocess.run([str(ROOT/'.build/debug/QingzhouChecks'),'combined-fixture',str(target),json.dumps(ports)],check=True,stdout=subprocess.DEVNULL)
  (target/'server.json').write_text(json.dumps({'log':{'level':'info'},'inbounds':[{'type':'shadowsocks','listen':'127.0.0.1','listen_port':ports['server'],'method':'aes-128-gcm','password':'synthetic'}],'outbounds':[{'type':'direct','tag':'direct'}],'route':{'final':'direct'}}))
  with (target/'components.log').open('wb') as log:
   for name in ['server','core']:
    process=subprocess.Popen([str(CORE),'run','-c',str(target/(name+'.json'))],stdout=log,stderr=log);processes.append(process);wait(ports[name],process)
   gateway=subprocess.Popen([str(ROOT/'.build/httpcompat/qzhttp')],stdin=subprocess.PIPE,stdout=log,stderr=log);processes.append(gateway);
   gateway.stdin.write((target/'gateway.json').read_bytes());gateway.stdin.close();wait(ports['gateway'],gateway)
   def request(url,*extra):return subprocess.run(['curl','--silent','--show-error','--fail','--max-time','4','--noproxy','','--proxy',f'http://127.0.0.1:{ports["gateway"]}',*extra,url],capture_output=True)
   result=request(f'http://origin.example:{origin.server_port}/');assert result.returncode==0 and result.stdout==b'COMBINED_FORWARD_OK',(result.returncode,result.stderr,(target/'components.log').read_text()[-3000:]);print('PASS combined.HTTPThroughAuthenticatedPolicyAndSS')
   result=request(f'https://origin.example:{secure.server_port}/','--cacert',str(cert));assert result.returncode==0 and result.stdout==b'COMBINED_FORWARD_OK',(result.returncode,result.stderr);print('PASS combined.CONNECTTLSThroughSameCoreAndSS')
   result=request('http://rewrite.test/path','--dump-header','-');assert b'302' in result.stdout and b'https://target.test/' in result.stdout;print('PASS combined.URLRewritePreserved')
   result=request(f'http://origin.example:{origin.server_port}/stream','--max-time','0.7','--no-buffer');assert result.returncode==28 and b'data: synthetic' in result.stdout,(result.returncode,result.stdout);print('PASS combined.StreamingVisibleBeforeCancellation')
   result=request('http://[2001:db8::1]/');assert result.returncode!=0;print('PASS combined.IPv6LiteralRejected')
   assert queries and set(queries)=={1},queries;print('PASS combined.DNSUsesAOnly')
   def query_core():
    return subprocess.run(['curl','--silent','--fail','--max-time','3','--noproxy','*','--header','Authorization: Bearer '+('a'*64),f'http://127.0.0.1:{ports["control"]}/dns/query?name=cache.example&type=A'],capture_output=True)
   from concurrent.futures import ThreadPoolExecutor
   before=len(queries)
   with ThreadPoolExecutor(max_workers=8) as executor: results=list(executor.map(lambda _:query_core(),range(8)))
   assert all(result.returncode==0 and b'127.0.0.1' in result.stdout for result in results),results
   assert len(queries)-before<=1,(before,len(queries))
   print('PASS combined.ConcurrentDNSQueriesShareCoreCache')
   stop(processes[0])
   result=request(f'http://origin.example:{origin.server_port}/','--user-agent','SyntheticDirect/1');assert result.returncode==0 and result.stdout==b'COMBINED_FORWARD_OK',(result.returncode,result.stderr);print('PASS combined.UserAgentDirectAfterProxyFailure')
   result=request(f'http://origin.example:{origin.server_port}/');assert result.returncode!=0;print('PASS combined.ProxyFailureDoesNotFallbackDirect')
   print('RESULT combined_isolated_scenarios=9 failures=0')
finally:
 for process in reversed(processes):stop(process)
 for server in servers:server.shutdown();server.server_close()
 closed.set();dns.close()
