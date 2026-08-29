#!/bin/bash
# MySQL이 outer(드라이빙)일 때와 StarRocks가 outer일 때 크로스 키스페이스 JOIN
# 성능을 직접 실측한다. docs/FINDINGS.md의 "JOIN 방향별 성능 실측" 절 참고.
#
# 방법: id가 겹치는 합성 데이터를 mysql_ks.orders / sr_ks.vitess_test_tbl 양쪽에
# 채워 넣고, WHERE id <= N으로 outer 쪽 행 수(N)를 조절하며 같은 조인을
# FROM 절 순서만 바꿔서 반복 실행 -> 벽시계 시간을 비교한다.
#
# 주의: 이 repo가 쓰는 vitess/lite:latest(25.0.0-SNAPSHOT 개발 빌드)는 짧은 시간에
# 수백 건 이상의 순차 gRPC 호출(nested loop join의 inner 반복 쿼리)이 몰리면
# Go 런타임 레벨 fatal error로 죽는 경우가 있었다(로컬 docker 환경, 리소스 제약
# 때문일 수 있음). 그래서 기본 N은 150까지만 돈다 - 더 큰 값을 시도할 거면
# 먼저 `docker-compose ps`로 컨테이너가 살아있는지 확인해가며 조금씩 올릴 것.
#
# 실행: ./examples/05_join_direction_benchmark.sh

set -e
MYSQL="mysql -h 127.0.0.1 -P 25306 -u root -N -B"

echo "== 합성 데이터 적재 (양쪽에 id 1..2002 겹치게) =="
python3 -c "
N = 2000
vals_o = ','.join(f\"({i},'cust{i}',{i%100}.50)\" for i in range(3, N+3))
print(f'INSERT INTO orders (id, customer, amount) VALUES {vals_o};')
" | mysql -h 127.0.0.1 -P 23306 -u root -pvitesstest123 vt_mysql_ks 2>/dev/null || true

python3 -c "
N = 2000
vals_s = ','.join(f\"({i},'sr-name-{i}')\" for i in range(3, N+3))
print(f'INSERT INTO vitess_test_tbl (id, name) VALUES {vals_s};')
" | mysql -h 127.0.0.1 -P 29030 -u root -pvitesstest123 vt_sr_ks 2>/dev/null || true

echo "== 벤치마크 실행 (각 N에 대해 mysql-outer / starrocks-outer 3회씩) =="

run() {
  local label="$1" sql="$2"
  local start=$(python3 -c 'import time; print(time.time())')
  local rows
  rows=$($MYSQL -e "$sql" 2>/tmp/bench_err.log | wc -l | tr -d ' ')
  local end=$(python3 -c 'import time; print(time.time())')
  if [ -s /tmp/bench_err.log ]; then
    echo "  $label -> ERROR: $(cat /tmp/bench_err.log)"
  else
    python3 -c "print(f'  $label -> {$end-$start:.3f}s (rows=$rows)')"
  fi
}

for N in 30 60 100 150; do
  echo "--- N=$N ---"
  for rep in 1 2 3; do
    run "mysql-outer     rep$rep" \
      "SELECT o.id, o.customer, o.amount, s.name FROM mysql_ks.orders o JOIN sr_ks.vitess_test_tbl s ON o.id = s.id WHERE o.id <= $((N+2));"
  done
  for rep in 1 2 3; do
    run "starrocks-outer rep$rep" \
      "SELECT s.id, s.name, o.customer, o.amount FROM sr_ks.vitess_test_tbl s JOIN mysql_ks.orders o ON s.id = o.id WHERE s.id <= $((N+2));"
  done
done
