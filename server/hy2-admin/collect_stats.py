from config import DATABASE, STATS_SECRET, STATS_URL, HELPER_PATH
from db import connect, init_db, purge_old_data
from helper import fetch_stats, OperationsHelper
from devices import retry_kicks
from metrics import record_sample

def main():
    init_db(DATABASE)
    conn = connect(DATABASE)
    try:
        retry_kicks(conn, STATS_URL, STATS_SECRET)
        try:
            before = OperationsHelper(HELPER_PATH).call('status').get('generation')
            traffic, online = fetch_stats(STATS_URL, STATS_SECRET, timeout=3)
            after = OperationsHelper(HELPER_PATH).call('status').get('generation')
            if not before or before != after:
                raise RuntimeError('service restarted during collection')
            record_sample(conn, traffic, online, after)
        except Exception:
            conn.rollback()
            record_sample(conn, None, None, None)
        from client_jobs import refresh_local
        refresh_local(conn)
        purge_old_data(conn, 180)
        conn.commit()
    finally:
        conn.close()

if __name__ == "__main__": main()
