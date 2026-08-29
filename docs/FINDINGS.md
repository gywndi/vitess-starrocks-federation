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

### JOIN 방향별 성능 실측

위의 "드라이빙은 FROM 절 순서" 사실 자체는 확인했지만, **outer/inner를 어느 쪽에
두느냐가 실제로 얼마나 차이 나는지**를 직접 재봤다([`05_join_direction_benchmark.sh`](../examples/05_join_direction_benchmark.sh)).

방법: `mysql_ks.orders`와 `sr_ks.vitess_test_tbl` 양쪽에 id가 겹치는 합성 데이터
2,000행을 채우고, `WHERE id <= N`으로 outer 쪽 행 수(N)를 조절해가며 같은 조인을
FROM 절 순서만 바꿔 반복 실행, 벽시계 시간을 비교(각 N당 3회 반복, 로컬 Mac
docker-compose 환경).

| N (outer 행 수) | mysql-outer (StarRocks가 inner) | starrocks-outer (MySQL이 inner) | 배율 |
|---|---|---|---|
| 30 | 0.226s | 0.102s | 2.2배 |
| 60 | 0.378s | 0.085s | 4.4배 |
| 100 | 0.470s | 0.116s | 4.1배 |
| 150 | 0.652s | 0.156s | 4.2배 |

**StarRocks가 inner(즉 MySQL이 outer)일 때가 일관되게 4배 안팎 더 느리다.** 구간별
기울기로 행당 순수 inner 쿼리 비용을 역산하면:

- StarRocks가 inner일 때: 행당 약 **3.5ms** 추가
- MySQL이 inner일 때: 행당 약 **0.45ms** 추가

즉 StarRocks에 단건 point-lookup을 반복해서 날리는 비용이 MySQL 대비 **약 8배**
비싸다. StarRocks는 컬럼형 OLAP 엔진이라 한 건짜리 쿼리도 FE 파싱/플래닝
오버헤드를 매번 지불하는 반면, MySQL은 PK 인덱스 point-lookup에 특화된 OLTP
엔진이라 반복 호출 비용이 훨씬 싸기 때문으로 보인다.

**실무 함의(갱신)**: FROM 절 순서 규칙("행 수 적은 쪽을 앞에")은 필요조건이지
충분조건이 아니다. **inner로 반복 조회당하는 쪽이 StarRocks라면, outer 행 수가
적더라도 반복 호출 자체의 단가가 높다**는 점까지 고려해야 한다. 크로스 키스페이스
조인이 잦은 경로라면 StarRocks를 inner에 두는 설계 자체를 피하고, 가능하면 조인
대신 `INSERT...SELECT`로 필요한 조각만 한쪽으로 모아온 뒤 단일 백엔드에서
조인하는 편이 낫다.

### 안정성: vtgate가 고빈도 쿼리 부하에서 fatal error로 죽는 현상 (원인: 로컬 arm64 에뮬레이션 추정)

N을 200~1000까지 올려서 JOIN 벤치마크를 테스트하던 중 vtgate가 여러 차례 실제로
죽는 것을 확인했다. 원인을 좁혀나간 과정과 결론은 다음과 같다.

**1차 관찰**: `vitess/lite:latest`(25.0.0-SNAPSHOT 개발 스냅샷) 빌드에서, 2,000행
JOIN 벤치마크 도중 vtgate gRPC 클라이언트가 타입 어서션 패닉으로 죽었다
(`go/vt/vtgate/engine/route.go` 근처 → gRPC 내부 controlbuf에서
`runtime: name offset base pointer out of range`, Go 런타임 레벨 fatal error).
처음엔 "JOIN의 nested loop이 inner 쪽에 수백 번 순차 RPC를 날리기 때문"이라고
추정했다.

