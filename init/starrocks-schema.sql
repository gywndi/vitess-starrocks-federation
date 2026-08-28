/* sr_ks(분석/아카이브 대역 시뮬레이션) 샘플 데이터 —
   StarRocks는 stdin 멀티 스테이트먼트 배치의 첫 줄이 대시 두 개짜리 줄 주석이면 문법 에러를 낸다
   (mysql client -e로 단일 문장 실행할 땐 문제없음) — 그래서 이 파일은 블록 주석으로 시작한다. */
CREATE TABLE IF NOT EXISTS vitess_test_tbl (
  id BIGINT,
  name VARCHAR(100)
) DUPLICATE KEY(id) DISTRIBUTED BY HASH(id) BUCKETS 1;
INSERT INTO vitess_test_tbl VALUES (1, 'hello-from-starrocks'), (2, 'via-vitess');

CREATE TABLE IF NOT EXISTS orders_archive (
  id BIGINT,
  customer VARCHAR(50),
  amount DECIMAL(10,2)
) DUPLICATE KEY(id) DISTRIBUTED BY HASH(id) BUCKETS 4;
INSERT INTO orders_archive VALUES (1, 'old-alice', 12.50), (2, 'old-bob', 33.00);
