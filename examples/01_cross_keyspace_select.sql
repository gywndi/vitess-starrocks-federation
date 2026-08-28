-- 하나의 세션에서 두 키스페이스(MySQL/StarRocks)를 각각 조회
-- 실행: mysql -h 127.0.0.1 -P 25306 -u root < examples/01_cross_keyspace_select.sql

USE mysql_ks;
SELECT id, customer, amount FROM orders;

USE sr_ks;
SELECT id, name FROM vitess_test_tbl;