**2차 검증(반증)**: 그 가설을 검증하려고 JOIN을 아예 빼고, **단일 키스페이스
쿼리**(`SELECT * FROM sr_ks.vitess_test_tbl LIMIT 1`, 스캔량도 무시할 수준)를
**커넥션 하나에서 반복 실행**하는 스트레스 테스트를 따로 돌렸다. 2,000회는
통과했지만 5,000회를 돌리자 3,682번째 호출에서 vtgate가 또 죽었다 — 이번엔
`fatal error: acquireSudog: found s.elem != nil in cache`(고루틴 스케줄러의
채널 동기화 캐시 손상)로, **완전히 다른 증상**이었다. 이걸로 "JOIN 전용 문제"
가설은 기각됐다 — **JOIN 여부와 무관하게, 짧은 시간에 많은 요청이 vtgate를
거치면 죽는다.**

**3차 검증**: "그럼 정식 릴리스가 아니라 검증 안 된 SNAPSHOT 빌드라서 그런 게
아니냐"는 의심이 합리적이어서, Docker Hub에서 확인한 최신 정식 GA 태그
`vitess/lite:v24.0.2`로 이미지를 바꿔 **동일한 5,000회 반복 스트레스 테스트를
재실행**했다. sr_ks 5,000회는 통과했지만, 이어서 돌린 mysql_ks 5,000회가
725번째 호출에서 또 죽었다 — 이번엔 `unexpected fault address ...
fatal error: fault`(세그폴트급 메모리 접근 위반)로, **또 다른 증상**이었다.

**결론(추정 원인)**: 정식 GA 릴리스에서도 재현되고, 매번 죽는 증상(타입 어서션
패닉 / 채널 캐시 손상 / fault address)이 다르다는 것 자체가 애플리케이션
로직 버그보다는 더 근본적인 원인을 가리킨다. 확인해보니 `vitess/lite`는
arm64용 이미지가 없어서, 이 Mac(Apple Silicon, arm64)에서 **amd64 이미지가
QEMU 에뮬레이션으로 돌아가고 있었다**(`docker image inspect` 결과
`Architecture: amd64`, 호스트는 `arm64`; 최초 기동 로그에도 "The requested
image's platform (linux/amd64) does not match the detected host platform
(linux/arm64/v8)" 경고가 이미 찍혀 있었다). amd64→arm64 QEMU 에뮬레이션에서
Go 런타임의 원자적 연산·메모리 배리어가 고빈도 부하 아래 부정확하게 번역되며
산발적으로(매번 다른 증상으로) 메모리가 손상되는 것은 잘 알려진 현상이고,
지금까지의 관찰과도 정확히 들어맞는다.

**실무 함의**: 이 크래시들은 Vitess 자체의 결함이라기보다 **"이 로컬 재현
환경이 amd64 전용 이미지를 arm64에서 에뮬레이션으로 돌린다"는 한계일 가능성이
가장 높다**. 네이티브 amd64 리눅스(실제 프로덕션 환경 대부분)에서는 이 부하로
재현 안 될 가능성이 크지만, 이 환경에서 직접 반증할 수는 없어 가설로 남는다.
Apple Silicon Mac에서 이 repo를 재현하는 사람은 **같은 크래시를 볼 수 있고,
그건 StarRocks 연동이나 Vitess 자체의 문제가 아니라 로컬 에뮬레이션
때문일 가능성이 높다는 점을 감안할 것.** 실제 채택 전에는 반드시 네이티브
amd64(또는 목표 배포 아키텍처) 서버에서 같은 부하로 재검증해야 한다.
`restart: on-failure`가 걸려 있어 매번 자동 복구는 됐다.

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
- **vtgate가 고빈도 쿼리 부하에서 fatal error로 죽음**: JOIN 여부와 무관하게, 짧은
  시간에 수천 건의 쿼리가 vtgate를 거치면 매번 다른 증상(타입 어서션 패닉, 고루틴
  캐시 손상, 세그폴트급 fault)으로 죽는다. 정식 GA 릴리스(`v24.0.2`)에서도
  재현되며, 원인은 이 로컬 환경이 amd64 전용 이미지를 Apple Silicon(arm64)에서
  QEMU로 에뮬레이션하기 때문일 가능성이 가장 높다 — [상세 분석](#안정성-vtgate가-고빈도-쿼리-부하에서-fatal-error로-죽는-현상-원인-로컬-arm64-에뮬레이션-추정).
  `restart: on-failure`로 자동 복구되도록 해뒀다.

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
