-- ⚠️ 실패 사례: 반대 방향(StarRocks가 SELECT 소스)은 단일 SQL문으로 안 된다.
-- VTGate가 SELECT 소스 쪽에 `LOCK IN SHARE MODE`를 무조건 붙이는데(하드코딩, 우회 불가 —
-- go/vt/vtgate/planbuilder/operators/insert.go의 insertSelectPlan 참고), StarRocks의
-- SQL 파서가 이 구문 자체를 모른다: "Unexpected input 'lock' ... select ... lock in share mode"
-- 실행: mysql -h 127.0.0.1 -P 25306 -u root < examples/04b_insert_select_starrocks_to_mysql_FAILS.sql

INSERT INTO mysql_ks.sr_import (id, name)
SELECT id, name FROM sr_ks.vitess_test_tbl;

-- 해법: 단일 SQL문 대신 애플리케이션에서 SELECT 후 INSERT를 분리 실행할 것.
-- 같은 세션(같은 커넥션) 안에서 두 단계로 나누면 정상 동작한다 — sync_on_demand.py 참고.
