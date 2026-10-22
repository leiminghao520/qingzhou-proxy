#!/usr/bin/env python3
import http.client,http.server,json,pathlib,socket,subprocess,tempfile,threading,time
root=pathlib.Path(__file__).resolve().parent.parent
class Target(http.server.BaseHTTPRequestHandler):
    protocol_version="HTTP/1.1"
    def do_GET(self):
        self.send_response(200);self.send_header('Content-Length','13');self.end_headers();self.wfile.write(b'BYPASS_TARGET')
    def log_message(self,*args):pass
class V6Server(http.server.ThreadingHTTPServer):address_family=socket.AF_INET6
servers=[http.server.ThreadingHTTPServer(('127.0.0.1',0),Target),V6Server(('::1',0),Target)]
for server in servers:threading.Thread(target=server.serve_forever,daemon=True).start()
def port():
    with socket.socket() as s:s.bind(('127.0.0.1',0));return s.getsockname()[1]
results=[]
try:
    with tempfile.TemporaryDirectory(prefix='qingzhou-bypass-traffic-') as temp:
        for enabled in (True,False):
            listen,control=port(),port()
            config=pathlib.Path(temp)/'config.json'
            subprocess.run([str(root/'.build/bypass-traffic-fixture'),str(config),str(listen),str(control),'enabled' if enabled else 'disabled'],check=True)
            with (pathlib.Path(temp)/'core.log').open('wb') as log:
                core=subprocess.Popen([str(root/'Vendor/sing-box'),'run','-c',str(config)],stdout=log,stderr=log)
                try:
                    for attempt in range(100):
                        try:
                            with socket.create_connection(('127.0.0.1',listen),timeout=.1):break
                        except OSError:time.sleep(.02)
                    else:raise RuntimeError('隔离核心未就绪')
                    for family,server in zip(('ipv4','ipv6'),servers):
                        target='127.0.0.1' if family=='ipv4' else '[::1]'
                        url=f'http://{target}:{server.server_port}/isolated'
                        connection=http.client.HTTPConnection('127.0.0.1',listen,timeout=3)
                        ok=False;details=None
                        try:
                            connection.request('GET',url)
                            response=connection.getresponse();body=response.read();details=(response.status,body);ok=response.status==200 and body==b'BYPASS_TARGET'
                        except (OSError,http.client.HTTPException) as error:details=str(error)
                        finally:connection.close()
                        assert ok==enabled,(family,enabled,ok,details,(pathlib.Path(temp)/'core.log').read_text())
                        results.append({'family':family,'bypassEnabled':enabled,'targetReached':ok})
                finally:core.terminate();core.wait(timeout=5)
finally:
    for server in servers:server.shutdown();server.server_close()
print(json.dumps({'assertions':len(results),'failures':0,'scope':'真实核心与回环 HTTP；未接管系统代理、TUN 或防火墙','results':results},ensure_ascii=False,indent=2))
