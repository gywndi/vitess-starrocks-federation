# Vitess로 MySQL + StarRocks를 하나의 세션에서 다루기

Vitess(MySQL 샤딩 미들웨어)의 VTGate가 실서비스 샤딩 DB(MySQL)와 분석 엔진(StarRocks)을
**하나의 MySQL 프로토콜 세션**으로 동시에 다룰 수 있는지 검증한 PoC다. StarRocks가
MySQL 와이어 프로토콜을 지원한다는 점에 착안해서, Vitess의 "unmanaged tablet"(원래
RDS/Aurora 같은 관리형 MySQL을 붙이는 기능)으로 StarRocks를 끼워 넣을 수 있는지
실제로 띄워서 확인했다.

**한 줄 결론**: 기본 SQL 프록시(SELECT/INSERT/JOIN/UNION)는 된다. VTGate가 크로스 샤드
처리를 위해 주입하는 일부 MySQL 전용 구문은 StarRocks가 이해 못해서 특정 패턴에서만
막힌다. 막히는 이유, 우회법, 배제한 대안은 **[docs/FINDINGS.md](docs/FINDINGS.md)** 참고.

## 빠른 시작

```bash
docker compose up -d   # 구버전 Docker Desktop이면 docker-compose (하이픈)
./init.sh
mysql -h 127.0.0.1 -P 25306 -u root < examples/01_cross_keyspace_select.sql
```

포트는 로컬 환경과 안 겹치도록 25xxx/29xxx/28xxx 대역을 썼다(필요하면 `docker-compose.yml`의
호스트 쪽 포트만 바꾸면 된다). `init.sh`는 재실행해도 안전하다(idempotent). 정리는
`docker-compose down`(`-v`를 붙이면 볼륨까지 삭제).

## 구성

```
mysql client (25306) → VTGate → ┬─ vttablet-mysql(unmanaged) → mysql-standalone(진짜 MySQL, "샤딩 대역" 시뮬레이션)
                                 └─ vttablet-sr(unmanaged)    → sr-standalone(StarRocks all-in-one, "분석/아카이브 대역" 시뮬레이션)
```

`mysql_ks` = MySQL 백엔드, `sr_ks` = StarRocks 백엔드. 클라이언트는 `USE mysql_ks` /
`USE sr_ks`로 전환하거나, 한 쿼리 안에서 `mysql_ks.table` / `sr_ks.table`처럼 완전한
이름으로 섞어 쓸 수 있다.

## 검증된 기능 매트릭스

| 기능 | 결과 | 예제 |
|---|---|---|
| 같은 세션에서 두 키스페이스 조회 | ✅ | [`01`](examples/01_cross_keyspace_select.sql) |
| 키스페이스 간 JOIN(항상 Nested Loop, 드라이빙은 `FROM` 절 순서로 결정됨) | ✅ | [`02`](examples/02_cross_keyspace_join.sql), [원리](docs/FINDINGS.md#크로스-키스페이스-join의-실행-순서--nested-loop-그리고-드라이빙-테이블은-from-절-순서로-결정) |
| JOIN 방향별 실측: StarRocks가 inner일 때 MySQL이 inner일 때보다 약 4배 느림 | 📊 | [`05`](examples/05_join_direction_benchmark.sh), [수치](docs/FINDINGS.md#join-방향별-성능-실측) |
| UNION ALL (hot=MySQL + cold=StarRocks 아카이브) | ✅ | [`03`](examples/03_union_all_archive.sql) |
| UNION ALL + 바깥쪽 전역 ORDER BY | ❌ | [`03b`](examples/03b_union_all_order_by_FAILS.sql) |
| UNION ALL + 서브쿼리별 개별 ORDER BY/LIMIT | ✅ | [`03c`](examples/03c_union_all_per_subquery_sort.sql) |
| `INSERT...SELECT`: MySQL → StarRocks (단일 SQL문) | ✅ | [`04`](examples/04_insert_select_mysql_to_starrocks.sql) |
| `INSERT...SELECT`: StarRocks → MySQL (단일 SQL문) | ❌ | [`04b`](examples/04b_insert_select_starrocks_to_mysql_FAILS.sql) |
| StarRocks → MySQL, 2단계(SELECT 후 앱에서 INSERT) | ✅ | [`sync_on_demand.py`](examples/sync_on_demand.py) |
| VReplication / Online DDL / 정밀 헬스체크 | ❌ | [FINDINGS.md](docs/FINDINGS.md#3-사이드카-_vt-db) |

각 항목이 왜 되고 안 되는지(소스 코드 위치 포함), 시도했지만 배제한 대안(FEDERATED 엔진 등)은
**[docs/FINDINGS.md](docs/FINDINGS.md)**에 정리했다.

## 파일 구조

```
docker-compose.yml       # etcd + vtctld + vtgate + vttablet×2 + mysql + starrocks
init.sh                  # 1회성 초기화(토폴로지, 승격, 샘플 데이터)
init/                    # 샘플 스키마/데이터
examples/                # 검증 쿼리(성공/실패 사례) + 온디맨드 동기화 스크립트
docs/FINDINGS.md         # 상세 원인 분석, 배제한 대안, 실무 권장사항
```
