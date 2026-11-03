"""真实双进程 Gunicorn 与隔离 HTTPS 入口检查，使用临时凭据和回环端口。"""
import concurrent.futures,json,os,secrets,socket,ssl,subprocess,sys,tempfile,time,urllib.request,urllib.error
from pathlib import Path
from cryptography.fernet import Fernet


def port():
    with socket.socket() as sock:sock.bind(('127.0.0.1',0));return sock.getsockname()[1]


def main():
    root=Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix='qingzhou-http-isolated-') as temp:
        directory=Path(temp);db=directory/'isolated.sqlite3';backend=port();front=port()
        environment=os.environ.copy();environment.update(HY2_DATABASE=str(db),HY2_SECRET_KEY=secrets.token_hex(32),HY2_ENCRYPTION_KEY=Fernet.generate_key().decode())
        os.environ.update({k:environment[k] for k in ['HY2_DATABASE','HY2_SECRET_KEY','HY2_ENCRYPTION_KEY']})
        sys.path.insert(0,str(root))
        from app import create_app
        from db import connect
        from devices import create_device,credentials
        from client_api import digest
        app=create_app();code=secrets.token_urlsafe(24)
        with connect(db) as conn:
            encrypted,password,_=credentials(app.fernet)
            uid=conn.execute('INSERT INTO proxy_users(username,display_name,role,encrypted_password,encrypted_token) VALUES(?,?,?,?,?)',('isolated','fixture','owner',encrypted,password)).lastrowid
            did=create_device(conn,app.fernet,uid,'fixture','macOS','hy2','')
            conn.execute('INSERT INTO client_pairings VALUES(?,?,?)',(digest(code),did,int(time.time())+600));conn.commit()
        subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1','-subj','/CN=127.0.0.1','-addext','subjectAltName=IP:127.0.0.1','-keyout',str(directory/'key.pem'),'-out',str(directory/'cert.pem')],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        source=(root/'deploy/nginx.conf').read_text();start=source.index('    location /api/client/v1/ {');end=source.index('\n    }',start)+6
        location=source[start:end].replace('127.0.0.1:8787','127.0.0.1:'+str(backend)).replace('include proxy_params','include /etc/nginx/proxy_params')
        config=directory/'nginx.conf'
        config.write_text(f'pid {directory}/nginx.pid;\nerror_log {directory}/nginx.log;\nevents {{worker_connections 128;}}\nhttp {{access_log off;client_body_temp_path {directory}/body;server {{listen 127.0.0.1:{front} ssl;ssl_certificate {directory}/cert.pem;ssl_certificate_key {directory}/key.pem;{location}}}}}')
        subprocess.run(['/usr/sbin/nginx','-t','-c',str(config),'-p',str(directory)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        gunicorn=subprocess.Popen([sys.executable,'-m','gunicorn','--workers','2','--bind','127.0.0.1:'+str(backend),'app:create_app()'],cwd=root,env=environment,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        nginx=subprocess.Popen(['/usr/sbin/nginx','-c',str(config),'-p',str(directory),'-g','daemon off;'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        try:
            context=ssl.create_default_context(cafile=str(directory/'cert.pem'))
            opener=urllib.request.build_opener(urllib.request.ProxyHandler({}),urllib.request.HTTPSHandler(context=context))
            def request(path,body=None,token=None,declared_size=None):
                req=urllib.request.Request(f'https://127.0.0.1:{front}/api/client/v1/'+path,data=body)
                if body is not None:req.add_header('Content-Type','application/json' if path=='pair' else 'application/octet-stream')
                if token:req.add_header('Authorization','Bearer '+token)
                if declared_size is not None:req.add_header('Content-Length',str(declared_size))
                try:
                    with opener.open(req,timeout=10) as response:return response.status,response.read()
                except urllib.error.HTTPError as error:return error.code,error.read()
            for _ in range(50):
                try:
                    if request('me')[0]==401:break
                except (OSError,urllib.error.URLError):pass
                time.sleep(.1)
            else:raise RuntimeError('隔离 HTTPS 服务未就绪')
            body=json.dumps({'code':code}).encode()
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:replies=list(pool.map(lambda _:request('pair',body),range(2)))
            assert sorted(r[0] for r in replies)==[200,401]
            token=json.loads(next(r[1] for r in replies if r[0]==200))['token']
            assert json.loads(request('me',token=token)[1])['owner'] is True
            assert request('speed/upload',b'x'*(8*1024*1024),token)[0]==200
            assert request('speed/upload',b'x',token,8*1024*1024+1)[0]==413
            assert len(request('speed/download',token=token)[1])==8*1024*1024
            assert request('speed/download',token=token)[0]==429
            assert json.loads(request('usage',token=token)[1])['retained']['upload'] is None
            print('HTTPS_ISOLATION_OK: real TLS, two workers, one-use pairing race, 8MiB upload/download, 413/429, missing usage')
        finally:
            for process in [nginx,gunicorn]:
                process.terminate()
                try:process.wait(timeout=10)
                except subprocess.TimeoutExpired:process.kill();process.wait()

if __name__=='__main__':main()
