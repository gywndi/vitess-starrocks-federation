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
- **vtgate gRPC 클라이언트 패닉**: vttablet 컨테이너가 재시작되며 재연결될 때 vtgate가
  간헐적으로 패닉하며 죽는다(`vitess/lite:latest` 스냅샷 빌드의 알려진 불안정성으로
  보임). `restart: on-failure`로 자동 복구되도록 해뒀다.

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
