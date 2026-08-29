# 상세 원인 분석

[README](../README.md)의 기능 매트릭스에서 왜 특정 패턴만 막히는지, 시도했지만
배제한 대안, 재현 중 겪은 이슈, 실무 권장사항을 정리한다.

## 왜 특정 패턴만 막히는가

### 1. `LOCK IN SHARE MODE` — SELECT 소스가 StarRocks일 때만

VTGate는 `INSERT INTO ... SELECT ...`를 계획할 때 SELECT 쪽에 `LOCK IN SHARE MODE`를
**무조건** 붙인다. INSERT 대상과 SELECT 소스가 같은 테이블일 수 있는 상황(자기 참조)에서
레이스 컨디션을 막기 위한 정합성 보장 장치다. 소스 코드
(`go/vt/vtgate/planbuilder/operators/insert.go`, `insertSelectPlan` 함수)에서
`sqlparser.ShareModeLock`이 **리터럴 상수로 하드코딩**돼 있다 — 세션 변수도, 쿼리
힌트(`/*vt+ ... */`)도, config 플래그도 거치지 않아서 **끌 방법이 없다**.

- SELECT 소스가 MySQL이면 문제없음(MySQL은 이 구문을 지원) → [`04`](../examples/04_insert_select_mysql_to_starrocks.sql)
- SELECT 소스가 StarRocks면 문법 에러 → [`04b`](../examples/04b_insert_select_starrocks_to_mysql_FAILS.sql)

**우회법**: 단일 SQL문 대신 애플리케이션에서 SELECT와 INSERT를 분리 실행([`sync_on_demand.py`](../examples/sync_on_demand.py)).
같은 커넥션 안에서만 하면 되고, 크론 같은 스케줄러도 필요 없다 — 그냥 호출하면 그때
한 번 실행되는 함수로 만들면 "사용자가 원할 때 데이터를 넣는" 온디맨드 패턴에 바로 쓸 수 있다.

### 2. `weight_string()` — 크로스 소스 UNION/정렬 시

여러 소스에서 모은 결과를 정확히 병합 정렬하기 위해 VTGate가 각 소스 쿼리에
`weight_string(...)`(문자열/숫자를 정렬 비교 가능한 바이트열로 바꾸는 MySQL 전용
내부 함수)을 주입한다. StarRocks에는 이 함수가 없다.

**우회법 1**: `ORDER BY` 없이 받아온 뒤 애플리케이션에서 정렬. `UNION ALL` 자체는 정상.

**우회법 2 (더 나음)**: 바깥쪽에 `ORDER BY`를 걸지 말고, 각 서브쿼리(괄호)
안에서 개별적으로 `ORDER BY`/`LIMIT`을 건다:

```sql
(SELECT ... FROM mysql_ks.orders ORDER BY id LIMIT 10)
UNION ALL
(SELECT ... FROM sr_ks.orders_archive ORDER BY id LIMIT 10);
```

각 정렬이 자기 백엔드로 완전히 push-down되고, 바깥 `UNION ALL`은 단순 concat이라
VTGate가 크로스 소스 병합 정렬을 할 필요가 없어져서 `weight_string` 에러가 안 난다
([`03c`](../examples/03c_union_all_per_subquery_sort.sql)). 다만 결과는 "각 블록
내부만 정렬"된 상태다(두 소스를 뒤섞어 전체를 하나로 정렬한 게 아님) — 진짜 전역
정렬이 필요하면 우회법 1처럼 애플리케이션에서 최종 병합해야 한다.

### 3. 사이드카(`_vt`) DB

Vitess의 모든 vttablet(managed든 unmanaged든)은 실제 DB 옆에 `_vt`라는 자체 내부
DB를 만들고 운영 정보를 저장한다 — 스키마 트래킹 캐시(`_vt.tables`), Online DDL
작업 큐(`_vt.schema_migrations`), 리샤딩/스트리밍 복제 상태(`_vt.vreplication`,
`_vt.vdiff`), 2PC 트랜잭션 복구(`_vt.redo_state`), 헬스체크용 heartbeat 등.

MySQL에서는 이 사이드카가 완벽하게 만들어진다(20개 테이블 전부). **StarRocks에서는
`_vt` DB 자체가 끝내 안 만들어진다** — vttablet이 사이드카를 셋업하며 쓰는 문법 중
일부가 StarRocks 파서에서 거부되기 때문이다(실측: `UPDATE ... LIMIT 1` 구문 에러).

