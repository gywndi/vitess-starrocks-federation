-- ⚠️ 실패 사례: 위 03번에 ORDER BY만 추가하면 깨진다.
-- VTGate가 크로스 소스 병합 정렬을 위해 각 소스 쿼리에 weight_string()을 주입하는데
-- StarRocks에는 이 함수가 없다: "No matching function with signature: weight_string(bigint(20))"
-- 실행: mysql -h 127.0.0.1 -P 25306 -u root < examples/03b_union_all_order_by_FAILS.sql

SELECT id, customer, amount, 'live(MySQL)' AS tier FROM mysql_ks.orders
UNION ALL
SELECT id, customer, amount, 'archive(StarRocks)' AS tier FROM sr_ks.orders_archive
ORDER BY id;

-- 해법: ORDER BY를 빼고 받아온 뒤 애플리케이션(클라이언트 코드)에서 정렬할 것.
