---
name: daily-health
description: 아침 점검. 스펙(specs/observability.md 7장 B)의 B1 ~ B4 를 매일 같은 순서로 Grafana MCP 로 조회해 지난 24시간의 재시작 · NotReady · Pending · OOMKilled · 노드 여유 · HPA · 주문 기준선에 더해 firing 중인 알람 · Collector 전송 실패 · Argo CD 앱 상태를 한 장으로 보고한다. 읽기 전용. 클러스터 · 대시보드 · 알람은 바꾸지 않는다.
---

# 아침 점검 (읽기 전용)

`specs/observability.md` 7장 **B. 아침 점검** 의 질문 네 개와 추가 점검 세 가지(firing 알람 · Collector 전송 실패 · Argo CD 앱 상태)를 매일 같은 순서 · 같은 쿼리로 답한다.
목표는 원인 분석이 아니라 **"오늘 사람이 들여다볼 것이 있는가" 를 근거와 함께 가르는 것**이다. 깊이 파는 일은 `/obs-ask` · `/deploy-triage` 로 넘긴다.

CLAUDE.md 의 "관측 데이터 조회" 규칙을 지킨다. 쿼리는 "아침 점검" 대시보드(`gitops/manifests/observability/morning-check-dashboard.yaml`, uid `morning-check`)의 패널과 같은 메트릭을 쓴다. 대시보드와 이 Skill 의 답이 다르면 안 된다.

## 0. 범위

- 시간 범위는 **실행 시각 기준 지난 24시간** 고정(규칙의 최대값). 더 넓히지 않는다. 보고에는 시작 · 끝을 KST 절대 시각으로 적는다.
- 데이터소스는 Prometheus(uid `prometheus`). 조회가 안 되면 `list_datasources` 로 uid 를 확인한다.
- 모든 쿼리는 `query_prometheus` 의 instant 조회(`endTime: now`)로 실행한다. 24시간은 쿼리 안의 `[24h]` 로 본다.
- 메트릭 보존이 2일이고 저장이 emptyDir 이라, Prometheus 가 24시간 안에 재시작했으면 `[24h]` 는 그만큼 짧은 구간만 본다. C 단계에서 확인해 보고에 적는다.

## 1. 수집부터 확인한다 (7장 C — 데이터가 없는 것과 이상이 없는 것을 가른다)

| 확인 | 쿼리 | 읽는 법 |
| --- | --- | --- |
| 수집 대상이 살아 있나 | `count by (job) (up == 0)` | 비어야 정상. 나온 job 은 그 job 의 메트릭을 쓰는 항목을 "확인 필요" 로 |
| kube-state-metrics | `count(kube_pod_container_status_restarts_total)` | 0 · 빈 결과면 B1 · B2 는 "데이터 없음" |
| node-exporter | `count(node_memory_MemTotal_bytes)` | 노드 수(2)와 같아야 한다. 다르면 B3 은 "확인 필요" |
| 주문 메트릭 | `sum(increase(traces_span_metrics_calls_total{service_name="checkout", span_name="oteldemo.CheckoutService/PlaceOrder", span_kind="SPAN_KIND_SERVER"}[24h]))` | 0 · 빈 결과면 B4 는 "주문 없음 / 데이터 없음". 실패율 0% 로 쓰지 않는다 |
| Prometheus 가동 시간 | `time() - max(process_start_time_seconds{job="kube-prometheus-stack-prometheus"})` | 86400 보다 작으면 "24시간 중 최근 N시간만 본 값" 이라고 적는다 |

빈 결과가 나오면 `list_prometheus_metric_names` · `list_prometheus_label_values` 로 이름부터 확인한다. 조회 실패(연결 · 권한 · 타임아웃)는 "확인 필요" 다.

## 2. B1 — 지난 24시간 재시작한 Pod 는

```
topk(10, sum by (namespace, pod, container) (increase(kube_pod_container_status_restarts_total[24h])) > 0)
```

