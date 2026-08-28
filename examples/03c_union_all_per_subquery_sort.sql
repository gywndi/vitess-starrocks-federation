-- 03b의 우회법: 바깥쪽에 ORDER BY를 걸지 말고, 각 서브쿼리(괄호) 안에서 개별적으로
-- ORDER BY/LIMIT을 건다. 각 정렬이 자기 백엔드(MySQL/StarRocks)로 완전히
-- push-down되고, 바깥 UNION ALL은 단순 concat이라 VTGate가 크로스 소스 병합
-- 정렬(weight_string 필요)을 할 필요가 없어져서 에러가 안 난다.
--
-- 주의: 결과는 "각 블록 내부만 정렬"된 상태다(예: MySQL 행들 정렬 → StarRocks 행들
-- 정렬 → 두 블록을 이어붙임) — 두 소스를 뒤섞어 전체를 하나로 정렬한 게 아니다.
-- 진짜 전역 정렬이 필요하면 애플리케이션에서 최종 병합해야 한다(03b 참고).
--
-- 실행: mysql -h 127.0.0.1 -P 25306 -u root < examples/03c_union_all_per_subquery_sort.sql

(SELECT id, customer, amount, 'live(MySQL)' AS tier FROM mysql_ks.orders ORDER BY id LIMIT 10)
UNION ALL
(SELECT id, customer, amount, 'archive(StarRocks)' AS tier FROM sr_ks.orders_archive ORDER BY id LIMIT 10);
