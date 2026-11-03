"""Minute samples. Missing observations stay unknown rather than becoming zero."""
from datetime import datetime, timedelta, timezone


def utcnow():
    return datetime.now(timezone.utc).replace(tzinfo=None, microsecond=0)


def record_sample(conn, traffic, online, generation, captured_at=None):
    now = captured_at or utcnow()
    stamp = now.strftime('%Y-%m-%d %H:%M:00')
    conn.execute('BEGIN IMMEDIATE')
    previous = conn.execute('SELECT * FROM metric_samples ORDER BY captured_at DESC LIMIT 1').fetchone()
    if previous and stamp <= previous['captured_at']:
        conn.rollback()
        return
    ok = traffic is not None and online is not None and bool(generation)
    continuous = bool(ok and previous and previous['ok'] and previous['generation'] == generation
                      and (now - datetime.fromisoformat(previous['captured_at'])).total_seconds() <= 150)
    sid = conn.execute('INSERT INTO metric_samples(captured_at,generation,ok,complete) VALUES(?,?,?,?)',
                       (stamp, generation, ok, continuous)).lastrowid
    if ok:
        for device in conn.execute('SELECT id,auth_id FROM devices').fetchall():
            values = traffic.get(device['auth_id'], {'tx': 0, 'rx': 0})
            tx, rx = values['tx'], values['rx']
            count = online.get(device['auth_id'], 0)
            old = conn.execute('SELECT * FROM device_samples WHERE sample_id=? AND device_id=?',
                               (previous['id'] if previous else -1, device['id'])).fetchone()
            valid = continuous and old is not None and tx >= old['tx'] and rx >= old['rx']
            dx, dr = (tx-old['tx'], rx-old['rx']) if valid else (None, None)
            conn.execute('INSERT INTO device_samples VALUES(?,?,?,?,?,?,?)', (sid, device['id'], tx, rx, count, dx, dr))
            if not valid:
                conn.execute('UPDATE metric_samples SET complete=0 WHERE id=?', (sid,))
            if count:
                conn.execute('UPDATE devices SET last_online_at=? WHERE id=?', (stamp, device['id']))
    conn.commit()


def overview(conn, period='24h', user_id=None, device_id=None, now=None):
    now = now or utcnow()
    days = {'24h': 1, '7d': 7, '30d': 30}.get(period, 1)
    since = (now-timedelta(days=days)).strftime('%Y-%m-%d %H:%M:%S')
    today = (now+timedelta(hours=8)).replace(hour=0, minute=0, second=0)-timedelta(hours=8)
    where, params = '', []
    if user_id is not None:
        where += ' AND d.user_id=?'; params.append(user_id)
    if device_id is not None:
        where += ' AND d.id=?'; params.append(device_id)
    latest = conn.execute('SELECT * FROM metric_samples ORDER BY captured_at DESC LIMIT 1').fetchone()
    latest_ok = conn.execute('SELECT captured_at FROM metric_samples WHERE ok=1 ORDER BY captured_at DESC LIMIT 1').fetchone()
    fresh = bool(latest and latest['ok'] and (now-datetime.fromisoformat(latest['captured_at'])).total_seconds() <= 150)
    total = conn.execute('SELECT SUM(s.delta_tx) tx,SUM(s.delta_rx) rx FROM device_samples s '
                         'JOIN devices d ON d.id=s.device_id JOIN metric_samples m ON m.id=s.sample_id '
                         'WHERE m.captured_at>=?'+where, [today.strftime('%Y-%m-%d %H:%M:%S')]+params).fetchone()
    instances = None
    if fresh:
        instances = conn.execute('SELECT COALESCE(SUM(s.online),0) FROM device_samples s JOIN devices d ON d.id=s.device_id '
                                 'WHERE s.sample_id=?'+where, [latest['id']]+params).fetchone()[0]
    bucket = '%Y-%m-%d %H:00' if days == 1 else '%Y-%m-%d'
    rows = conn.execute("SELECT strftime(?,m.captured_at,'+8 hours') label, SUM(s.delta_tx) tx,SUM(s.delta_rx) rx, "
                        'MIN(CASE WHEN s.delta_tx IS NULL OR m.complete=0 THEN 0 ELSE 1 END) complete '
                        'FROM metric_samples m LEFT JOIN device_samples s ON s.sample_id=m.id '
                        'LEFT JOIN devices d ON d.id=s.device_id WHERE m.captured_at>=?'+where+
                        ' GROUP BY label ORDER BY label', [bucket, since]+params).fetchall()
    start = now-timedelta(days=days)+timedelta(hours=8)
    end = now+timedelta(hours=8)
    start = start.replace(minute=0,second=0,microsecond=0) if days == 1 else start.replace(hour=0,minute=0,second=0,microsecond=0)
    by_label = {r['label']:dict(r) for r in rows}
    points = []
    while start <= end:
        label = start.strftime(bucket)
        points.append(by_label.get(label, {'label':label,'tx':None,'rx':None,'complete':0}))
        start += timedelta(hours=1) if days == 1 else timedelta(days=1)
    return {'period': period, 'tx':total['tx'], 'rx':total['rx'], 'online':instances,
            'fresh':fresh, 'captured_at':latest_ok['captured_at'] if latest_ok else None,
            'complete':bool(fresh and points and all(p['complete'] for p in points)), 'points':points}


def device_usage(conn, device_id):
    return dict(conn.execute('SELECT SUM(delta_tx) tx,SUM(delta_rx) rx FROM device_samples WHERE device_id=?',
                             (device_id,)).fetchone())