다행히 Vitess 자신이 이 상황을 예상하고 있다 — 로그에 정확히 이렇게 찍힌다:

```
"Ignoring sidecardb.Init error for unmanaged tablets"
```

즉 사이드카 초기화 실패가 **쿼리 서빙 자체를 막는 치명적 에러가 아니라, unmanaged
tablet에서는 공식적으로 허용되는 상황**이다. 다만 사이드카에 의존하는 기능(위 목록)은
당연히 동작하지 않고, 백그라운드 재시도 루프가 계속 에러 로그를 남긴다.

**로그 노이즈 줄이기** (기능에는 영향 없음, `vttablet-sr` 커맨드에 이미 반영돼 있음):

```
--queryserver-config-schema-change-signal=false   # 스키마 변경 알림 비활성화
--queryserver-enable-online-ddl=false             # Online DDL 실행기 비활성화(schema_migrations 에러 제거)
--heartbeat-enable=false                          # heartbeat 쓰기 시도 비활성화
```

이 옵션들은 **StarRocks 쪽에서만** 의미가 있다 — 애초에 동작 안 하던 기능을 끄는
것뿐이라 손실이 없다. 반대로 진짜 MySQL(사이드카가 제대로 도는 백엔드)에 이 옵션을
걸면 실제로 잘 동작하던 Online DDL/정밀 헬스체크/즉시 스키마 반영 기능을 잃게 되므로
**절대 걸면 안 된다** — 이 repo의 `vttablet-mysql`은 기본값 그대로다.

## 시도했지만 배제한 대안

- **MySQL FEDERATED 엔진**: MySQL 테이블이 원격 MySQL 프로토콜 서버(StarRocks 포함)를
  직접 프록시하게 만드는 스토리지 엔진. 기술적으로는 동작을 확인했지만(StarRocks
  테이블을 FEDERATED로 잡아서 로컬 테이블처럼 SELECT/INSERT 가능), **레거시 취급받는
  기능이고 RDS/Aurora 등 매니지드 MySQL에서는 아예 지원하지 않아서** 채택하지 않았다.
- **MySQL 프로시저 / StarRocks UDF에서 원격 연결**: 둘 다 FEDERATED과 같은 범주의
  함정(엔진 내부에서 다른 엔진의 와이어 프로토콜에 직접 다이얼)에 걸린다. StarRocks는
  outbound 쓰기 기능 자체가 없고, MySQL 쪽은 커스텀 C UDF(`libmysqlclient` 사용) 정도인데
  이것도 매니지드 MySQL에서는 로드가 막힌다.
- **Vitess VReplication(MoveTables 등)으로 자동 동기화**: 사이드카 DB 문제로 애초에
  StarRocks 쪽에서 vreplication 엔진 자체가 기동 못 함.

## 크로스 키스페이스 JOIN의 실행 순서 — Nested Loop, 그리고 드라이빙 테이블은 FROM 절 순서로 결정

`VEXPLAIN PLAN`으로 실제 실행 계획을 까보면(일반 `EXPLAIN`은 `VT03031: EXPLAIN is
only supported for single keyspace`로 크로스 키스페이스 쿼리를 지원하지 않는다):

```sql
VEXPLAIN PLAN
SELECT o.id, o.customer, o.amount, s.name AS sr_name
FROM mysql_ks.orders o
JOIN sr_ks.vitess_test_tbl s ON o.id = s.id;
```

```json
{
  "OperatorType": "Join", "Variant": "Join",
  "JoinVars": { "o_id": 0 },
  "Inputs": [
    { "Keyspace": "mysql_ks", "Query": "select o.id, o.customer, o.amount from orders as o" },
    { "Keyspace": "sr_ks", "Query": "select s.`name` as sr_name from vitess_test_tbl as s where s.id = :o_id" }
  ]
}
```

- **항상 Nested Loop Join이다.** `Inputs[0]`(outer)을 필터 없이 통째로 조회한 뒤,
  그 결과의 **각 행마다** 바인드 변수(`:o_id`)를 넣어 `Inputs[1]`(inner)을 반복 쿼리한다.
  outer가 N행이면 inner에 N번 쿼리가 나간다.
