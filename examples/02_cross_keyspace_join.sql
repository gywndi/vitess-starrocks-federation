-- 키스페이스 간 JOIN — VTGate가 각 키스페이스에서 읽어와 자기 레이어에서 조인한다.
-- 실행: mysql -h 127.0.0.1 -P 25306 -u root < examples/02_cross_keyspace_join.sql

SELECT o.id, o.customer, o.amount, s.name AS sr_name
FROM mysql_ks.orders o
JOIN sr_ks.vitess_test_tbl s ON o.id = s.id;
