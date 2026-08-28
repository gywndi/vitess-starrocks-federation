-- hot(MySQL) + cold(StarRocks 아카이브) 데이터를 UNION ALL로 하나의 결과셋으로 병합
-- ORDER BY 없이는 정상 동작한다(정렬은 애플리케이션에서 처리할 것 — 03b 참고)
-- 실행: mysql -h 127.0.0.1 -P 25306 -u root < examples/03_union_all_archive.sql

SELECT id, customer, amount, 'live(MySQL)' AS tier FROM mysql_ks.orders
UNION ALL
SELECT id, customer, amount, 'archive(StarRocks)' AS tier FROM sr_ks.orders_archive;