- **드라이빙(outer) 테이블은 비용 기반이 아니라 SQL `FROM` 절에 먼저 쓴 테이블로 정해진다.**
  실제로 `FROM sr_ks.vitess_test_tbl s JOIN mysql_ks.orders o`로 순서만 바꿔서 다시
  `VEXPLAIN`을 돌려보면 outer/inner가 그대로 뒤집힌다 — StarRocks가 outer, MySQL이
  inner(`WHERE o.id = :s_id`)가 된다. VTGate는 두 백엔드의 행 수·인덱스 같은 실제
  통계를 갖고 있지 않아서 진짜 옵티마이저처럼 어느 쪽이 더 작은지 판단하지 못하고,
  그냥 쿼리 텍스트 순서를 따른다.

**실무 함의**: 조인 시 **행 수가 적은 쪽을 `FROM` 절 맨 앞(outer)에 직접 배치**해야
한다. 신경 안 쓰면 대용량 분석 테이블(StarRocks)이 outer가 돼서 상대 백엔드에 수백만
번 쿼리를 반복 날리는 최악의 상황이 나올 수 있다 — Vitess가 알아서 최적화해주지
않는다.

### JOIN 방향별 성능 실측 (네이티브 amd64, 2026-08-29)

"드라이빙은 FROM 절 순서" 사실 자체는 확인했지만, **outer/inner를 어느 쪽에
두느냐가 실제로 얼마나 차이 나는지**를 [`05_join_direction_benchmark.sh`](../examples/05_join_direction_benchmark.sh)와
같은 방법으로 홈랩 k8s(네이티브 amd64, [안정성 검증](#안정성-vtgate-고빈도-쿼리-부하-네이티브-amd64-검증-완료)과
동일 환경 — mysql_ks는 테스트 Pod 내 컨테이너, sr_ks는 운영 StarRocks 클러스터를
실제 클러스터 네트워크 너머로 연결)에서 재측정했다. `mysql_ks.orders`와
`sr_ks.vitess_test_tbl` 양쪽에 id가 겹치는 합성 데이터 2,000행을 채우고,
`WHERE id <= N`으로 outer 쪽 행 수(N)를 조절해가며 FROM 절 순서만 바꿔 반복
실행(각 N당 3회), 벽시계 시간을 비교했다.

| N (outer 행 수) | mysql-outer (StarRocks가 inner) | starrocks-outer (MySQL이 inner) | 배율 |
|---|---|---|---|
| 30 | 0.270s | 0.051s | 5.3배 |
| 60 | 0.476s | 0.083s | 5.7배 |
| 100 | 0.714s | 0.085s | 8.4배 |
| 150 | 1.059s | 0.061s | 17.4배 |
| 300 | 2.098s | 0.128s | 16.4배 |
| 600 | 4.090s | 0.376s | 10.9배 |
| 1,000 | 6.703s | 0.402s | 16.7배 |
| 2,000 | 13.645s | 0.886s | 15.4배 |

**StarRocks가 inner일 때가 N이 커질수록 일관되게 15~17배 더 느리다** — Mac
로컬 측정치(약 4배)보다 격차가 훨씬 크다. 구간별(N=150→2,000) 기울기로 행당
순수 inner 쿼리 비용을 역산하면:

- StarRocks가 inner일 때: 행당 약 **6.8ms** 추가
- MySQL이 inner일 때: 행당 약 **0.45ms** 추가

즉 StarRocks에 단건 point-lookup을 반복 날리는 비용이 MySQL 대비 **약 15배**
비싸다. StarRocks는 컬럼형 OLAP 엔진이라 한 건짜리 쿼리도 FE 파싱/플래닝
오버헤드를 매번 지불하는 반면, MySQL은 PK 인덱스 point-lookup에 특화된 OLTP
엔진이라 반복 호출 비용이 훨씬 싸다는 동일한 이유지만, 이 환경에서는 sr_ks가
실제 클러스터 네트워크(파드→서비스 홉)를 타는 반면 mysql_ks는 테스트 Pod 안에
동거하는 컨테이너라 왕복이 사실상 로컬이었다 — 그런데도 격차가 이만큼 벌어졌다는
건 네트워크 홉보다 StarRocks FE 자체의 반복 호출 오버헤드가 지배적이라는 뜻으로
읽힌다. (반대로 mysql_ks가 같은 파드 안이라 유리했던 만큼, "실제 운영 환경처럼
MySQL도 별도 네트워크 홉을 타면" mysql-outer 절대 시간은 더 늘어날 수 있다 —
다만 두 방향의 상대적 배율에는 큰 영향이 없을 것으로 본다.)

**실무 사용 가능 여부**: **StarRocks를 outer, MySQL을 inner로 둔 방향은
2,000행 크로스 키스페이스 JOIN이 1초 이내(0.89s)**로 끝나 대시보드/리포트성
쿼리에는 실사용 가능한 수준이다. 반대로 **StarRocks가 inner인 방향은 같은
2,000행에서 13.6초**가 걸려 사실상 실사용 불가 — 방향을 잘못 두면 응답 시간이
15배 이상 벌어진다는 뜻이다. **FROM 절 순서 규칙("행 수 적은 쪽을 앞에")은
필요조건이지 충분조건이 아니다.** inner로 반복 조회당하는 쪽이 StarRocks라면
outer 행 수가 적더라도 반복 호출 단가 자체가 높으므로, 크로스 키스페이스
조인이 잦은 경로는 **항상 StarRocks를 outer(드라이빙)에 두도록 애플리케이션
쿼리를 강제**해야 한다. 그마저 어렵다면(양방향 다 필요하다면) 조인 대신
`INSERT...SELECT`로 필요한 조각만 한쪽으로 모아온 뒤 단일 백엔드에서 조인하는
편이 낫다.

## 실무 패턴: MySQL 1~2건 조회 → StarRocks 통계/리스트 조회 (네이티브 amd64, 2026-08-29)

가장 흔할 실사용 패턴 — **MySQL에서 PK로 1~2건만 찾은 뒤, 그 키로 StarRocks에서
통계(그룹핑)나 리스트를 가져오는 경우** — 도 검증했다. 이 방향은 outer(MySQL)가
1~2행이라 StarRocks가 inner라도 위 "JOIN 방향별 성능" 문제(반복 호출 단가)와
무관하다 — inner 호출 자체가 1~2번만 나가기 때문이다. `mysql_ks.orders`에 2행,
`sr_ks.events`에 고객당 1,000행(총 2,000행)을 채우고 두 케이스를 테스트했다.

**케이스 A — 그룹핑(통계)**:

```sql
SELECT o.id, o.customer, COUNT(*) AS event_cnt, SUM(ev.amount) AS total_amount
FROM mysql_ks.orders o
JOIN sr_ks.events ev ON o.id = ev.customer_id
WHERE o.id IN (1,2)
GROUP BY o.id, o.customer;
```

문제없이 동작한다. StarRocks 쪽 라우트는 `... where ev.customer_id = :o_id
group by .0`처럼 고객 1명 단위 집계를 그대로 push-down하고, vtgate가 그 결과를
다시 합치는 구조라 `weight_string`도 필요 없다. 결과도 정확했다(이벤트 1,000건,
합계 58743.75 — 직접 계산한 기댓값과 일치). **5회 반복 평균 약 19ms.**

**케이스 B — 리스트 조회**:

```sql
SELECT o.id, o.customer, ev.event_type, ev.amount
FROM mysql_ks.orders o
JOIN sr_ks.events ev ON o.id = ev.customer_id
WHERE o.id IN (1,2)
ORDER BY o.id
LIMIT 50;
```

이것도 문제없이 동작한다(**5회 반복 평균 약 18ms**). 다만 **`ORDER BY`에
StarRocks 쪽 컬럼(`ev.event_type`, `ev.amount`, `ev.event_id` 등)이 하나라도
들어가면 실패한다** — mysql 컬럼과 섞였는지 여부와 무관하다. `ORDER BY
ev.event_id`처럼 StarRocks 컬럼 단독으로만 정렬해도 똑같은 에러가 난다.
vtgate가 정렬 키로 쓰이는 컬럼은 **그 컬럼을 낸 쪽 라우트에** `weight_string()`을
주입해서 비교 가능한 형태로 바꾸는데, 그 라우트가 StarRocks면 함수 자체가
없어서 거기서 막힌다(`No matching function with signature:
weight_string(bigint(20))`). 즉 **판단 기준은 "정렬 키가 어느 컬럼과 섞였나"가
아니라 "정렬 키 중 하나라도 StarRocks 컬럼인가"** 다. 이건 "왜 특정 패턴만
막히는가 #2"에 정리한 `weight_string` 문제가 **UNION뿐 아니라 크로스
키스페이스 JOIN의 ORDER BY에도 똑같이 적용된다**는, 기존 문서에 없던 새 사례다.

**실무 함의**: MySQL에서 소수 건을 찾아 그 키로 StarRocks 통계/리스트를
당겨오는 패턴은 **성능(약 20ms 내외)도 정합성도 문제없다** — 이 구조는 실사용
가능하다. 단 하나 지켜야 할 규칙: **정렬 키에 StarRocks 컬럼을 절대 넣지
말 것**(MySQL 쪽 컬럼으로만 정렬하거나 아예 생략). StarRocks 쪽 값으로 순서를
매겨야 한다면 애플리케이션에서 받은 뒤 정렬하거나, StarRocks 쪽에 이미 정렬된
인덱스/뷰를 두는 식으로 우회해야 한다.

## StarRocks 단독(단일 키스페이스) 쿼리는 정렬 제약이 없음

`weight_string` 문제는 크로스 키스페이스(JOIN/UNION)일 때만 생긴다 —
**StarRocks 단독(단일 키스페이스) 쿼리는 정렬이 전혀 문제없다.** 같은 `sr_ks.events`
테이블에 대해 JOIN 없이 `sr_ks`만 조회하면:

```sql
SELECT customer_id, event_type, amount, event_id
FROM sr_ks.events
WHERE customer_id = 1
ORDER BY event_id DESC
LIMIT 10;
```

`VEXPLAIN PLAN`을 까보면 `Route`가 하나뿐이고(`Variant: Unsharded`) `ORDER BY`가
`weight_string` 없이 그대로 StarRocks 쿼리 텍스트에 박혀서(`... order by event_id
desc limit :vtg1`) 통째로 push-down된다 — vtgate가 병합할 다른 소스가 없으니
비교 함수를 주입할 이유 자체가 없기 때문이다. 다음 조합 전부 정상 동작을 확인했다:

- 정수 컬럼(`event_id`) DESC 정렬
- DECIMAL 컬럼(`amount`) 정렬
- VARCHAR 컬럼(`event_type`) + 보조키 다중 정렬
- `WHERE` 없이 전체 스캔 + 다중 컬럼 정렬
- **`GROUP BY` + `ORDER BY`(집계 컬럼 기준)** — `... group by customer_id,
  event_type order by total desc`까지 전부 StarRocks로 그대로 내려간다

**실무 함의**: 정렬이 필요한 쿼리는 **StarRocks 하나의 키스페이스로만 끝나도록
설계하면(MySQL과 JOIN하지 않으면) 아무 제약 없이 자유롭게 정렬**할 수 있다.
제약은 오직 "정렬 결과가 여러 키스페이스에 걸친 행을 vtgate가 병합해야 하는
경우"에만 생긴다 — 흔한 "StarRocks 통계/리스트를 정렬해서 보여주기" 요구는
sr_ks 단독 쿼리로 짜면 전혀 문제되지 않는다.

## `WHERE col IN (SELECT ... FROM mysql_ks)` 서브쿼리로 StarRocks 조회하기 (네이티브 amd64, 2026-08-29)

JOIN 말고 **서브쿼리로 MySQL 쪽 키를 먼저 뽑아 StarRocks를 필터링**하는 패턴도
확인했다:

```sql
SELECT customer_id, event_type, amount, event_id
FROM sr_ks.events
WHERE customer_id IN (SELECT id FROM mysql_ks.orders WHERE customer = 'carol')
ORDER BY event_id DESC
LIMIT 10;
```

`VEXPLAIN PLAN`을 보면 vtgate가 이걸 **`UncorrelatedSubquery`(`PulloutIn`
변형)**로 계획한다 — 서브쿼리(`mysql_ks`)를 먼저 통째로 실행해 결과를 바인드
변수 리스트(`__sq1`)로 만든 뒤, `sr_ks` 쪽에 `WHERE customer_id IN ::__sq1`로
한 번에 넘겨 **단일 Route**로 끝낸다(JOIN처럼 outer 행마다 반복 호출하지
않는다). **단순 필터 + `ORDER BY`는 문제없이 동작한다** — `order by
events.event_id desc`가 `weight_string` 없이 그 Route 안에 그대로 박힌다.

**단, 여기에 `GROUP BY`(집계)를 추가하면 `ORDER BY`가 없어도 실패한다**:

```sql
SELECT customer_id, COUNT(*) AS cnt, SUM(amount) AS total
FROM sr_ks.events
WHERE customer_id IN (SELECT id FROM mysql_ks.orders WHERE customer IN ('carol','dave'))
GROUP BY customer_id;
```

```
ERROR 1064 (HY000): ... No matching function with signature: weight_string(bigint(20)).
Sql: "select customer_id, count(*) as cnt, sum(amount) as total, weight_string(customer_id)
      from `events` where :__sq_has_values and customer_id in ::__sq1
      group by customer_id order by customer_id asc"
```

`VEXPLAIN`으로 보면 이유가 드러난다 — **단독 `sr_ks` 쿼리(위 "StarRocks 단독
소팅" 절)에서는 `GROUP BY`가 있어도 Route 하나로 완전히 push-down**됐지만,
`UncorrelatedSubquery`(`PulloutIn`) 래퍼 **안**에서는 vtgate가 그 신뢰를
안 하고 바깥에 별도 **`Aggregate`(`Ordered` 변형) 오퍼레이터를 얹어서
vtgate 레이어에서 다시 집계**한다 — `Ordered` 집계는 입력이 정렬돼 있어야
하므로 그룹 키에 `weight_string()`을 주입하고, StarRocks가 이를 거부한다.
물리적으로는 여전히 route가 하나뿐인데도(다른 키스페이스와 병합할 필요가
없는데도) 이 최적화를 안 타는 건 **서브쿼리 pullout 플래너의 한계**로 보인다.
JOIN 방식(위 "실무 패턴: MySQL 1~2건 조회 → StarRocks 통계/리스트" 절의
케이스 A)은 같은 통계 요구를 문제없이 처리했다는 점과 대비된다.

**실무 함의**: **MySQL 키로 StarRocks를 필터링만 할 때는 `WHERE col IN
(SELECT ...)` 서브쿼리를 써도 되고(JOIN보다 오히려 계획이 단순), 정렬도
자유롭다.** 하지만 **통계·집계(`GROUP BY`, `COUNT`/`SUM` 등)가 필요하면
서브쿼리 방식을 피하고 JOIN(outer=MySQL, inner=StarRocks, outer 행 수가
적을 때)으로 짜야 한다** — 같은 요구를 서브쿼리로 짜면 `GROUP BY`가 있는
순간 무조건 깨진다.

## 안정성: vtgate 고빈도 쿼리 부하 (네이티브 amd64 검증 완료)

개발 중 Apple Silicon Mac(docker-compose)에서 JOIN 벤치마크나 고빈도 쿼리 부하를
주면 vtgate가 간헐적으로 fatal error(타입 어서션 패닉, 고루틴 캐시 손상, fault
address 등 — 매번 다른 시그니처)로 죽는 현상이 있었다. `vitess/lite`는 arm64
이미지가 없어 이 Mac에서는 amd64 이미지가 QEMU로 에뮬레이션되고 있었는데, 매번
증상이 다르다는 점이 애플리케이션 로직 버그보다는 이 QEMU 에뮬레이션 하의 산발적
메모리 손상(잘 알려진 현상)을 가리켰다. 아래는 이 가설을 네이티브 amd64에서
직접 검증한 결과다.

**검증 환경(2026-08-29)**: 홈랩 k8s 클러스터(chan08/chan09/llm001, 전부
x86_64), `vitess/lite:v24.0.2`로 etcd/vtctld/vtgate/vttablet-mysql/mysql을
한 Pod에 담아 docker-compose 네트워크 구조를 재현. StarRocks는 별도로 새로
띄우지 않고 운영 중인 `starrocks` 네임스페이스의 FE를 그대로 재사용(테스트
전용 DB/계정만 신설, 테스트 후 삭제).

| 테스트 | 부하 | 결과 |
|---|---|---|
| 단일 키스페이스, 단일 커넥션 순차 | 5,000회 | 에러 0 |
| 단일 키스페이스, 단일 커넥션 순차 | 50,000회 (19.6초, ~2,550 QPS) | 에러 0 |
| 단일 키스페이스, 20커넥션 병렬 | 50,000회 (2.8초) | 에러 0 |
| 크로스 키스페이스 JOIN(N=2,000, 양방향 FROM 순서) | 60회 반복, nested-loop RPC 약 12만 건 (5분 12초) | 에러 0 |

**결론**: 총 22만 건 이상의 쿼리 — 단일 커넥션/병렬 커넥션 부하와 크로스
키스페이스 nested-loop JOIN까지 — 동안 vtgate/vttablet 컨테이너 재시작이
단 한 번도 발생하지 않았다. Mac에서 본 크래시는 Vitess/v24.0.2 자체의 결함이
아니라 로컬 QEMU 에뮬레이션 환경의 한계였음이 확인됐다.

**실무 함의**: Apple Silicon Mac에서 이 repo를 재현하면 크래시를 볼 수 있지만
StarRocks 연동이나 Vitess 자체 문제가 아니다. 네이티브 amd64(또는 목표 배포
아키텍처) 환경에서는 이 정도 규모의 부하가 문제되지 않음을 확인했으므로,
`restart: on-failure`는 안전장치로만 유지하면 된다.

## 재현 중 겪은 이슈

- **vttablet/vtgate 기동 레이스 컨디션**: `docker-compose up -d`는 모든 서비스를 거의
  동시에 띄우는데, vttablet/vtgate는 etcd에 cell·keyspace·tablet이 이미 있어야
  정상 동작한다. 최초 기동 시 vttablet이 "cell 없음"으로 죽거나(`restart: on-failure`로
  자동 재시도), vtgate가 "keyspace/tablet 없음" 상태를 빈 캐시로 기억해버리는 경우가
  있다(`init.sh`가 토폴로지를 다 만든 뒤 vtgate를 명시적으로 한 번 더 재시작해서 처리).
- **StarRocks stdin 멀티 스테이트먼트 첫 줄 주석 버그**: `mysql ... < file.sql`처럼
  여러 문장을 한 번에 보낼 때, 파일 첫 줄이 `--` 줄 주석이면 StarRocks가 문법 에러를
  낸다(`mysql -e`로 단일 문장 실행할 땐 문제없음). `init/*.sql`은 그래서 `/* */`
  블록 주석으로 시작한다.
- **vtgate가 고빈도 쿼리 부하에서 fatal error로 죽음 (Apple Silicon Mac 한정)**: Mac
  docker-compose에서 관찰됐지만, 네이티브 amd64 k8s에서 동일 부하의 20배 이상
  (단일/JOIN 합산 22만 건 이상)을 줘도 전혀 재현되지 않아 Vitess 결함이 아니라
  Mac의 QEMU(amd64→arm64) 에뮬레이션 환경 문제였음이 확인됐다 —
  [상세 분석](#안정성-vtgate-고빈도-쿼리-부하-네이티브-amd64-검증-완료).
  `restart: on-failure`는 안전장치로 유지.

## 정리

| 방향 | 방법 |
|---|---|
| MySQL(샤딩) → StarRocks(분석) 데이터 적재 | VTGate 단일 SQL문(`INSERT...SELECT`)으로 충분 |
| StarRocks(분석) → MySQL(샤딩) 데이터 반영 | 앱 레벨 2단계(SELECT 후 INSERT), 크론 불필요 — 호출 시점에 실행되는 함수로 구현 |
| hot/cold 데이터 통합 조회 | `UNION ALL`로 가능, 정렬은 앱에서 |
| 리샤딩/무중단 DDL/정밀 헬스체크 등 Vitess 고급 기능 | StarRocks 쪽에서는 불가 — 사이드카 DB 미지원 |

실무에 적용한다면: **StarRocks는 항상 순수 SQL 프록시 대상으로만 취급**하고(Vitess의
관리 기능을 StarRocks에 기대하지 말 것), 쓰기 방향이 "샤딩→분석"이면 VTGate 크로스
키스페이스 쿼리 한 줄로 충분하고, "분석→샤딩" 방향이나 온디맨드 트리거가 필요하면
애플리케이션 레벨에서 짧은 함수 하나로 처리하는 게 가장 실용적이다.
