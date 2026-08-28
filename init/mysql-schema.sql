-- mysql_ks(샤딩/OLTP 대역 시뮬레이션) 샘플 데이터
CREATE TABLE IF NOT EXISTS orders (
  id BIGINT PRIMARY KEY,
  customer VARCHAR(50),
  amount DECIMAL(10,2)
);
-- id를 sr_ks.vitess_test_tbl(1, 2)과 일부러 겹치게 잡았다 — 02번 JOIN 예제가 바로 결과를 보여준다.
INSERT INTO orders VALUES (1, 'carol', 50.00), (2, 'dave', 20.00)
  ON DUPLICATE KEY UPDATE customer = VALUES(customer);

CREATE TABLE IF NOT EXISTS sr_import (
  id BIGINT PRIMARY KEY,
  name VARCHAR(100)
);