- 비면 "재시작 0건" (1 단계에서 시계열이 있음을 확인했을 때만).
- `increase()` 는 외삽이라 정수가 아니다. 반올림해 "약 N회" 로 적는다.

## 3. B2 — NotReady 노드 · Pending Pod · OOMKilled 가 있나

```
kube_node_status_condition{condition="Ready", status!="true"} == 1
sum by (namespace, pod) (kube_pod_status_phase{phase="Pending"}) > 0
sum by (namespace, pod, container) (kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}) * on (namespace, pod, container) group_left sum by (namespace, pod, container) (increase(kube_pod_container_status_restarts_total[24h]))
```

- 앞의 둘은 **지금** 상태다. 비면 "없음".
- 셋째는 "마지막 종료가 OOMKilled 인 컨테이너 × 24시간 재시작 증가분" 이다. `last_terminated_reason` 은 시점이 없어서 재시작 수와 묶어 읽는다. 값이 0 이면 24시간보다 오래된 OOM 이므로 "과거 이력" 으로만 적고, 0 보다 크면 "24시간 안에 OOM 으로 재시작(가정: 마지막 종료 사유 기준)" 으로 적는다.

## 4. B3 — 노드 CPU · 메모리 여유와 HPA 상태

```
1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m]))
max_over_time((1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])))[24h:5m])
sum by (instance) (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)
max by (instance) (max_over_time((1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)[24h:5m]))
kube_horizontalpodautoscaler_status_current_replicas / on (namespace, horizontalpodautoscaler) kube_horizontalpodautoscaler_spec_max_replicas
kube_horizontalpodautoscaler_spec_max_replicas
max by (namespace, horizontalpodautoscaler) (max_over_time(kube_horizontalpodautoscaler_status_current_replicas[24h]))
```

- 노드마다 CPU · 메모리의 **지금 값과 24시간 최고값**을 적고, 스펙 10장 기준선(노드 실제 사용)을 옆에 둔다. 노드 사용률 임계는 스펙에 없으므로 숫자만 보고하고 판정하지 않는다.
- HPA 는 현재 / 최대 replicas 와 24시간 최고 replicas. 현재가 최대와 같으면(비율 1) "최대치에 붙어 있음 — 확인 필요", 24시간 최고만 최대에 닿았으면 "밤사이 최대까지 늘었다가 내려옴" 으로 적는다.

## 5. B4 — 주문 실패율 · p95 가 기준선(10장) 안인가

`ERR` = `traces_span_metrics_calls_total{service_name="checkout", span_name="oteldemo.CheckoutService/PlaceOrder", span_kind="SPAN_KIND_SERVER", status_code="STATUS_CODE_ERROR"}`,
`ALL` = 같은 셀렉터에서 `status_code` 를 뺀 것, `BKT` = 같은 셀렉터의 `traces_span_metrics_duration_milliseconds_bucket` (9장 SLI 쿼리. 실행할 때는 풀어 쓴다).

```
(sum(increase(ERR[24h])) or vector(0)) / sum(increase(ALL[24h]))
max_over_time(((sum(rate(ERR[5m])) or vector(0)) / sum(rate(ALL[5m])))[24h:5m])
histogram_quantile(0.95, sum by (le) (rate(BKT[24h])))
max_over_time(histogram_quantile(0.95, sum by (le) (rate(BKT[5m])))[24h:5m])
sum by (burn_rate, alertstate) (ALERTS{alertname="OrderFailureRateHigh"})
max by (burn_rate) (max_over_time(ALERTS{alertname="OrderFailureRateHigh", alertstate="firing"}[24h]))
```

