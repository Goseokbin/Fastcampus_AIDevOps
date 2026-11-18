---
name: obs-ask
description: 운영 질문(에러가 언제부터 늘었나, 어디가 느린가, 재시작한 Pod 가 있나, 실패한 요청 한 건 추적 등)을 Grafana MCP 로 PromQL · LogQL · TraceQL 조회해 근거와 함께 답한다. 읽기 전용. 대시보드 · 알람 · 플래그는 바꾸지 않는다.
---

# 관측 데이터에 질문하기 (읽기 전용)

질문이 무엇이든 같은 순서로 조사한다. 질문에 답하는 데 필요한 단계까지만 간다.

**메트릭으로 "언제 · 얼마나" → 트레이스로 "어디서" → 로그로 "왜"**

CLAUDE.md 의 "관측 데이터 조회" 규칙을 지킨다. 이 Skill 은 그 규칙을 조사 순서로 푼 것이다.

## 0. 범위

- 질문에 시간 범위가 없으면 최근 1시간. 넓힐 때는 이유를 먼저 말하고 최대 24시간.
- 대상은 `otel-demo-dev`. 시각은 KST 절대 시각(예: 11-17 20:00:10 KST).

## 1. 수집부터 확인한다

- 볼 메트릭에 최신 샘플이 있는지, 같은 메트릭의 시계열이 있는지 먼저 본다.
- 빈 결과는 "0" 일 수도, "데이터 없음"(이름 틀림 · 수집 끊김) 일 수도 있다. 둘을 가른 뒤에 답한다.

## 2. 메트릭 (Prometheus) — 언제 · 얼마나

- 이름은 `specs/observability.md` 의 SLI 쿼리에 있는 것을 쓴다(`traces_span_metrics_calls_total`, `traces_span_metrics_duration_milliseconds_bucket`, 라벨 `service_name` · `span_name` · `span_kind` · `status_code`). 없는 이름은 `list_prometheus_metric_names` · `list_prometheus_label_values` 로 확인한다. 추측하지 않는다.
- span 메트릭은 Collector 주기 때문에 1 ~ 2분 늦게 보인다. 정확한 시작 시각은 3 · 4 단계로 확인한다.
- 지연은 서버 span 의 p95 를 호출 수와 함께 본다. 연결을 열어 두는 스트림 span(flagd `EventStream` 등)은 지연 · 에러로 세지 않는다.
- Pod 상태는 kube-state-metrics(`kube_pod_container_status_restarts_total` 등)를 본다.

## 3. 트레이스 (Tempo) — 어디서

- `status = error` span 을 찾아 trace_id 를 얻고, 트레이스에서 처음 실패한 span 과 실행되지 않은 뒤 단계를 적는다.

## 4. 로그 (Loki) — 왜

- 같은 trace_id 로 로그를 찾는다: `{service_name=~"…"} | trace_id="…"`. 인덱스 라벨은 `service_name` 등 몇 개뿐이고 trace_id · 레벨은 `|` 뒤에서 거른다.
- 이메일 · 카드 정보가 보이면 인용하지 않고 "민감 정보 있음" 으로만 적는다.

## 5. 답

```
<결론 한두 줄. 숫자와 KST 절대 시각>

| 확인 | 결과 | 데이터소스 |

확인하지 못한 것
- <빈 결과, 조회 실패, 가정>

실행한 쿼리 (원문 · 시간 범위)
```

- 원인은 "가설" 로 쓰고, 증거(트레이스 · 로그)를 찾으면 "확인" 으로 바꾼다.
- 플래그 상태 · 배포 이력처럼 MCP 로 안 보이는 것은 사람이 확인할 명령을 적는다.
