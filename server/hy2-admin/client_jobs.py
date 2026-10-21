"""采集联动展示数据，附加采集失败不干扰认证和代理。"""
import json
import os
import shutil
import socket
import ssl
import time
from datetime import datetime, timezone, timedelta
from pathlib import Path
from client_api import rollup, SCHEMA


def store(conn, key, value):
    conn.execute('INSERT OR REPLACE INTO client_cache VALUES(?,?,?)',(key,json.dumps(value),int(time.time())))
    conn.commit()


def refresh_local(conn):
    conn.executescript(SCHEMA)
    rollup(conn)
    from helper import OperationsHelper
    from config import HELPER_PATH, SERVER_NAME
    try:
        status = OperationsHelper(HELPER_PATH).call('status')
        status = {k:status.get(k,'unknown') for k in ['hysteria','auth','nginx']}
    except Exception: status = {k:'unknown' for k in ['hysteria','auth','nginx']}
    try:
        context = ssl.create_default_context()
        with socket.create_connection(('127.0.0.1',443),timeout=2) as raw:
            with context.wrap_socket(raw,server_hostname=SERVER_NAME) as sock:
                status['certificate_expires'] = int(ssl.cert_time_to_seconds(sock.getpeercert()['notAfter']))
    except Exception: status['certificate_expires'] = None
    try:
        mem = dict(line.split(':',1) for line in Path('/proc/meminfo').read_text().splitlines())
        disk = shutil.disk_usage('/')
        status['resources'] = {'load':os.getloadavg()[0], 'memory_available':int(mem['MemAvailable'].split()[0])*1024,
                               'disk_free':disk.free}
    except (OSError,ValueError,KeyError): status['resources'] = None
    store(conn,'status',status)


def fetch_billing(config, clients):
    """只查询明确绑定资源；共享套餐与设备统计不合并。"""
    kind = config.get('resource_type') or ('lighthouse' if config['instance_id'].startswith('lhins-') else 'cvm')
    if kind not in ('lighthouse', 'cvm'):
        raise ValueError('unsupported_cloud_resource')
    instance = clients[kind]('DescribeInstances',{'InstanceIds':[config['instance_id']]})['InstanceSet']
    if len(instance)!=1: raise ValueError('bound_instance_not_found')
    info=instance[0]
    if kind=='lighthouse' and info.get('InstanceId')!=config['instance_id']:
        raise ValueError('bound_instance_identity_mismatch')
    result={'source':'tencent_cloud','resource_type':kind,'instance_id':config['instance_id'],
            'charge_type':info.get('InternetAccessible',{}).get('InternetChargeType'),
            'expires':info.get('ExpiredTime'),'packages':[],'bills':[],'settlement_delayed':True}
    resources={config['instance_id']}
    if kind == 'lighthouse':
        # 轻量实例使用专属套餐接口，返回字节值；不能套用 CVM 的 EIP 或共享套餐接口。
        page=clients['lighthouse']('DescribeInstancesTrafficPackages',{'InstanceIds':[config['instance_id']]})
        matches=[item for item in page.get('InstanceTrafficPackageSet',[]) if item.get('InstanceId')==config['instance_id']]
        if len(matches)!=1:
            raise ValueError('bound_traffic_package_not_found')
        for p in matches[0].get('TrafficPackageSet',[]):
            def gb(value):
                return None if value is None else value / 1073741824
            result['packages'].append({'id':p.get('TrafficPackageId'),'scope':'instance_package','unit':'GiB',
                'total_gb':gb(p.get('TrafficPackageTotal')),'remaining_gb':gb(p.get('TrafficPackageRemaining')),
                'total_bytes':p.get('TrafficPackageTotal'),'remaining_bytes':p.get('TrafficPackageRemaining'),
                'used_bytes':p.get('TrafficUsed'),'overflow_bytes':p.get('TrafficOverflow'),
                'cycle':str(p.get('StartTime',''))+'/'+str(p.get('EndTime','')),
                'expires':p.get('Deadline'),'status':p.get('Status')})
    else:
        # EIP 由实例关联查询，禁止读取后直接汇总整个账号的费用。
        addresses=clients['vpc']('DescribeAddresses',{'Filters':[{'Name':'instance-id','Values':[config['instance_id']]}]}).get('AddressSet',[])
        resources.update(a['AddressId'] for a in addresses)
    for package_id in config.get('package_ids',[]) if kind=='cvm' else []:
        packages=clients['vpc']('DescribeTrafficPackages',{'TrafficPackageIds':[package_id]}).get('TrafficPackageSet',[])
        details=[];offset=0
        while True:
            page=clients['vpc']('DescribeSpecificTrafficPackageUsedDetails',{'TrafficPackageId':package_id,'Limit':100,'Offset':offset})
            items=page.get('UsedDetailSet',[]);details.extend(items);offset+=len(items)
            if not items or offset>=int(page.get('TotalCount',0)):break
            if offset>=10000:raise ValueError('package_page_limit')
        matching=[d for d in details if d.get('ResourceId') in resources]
        if not matching: continue
        for p in packages:
            # 套餐接口提供当前 GB 值；抵扣明细中的字节余量是历史值，不可冒充当前余量。
            exact=max(matching,key=lambda d:d.get('Time') or '')
            result['packages'].append({'id':package_id,'scope':'shared_package',
                'total_gb':p.get('TotalAmount'),'remaining_gb':p.get('RemainingAmount'),
                'last_bound_deduction_at':exact.get('Time'),
                'last_bound_deduction_bytes':(exact.get('Deduction') or {}).get('Value'),
                'cycle':str(p.get('CreatedTime',''))+'/'+str(p.get('Deadline','')),
                'expires':p.get('Deadline')})
    for resource in sorted(resources):
        offset=0
        while True:
            page=clients['billing']('DescribeBillDetail',{'Month':(datetime.now(timezone.utc)+timedelta(hours=8)).strftime('%Y-%m'),
                'ResourceId':resource,'Offset':offset,'Limit':100,'NeedRecordNum':1})
            items=page.get('DetailSet',[])
            for item in items:
                if item.get('ResourceId')!=resource: continue
                clean={k:item.get(k) for k in ['ResourceId','BusinessCodeName','PayModeName']}
                clean['ComponentSet']=[{k:c.get(k) for k in ['ComponentCodeName','UsedAmount','UsedAmountUnit','RealCost']} for c in item.get('ComponentSet',[])]
                result['bills'].append(clean)
            offset+=len(items)
            if not items or offset>=int(page.get('Total',0)): break
            if offset>=10000: raise ValueError('billing_page_limit')
    return result


