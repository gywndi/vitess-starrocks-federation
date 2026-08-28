#!/bin/bash
# docker-compose up -d 이후 실행하는 1회성 초기화 스크립트.
#
# vttablet은 etcd에 cell/keyspace가 이미 있어야 정상 기동한다 — docker-compose가
# 모든 서비스를 거의 동시에 띄우기 때문에 vttablet 컨테이너들은 최초 기동 시
# "cell이 없다"며 죽어버린다(정상). 그래서 이 스크립트는 cell/keyspace부터 먼저
# 만들고, 그 다음 vttablet을 재시작하는 순서로 짰다.
#
# 사용법: docker-compose up -d 로 전체 기동 후, ./init.sh 실행

set -euo pipefail

echo "== StarRocks 기동 대기 (재실행 시 이미 비밀번호가 설정돼 있을 수 있음 — 둘 다 시도) =="
until mysql -h 127.0.0.1 -P 29030 -u root -e "SELECT 1;" >/dev/null 2>&1 \
   || mysql -h 127.0.0.1 -P 29030 -u root -pvitesstest123 -e "SELECT 1;" >/dev/null 2>&1; do
  sleep 2
done

echo "== StarRocks 초기화: root 비밀번호 + sql_mode + DB 생성 (idempotent) =="
if mysql -h 127.0.0.1 -P 29030 -u root -pvitesstest123 -e "SELECT 1;" >/dev/null 2>&1; then
  echo "  이미 초기화됨 (재실행) — 비밀번호 설정 스킵"
else
  mysql -h 127.0.0.1 -P 29030 -u root -e "SET PASSWORD FOR 'root' = PASSWORD('vitesstest123');"
fi
mysql -h 127.0.0.1 -P 29030 -u root -pvitesstest123 -e "
  SET GLOBAL sql_mode = 'STRICT_TRANS_TABLES';
  CREATE DATABASE IF NOT EXISTS vt_sr_ks;
"

echo "== MySQL 기동 대기 =="
until docker-compose exec -T mysql-standalone mysqladmin ping -uroot -pvitesstest123 >/dev/null 2>&1; do sleep 2; done

echo "== vtctld 기동 대기 =="
until docker-compose exec -T vtctld vtctldclient --server localhost:15999 GetCellInfoNames >/dev/null 2>&1; do sleep 2; done

echo "== Vitess 토폴로지: cell 등록 (vttablet보다 먼저 있어야 함) =="
docker-compose exec -T vtctld vtctldclient --server localhost:15999 AddCellInfo --root /vitess/global/zone1 --server-address etcd:2379 zone1 2>&1 | grep -v "already exists" || true

echo "== Vitess 토폴로지: keyspace 생성 =="
docker-compose exec -T vtctld vtctldclient --server localhost:15999 CreateKeyspace mysql_ks 2>&1 | grep -v "already exists" || true
docker-compose exec -T vtctld vtctldclient --server localhost:15999 CreateKeyspace sr_ks 2>&1 | grep -v "already exists" || true

echo "== vttablet 재시작 (cell/keyspace가 이제 있으니 정상 기동해야 함) =="
docker-compose restart vttablet-mysql vttablet-sr

echo "== vttablet 자체 등록 대기 (GetTablets에 두 개 다 나올 때까지) =="
for i in $(seq 1 30); do
  COUNT=$(docker-compose exec -T vtctld vtctldclient --server localhost:15999 GetTablets 2>/dev/null | wc -l | tr -d ' ')
  if [ "$COUNT" -ge 2 ]; then
    echo "  등록 완료 (tablet ${COUNT}개 확인)"
    break
  fi
  echo "  대기 중... (${i}/30, 현재 ${COUNT}개)"
  sleep 3
done

echo "== 두 tablet을 PRIMARY로 승격 (unmanaged라 자동 reparent가 없음) =="
docker-compose exec -T vtctld vtctldclient --server localhost:15999 TabletExternallyReparented zone1-0000000200
docker-compose exec -T vtctld vtctldclient --server localhost:15999 TabletExternallyReparented zone1-0000000100

echo "== vtgate 재시작 (cell/keyspace가 없던 시점에 먼저 떠서 빈 상태로 캐싱했을 수 있음) =="
docker-compose restart vtgate
until mysql -h 127.0.0.1 -P 25306 -u root -e "SELECT 1;" >/dev/null 2>&1; do sleep 2; done
sleep 5  # 태블릿 헬스체크가 vtgate에 반영될 시간

echo "== 샘플 스키마/데이터 적재 =="
mysql -h 127.0.0.1 -P 23306 -u root -pvitesstest123 vt_mysql_ks < init/mysql-schema.sql
mysql -h 127.0.0.1 -P 29030 -u root -pvitesstest123 vt_sr_ks < init/starrocks-schema.sql

echo ""
echo "완료. VTGate 접속: mysql -h 127.0.0.1 -P 25306 -u root"
echo "examples/ 디렉토리의 쿼리들을 그대로 실행해보면 된다."