- 순서대로: 24시간 실패율, 가장 나빴던 5분 창의 실패율, 24시간 p95, 가장 나빴던 5분 창의 p95, 주문 실패 알람의 지금 상태, 24시간 안에 firing 한 단계.
- 기준선과 목표는 **스펙 10장 · 9장을 그때 읽어서** 쓴다(값을 여기 베껴 두지 않는다). 판정:
  - **기준선 안**: 24시간 실패율과 p95 가 10장 값 안(p95 는 10장이 적은 버킷 상한 이하)
  - **기준선 밖 · 목표 안**: 기준선은 넘었지만 9장 목표(가용성 · p95) 안 — "확인 필요"
  - **목표 밖**: 9장 목표를 넘었거나 알람이 firing 중 — "이상"
- 24시간 값은 정상인데 5분 최고값만 튄 경우는 판정을 바꾸지 않고 "N분 창에서 일시적으로 X" 로 따로 적는다. 정확한 시각이 필요하면 같은 식을 range 조회(step 300초)로 한 번 더 본다.
- ALERTS 가 비면 "firing 이력 없음" 이다(1 단계에서 Prometheus 가 살아 있을 때만).
- p95 는 히스토그램 버킷 보간값이다. 버킷 경계(9장)를 넘었는지로 읽는다.

## 6. 추가 점검 — firing 중인 알람 전체 (Watchdog 제외)

```
sum by (alertname, namespace, severity) (ALERTS{alertstate="firing", alertname!="Watchdog"})
```

- **지금** firing 인 알람이다. `Watchdog` 은 알람 경로가 살아 있음을 보이려고 항상 firing 하는 룰이라 뺀다.
- 비면 "firing 0건" (1 단계에서 Prometheus 가 살아 있을 때만). 한 건이라도 있으면 `확인 필요` 로 알람 이름 · 네임스페이스 · 건수를 적는다. `OrderFailureRateHigh` 가 있으면 B4 와 같은 건이므로 B4 를 가리킨다.
- `severity` 는 차트 기본 룰이 붙인 라벨이다. 팀의 알람 등급은 미정(스펙 6장)이므로 등급으로 해석하지 않고 값만 옮긴다.
- 어느 Pod · 노드인지는 `ALERTS{alertstate="firing", alertname="<이름>"}` 로 라벨을 펼쳐 본다.

## 7. 추가 점검 — Collector 전송 실패 (7장 C1)

```
label_replace(sum by (exporter) (increase({__name__=~"otelcol_exporter_(send|enqueue)_failed_spans_total"}[24h])), "signal", "spans", "", "") or label_replace(sum by (exporter) (increase({__name__=~"otelcol_exporter_(send|enqueue)_failed_metric_points_total"}[24h])), "signal", "metric_points", "", "") or label_replace(sum by (exporter) (increase({__name__=~"otelcol_exporter_(send|enqueue)_failed_log_records_total"}[24h])), "signal", "log_records", "", "")
label_replace(sum by (exporter) (increase(otelcol_exporter_sent_spans_total[24h])), "signal", "spans", "", "") or label_replace(sum by (exporter) (increase(otelcol_exporter_sent_metric_points_total[24h])), "signal", "metric_points", "", "") or label_replace(sum by (exporter) (increase(otelcol_exporter_sent_log_records_total[24h])), "signal", "log_records", "", "")
```

- 첫째는 24시간 동안 exporter · 신호별 전송 실패(보내다 실패 + 큐에 못 넣음) 건수, 둘째는 보낸 건수다. 실제 백엔드로 가는 exporter 는 `otlp_grpc/tempo`(spans) · `otlp_http/prometheus`(metric_points) · `otlp_http/loki`(log_records) 셋이다. `debug` 는 화면 출력용이라 판정에서 뺀다.
- 실패 카운터는 한 번도 실패하지 않은 exporter 에는 시계열 자체가 없다. 그래서 **실패가 비거나 0 이고, 같은 exporter 의 보낸 건수가 0 보다 클 때만** "실패 0건" 이다. 보낸 건수까지 비면 "데이터 없음", 세 exporter 중 하나라도 보낸 건수가 0 이면 `이상`(그 신호가 24시간 동안 안 나갔다).
- 실패가 0 보다 크면 `확인 필요` 로 exporter · 신호 · 건수와 보낸 건수 대비 비율을 적는다. 그 신호를 쓰는 항목(spans → B4)에 "수치가 실제보다 적을 수 있음" 을 덧붙인다.

