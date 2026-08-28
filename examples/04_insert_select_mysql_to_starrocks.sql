-- MySQL(SELECT 소스) -> StarRocks(INSERT 대상): 단일 SQL문으로 동작한다.
-- LOCK IN SHARE MODE는 VTGate가 SELECT 소스 쪽에 붙이는데, 여기선 소스가 진짜 MySQL이라 문제없다.
-- 실행: mysql -h 127.0.0.1 -P 25306 -u root < examples/04_insert_select_mysql_to_starrocks.sql

INSERT INTO sr_ks.vitess_test_tbl (id, name)
SELECT id, customer FROM mysql_ks.orders;

-- 확인
SELECT * FROM sr_ks.vitess_test_tbl ORDER BY id;
