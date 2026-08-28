"""04b(StarRocks -> MySQL 단일 SQL문)이 안 되는 문제의 실전 해법.
같은 VTGate 세션 안에서 SELECT(StarRocks) -> INSERT(MySQL)를 애플리케이션 레벨에서
두 단계로 나눠 실행한다. 크론이 필요 없다 — 호출될 때 1회 실행되는 함수 형태라
'사용자가 원할 때' 트리거하는 온디맨드 동기화에 그대로 쓸 수 있다.

사전 조건: pip install pymysql
사용법: python3 sync_on_demand.py <request_id> <payload>
"""
import pymysql
import time
import sys

VTGATE_HOST = "127.0.0.1"
VTGATE_PORT = 25306


def sync_on_demand(request_id: str, payload: str):
    conn = pymysql.connect(host=VTGATE_HOST, port=VTGATE_PORT, user="root", password="", autocommit=True)
    cur = conn.cursor()

    # 1) StarRocks: 데이터 생성(또는 이미 있는 데이터를 조회)
    cur.execute("USE sr_ks")
    cur.execute(
        "INSERT INTO vitess_test_tbl VALUES (%s, %s)",
        (int(time.time()) % 1000000, f"{request_id}:{payload}"),
    )
    cur.execute("SELECT id, name FROM vitess_test_tbl ORDER BY id DESC LIMIT 1")
    new_row = cur.fetchone()
    print(f"[StarRocks] 생성됨: {new_row}")

    # 2) MySQL: 같은 세션에서 바로 반영 (upsert)
    cur.execute("USE mysql_ks")
    cur.execute(
        "INSERT INTO sr_import (id, name) VALUES (%s, %s) ON DUPLICATE KEY UPDATE name=VALUES(name)",
        new_row,
    )
    cur.execute("SELECT id, name FROM sr_import WHERE id = %s", (new_row[0],))
    confirmed = cur.fetchone()
    print(f"[MySQL] 반영 확인: {confirmed}")

    conn.close()
    return confirmed


if __name__ == "__main__":
    request_id = sys.argv[1] if len(sys.argv) > 1 else "user-request-001"
    payload = sys.argv[2] if len(sys.argv) > 2 else "온디맨드-테스트"
    result = sync_on_demand(request_id, payload)
    print(f"\n완료: {result}")