## 8. 추가 점검 — Argo CD 앱이 전부 Synced · Healthy 인가

```
kubectl get applications.argoproj.io -n argocd -o custom-columns='NAME:.metadata.name,PROJECT:.spec.project,SYNC:.status.sync.status,HEALTH:.status.health.status,AUTO:.spec.syncPolicy.automated,LAST:.status.operationState.finishedAt'
```

- Prometheus 에 Argo CD 메트릭(`argocd_app_info`)이 없어 이 항목만 kubectl 로 본다. 실행 전에 `kubectl config current-context` 가 스펙의 클러스터인지 확인한다. 데이터소스는 "kubectl(Application 리소스)", 시각은 실행 시각으로 적는다.
- 모든 앱이 `Synced` · `Healthy` 면 `정상`. 아닌 앱은 `확인 필요` 로 이름 · Sync · Health 를 적고 다음 단계로 `argocd app get <앱>` 또는 `/deploy-triage` 를 가리킨다.
- `AUTO` 가 `<none>` 인 앱은 수동 Sync 다(`specs/eks-demo.md`: `otel-demo-prod`). `OutOfSync` 여도 자동으로 맞춰지지 않는 것이 설계이므로 "수동 Sync 앱" 이라고 구분해 적는다. 의도된 상태인지는 사람이 판단한다.
- `LAST`(마지막 Sync 완료, UTC)가 24시간 안이면 "지난 24시간 안에 배포 있음" 으로 KST 로 바꿔 적는다. B1 · B4 가 나쁠 때 먼저 볼 단서다.
- `argocd app sync` 는 실행하지 않는다.

## 9. 보고

```
아침 점검 <날짜> — <한 줄 결론: 이상 없음 / 확인 필요 N건 / 이상 N건>
범위: <시작> ~ <끝> KST (24시간) · 데이터소스: Prometheus (Argo CD 는 kubectl, <실행 시각> KST)

| 질문 | 판정 | 결과 (숫자 · 리소스 이름) |
| --- | --- | --- |
| C  수집 | | |
| B1 재시작 | | |
| B2 NotReady · Pending · OOMKilled | | |
| B3 노드 여유 · HPA | | |
| B4 주문 기준선 | | |
| firing 알람 (Watchdog 제외) | | |
| Collector 전송 실패 | | |
| Argo CD 앱 Synced · Healthy | | |

오늘 볼 것
- <확인 필요 · 이상 항목마다: 무엇을, 다음에 실행할 것(/obs-ask · /deploy-triage 또는 사람이 실행할 명령)>

확인하지 못한 것
- <데이터 없음, 조회 실패, 가정. 플래그 상태(`scenarios/flag.sh --list`)는 사람이 확인한다>

실행한 쿼리 (원문)
```

- 판정은 `정상` · `확인 필요` · `이상` · `데이터 없음` 넷 중 하나. B1 · B2 는 한 건이라도 있으면 `확인 필요`.
- 원인은 여기서 단정하지 않는다. 보이는 사실(어느 Pod 가 몇 번, 언제)까지만 적는다.
- 복구 · 변경은 하지 않는다. 필요하면 `gitops/` PR 이나 사람이 실행할 명령으로 제안한다.
- 보고는 대화에 한다. Slack 으로 보내 달라는 요청을 받았을 때만 CLAUDE.md "Slack 사용" 대로 `#ops-daily` 에, 채널 이름과 메시지 전문을 먼저 보여 준 뒤 보낸다.