def cloud_main(conn):
    # 独立定时任务读取受限环境；不将云密钥写入数据库或输出。
    if not os.environ.get('HY2_CLOUD_INSTANCE_ID'):
        store(conn,'billing',{'configured':False}); return
    from tencentcloud.common import credential
    from tencentcloud.common.profile.client_profile import ClientProfile
    from tencentcloud.common.profile.http_profile import HttpProfile
    from tencentcloud.cvm.v20170312 import cvm_client,models as cvm_models
    from tencentcloud.vpc.v20170312 import vpc_client,models as vpc_models
    from tencentcloud.billing.v20180709 import billing_client,models as billing_models
    from tencentcloud.lighthouse.v20200324 import lighthouse_client,models as lighthouse_models
    cred=credential.DefaultCredentialProvider().get_credential()
    region=os.environ['HY2_CLOUD_REGION']; profile=ClientProfile(httpProfile=HttpProfile(reqTimeout=5))
    clients={}
    for name,cls,models in [('cvm',cvm_client.CvmClient,cvm_models),('vpc',vpc_client.VpcClient,vpc_models),('billing',billing_client.BillingClient,billing_models),('lighthouse',lighthouse_client.LighthouseClient,lighthouse_models)]:
        client=cls(cred,region,profile)
        def invoke(action,payload,client=client,models=models):
            req=getattr(models,action+'Request')(); req.from_json_string(json.dumps(payload))
            return json.loads(getattr(client,action)(req).to_json_string())
        clients[name]=invoke
    result=fetch_billing({'instance_id':os.environ['HY2_CLOUD_INSTANCE_ID'],
                          'resource_type':os.environ.get('HY2_CLOUD_RESOURCE_TYPE'),
                          'package_ids':os.environ.get('HY2_CLOUD_PACKAGE_IDS','').split(',') if os.environ.get('HY2_CLOUD_PACKAGE_IDS') else []},clients)
    result['configured']=True
    store(conn,'billing',result)


if __name__=='__main__':
    from db import connect
    from config import DATABASE
    with connect(DATABASE) as conn:
        conn.executescript(SCHEMA)
        try: cloud_main(conn)
        except Exception:
            # 保留上次有效账单及原时间，客户端据此显示过期，不能更新为零费用。
            raise SystemExit('云账单查询失败；保留旧数据，请检查授权与资源绑定')
