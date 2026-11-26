---
name: daily-health
description: 아침 점검. 스펙(specs/observability.md 7장 B)의 B1 ~ B4 를 매일 같은 순서로 Grafana MCP 로 조회해 지난 24시간의 재시작 · NotReady · Pending · OOMKilled · 노드 여유 · HPA · 주문 기준선에 더해 firing 중인 알람 · Collector 전송 실패 · Argo CD 앱 상태를 한 장으로 보고하고, 항목마다 정상 · 확인 필요 · 즉시 대응으로 판정한다. 즉시 대응은 Slack #ops-daily 에 멘션해 알리고 확인 필요는 GitHub Issue 로 남긴다(같은 건이 열려 있으면 만들지 않는다). 조회는 읽기 전용. 클러스터 · 대시보드 · 알람은 바꾸지 않는다.
---

# 아침 점검 (조회는 읽기 전용 · 판정 · 에스컬레이션)

`specs/observability.md` 7장 **B. 아침 점검** 의 질문 네 개와 추가 점검 세 가지(firing 알람 · Collector 전송 실패 · Argo CD 앱 상태)를 매일 같은 순서 · 같은 쿼리로 답한다.
목표는 원인 분석이 아니라 **"오늘 사람이 들여다볼 것이 있는가" 를 근거와 함께 가르는 것**이다. 깊이 파는 일은 `/obs-ask` · `/deploy-triage` 로 넘긴다.
판정은 9 단계의 기준표로만 하고, 결과에 따라 10 단계에서 Slack · GitHub Issue 로 올린다. 클러스터 · AWS 는 어떤 경우에도 바꾸지 않는다.

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
- 재시작 이력만으로는 판정하지 않는다. **지금도 CrashLoop 인가**를 따로 본다:

```
sum by (namespace, pod, container) (max_over_time(kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"}[10m])) > 0
```

- CrashLoop 중인 컨테이너는 재시도하는 잠깐 동안 Running 으로 보여서 그 순간에는 시계열이 없다. 백오프 최대 간격이 5분이므로 최근 10분 안에 한 번이라도 `CrashLoopBackOff` 였으면 "지금도 CrashLoop" 로 본다.
- 결과가 있으면 `확인 필요`. 비어 있으면 재시작이 몇 번이었든 `정상` 이고 횟수는 기록으로만 적는다.

## 3. B2 — NotReady 노드 · Pending Pod · OOMKilled 가 있나

```
kube_node_status_condition{condition="Ready", status!="true"} == 1
sum by (namespace, pod) (kube_pod_status_phase{phase="Pending"}) > 0
sum by (namespace, pod, container) (kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}) * on (namespace, pod, container) group_left sum by (namespace, pod, container) (increase(kube_pod_container_status_restarts_total[24h]))
```

- 앞의 둘은 **지금** 상태다. 비면 "없음".
- 셋째는 "마지막 종료가 OOMKilled 인 컨테이너 × 24시간 재시작 증가분" 이다. `last_terminated_reason` 은 시점이 없어서 재시작 수와 묶어 읽는다. 값이 0 이면 24시간보다 오래된 OOM 이므로 "과거 이력" 으로만 적고, 0 보다 크면 "24시간 안에 OOM 으로 재시작(가정: 마지막 종료 사유 기준)" 으로 적는다.
- 판정: NotReady 노드 · Pending Pod 가 지금 있으면 `확인 필요`. OOMKilled 는 지나간 일이라 `정상` 으로 기록만 한다(지금도 죽고 있으면 B1 의 CrashLoop 에서 잡힌다).

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
- HPA 는 현재 / 최대 replicas 와 24시간 최고 replicas. **지금** 현재가 최대와 같으면(비율 1) `확인 필요`("최대치에 붙어 있음"). 24시간 최고만 최대에 닿았으면 `정상` 이고 "밤사이 최대까지 늘었다가 내려옴" 으로 기록만 한다.

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
  - **기준선 안**: 24시간 실패율과 p95 가 10장 값 안(p95 는 10장이 적은 버킷 상한 이하) — `정상`
  - **기준선 밖 · 목표 안**: 기준선은 넘었지만 9장 목표(가용성 · p95) 안 — `확인 필요`
  - **목표 밖**: 24시간 실패율 또는 24시간 p95 가 9장 목표를 넘었거나, `OrderFailureRateHigh` 가 **지금** firing(어느 단계든) — `즉시 대응`
- 알람이 24시간 안에 firing 했다가 지금은 내려온 경우는 판정을 바꾸지 않고 기록만 한다(24시간 값이 목표를 넘었으면 위 기준으로 이미 `즉시 대응` 이다). pending 은 firing 이 아니다. 단계와 함께 적기만 한다.
- 24시간 값은 정상인데 5분 최고값만 튄 경우는 판정을 바꾸지 않고 "N분 창에서 일시적으로 X" 로 따로 적는다. 정확한 시각이 필요하면 같은 식을 range 조회(step 300초)로 한 번 더 본다.
- ALERTS 가 비면 "firing 이력 없음" 이다(1 단계에서 Prometheus 가 살아 있을 때만).
- p95 는 히스토그램 버킷 보간값이다. 버킷 경계(9장)를 넘었는지로 읽는다.

## 6. 추가 점검 — firing 중인 알람 전체 (Watchdog 제외)

```
sum by (alertname, namespace, severity) (ALERTS{alertstate="firing", alertname!="Watchdog"})
```

- **지금** firing 인 알람이다. `Watchdog` 은 알람 경로가 살아 있음을 보이려고 항상 firing 하는 룰이라 뺀다.
- 비면 "firing 0건" (1 단계에서 Prometheus 가 살아 있을 때만). 한 건이라도 있으면 `확인 필요` 로 알람 이름 · 네임스페이스 · 건수를 적는다. `OrderFailureRateHigh` 는 B4 에서 `즉시 대응` 으로 판정하므로 이 행에서는 세지 않고 B4 를 가리킨다.
- `severity` 는 차트 기본 룰이 붙인 라벨이다. 팀의 알람 등급은 미정(스펙 6장)이므로 등급으로 해석하지 않고 값만 옮긴다.
- 어느 Pod · 노드인지는 `ALERTS{alertstate="firing", alertname="<이름>"}` 로 라벨을 펼쳐 본다.

## 7. 추가 점검 — Collector 전송 실패 (7장 C1)

```
label_replace(sum by (exporter) (increase({__name__=~"otelcol_exporter_(send|enqueue)_failed_spans_total"}[24h])), "signal", "spans", "", "") or label_replace(sum by (exporter) (increase({__name__=~"otelcol_exporter_(send|enqueue)_failed_metric_points_total"}[24h])), "signal", "metric_points", "", "") or label_replace(sum by (exporter) (increase({__name__=~"otelcol_exporter_(send|enqueue)_failed_log_records_total"}[24h])), "signal", "log_records", "", "")
label_replace(sum by (exporter) (increase(otelcol_exporter_sent_spans_total[24h])), "signal", "spans", "", "") or label_replace(sum by (exporter) (increase(otelcol_exporter_sent_metric_points_total[24h])), "signal", "metric_points", "", "") or label_replace(sum by (exporter) (increase(otelcol_exporter_sent_log_records_total[24h])), "signal", "log_records", "", "")
```

- 첫째는 24시간 동안 exporter · 신호별 전송 실패(보내다 실패 + 큐에 못 넣음) 건수, 둘째는 보낸 건수다. 실제 백엔드로 가는 exporter 는 `otlp_grpc/tempo`(spans) · `otlp_http/prometheus`(metric_points) · `otlp_http/loki`(log_records) 셋이다. `debug` 는 화면 출력용이라 판정에서 뺀다.
- 실패 카운터는 한 번도 실패하지 않은 exporter 에는 시계열 자체가 없다. 그래서 **실패가 비거나 0 이고, 같은 exporter 의 보낸 건수가 0 보다 클 때만** "실패 0건" 이다. 보낸 건수까지 비면 "데이터 없음"(`확인 필요`), 세 exporter 중 하나라도 보낸 건수가 0 이면 `확인 필요`(그 신호가 24시간 동안 안 나갔다).
- 24시간 실패가 0 보다 크면 **지금도 실패하는지**를 같은 식의 창만 `[10m]` 으로 바꿔 한 번 더 본다(스펙 5장 "10분간 0"). 10분 창에서도 0 보다 크면 `확인 필요`, 10분 창이 0 · 빈 결과면 `정상` 이고 24시간 건수는 기록만 한다.
- 어느 쪽이든 exporter · 신호 · 건수와 보낸 건수 대비 비율을 적는다. 실패가 있었던 신호를 쓰는 항목(spans → B4)에 "수치가 실제보다 적을 수 있음" 을 덧붙인다.

## 8. 추가 점검 — Argo CD 앱이 전부 Synced · Healthy 인가

```
kubectl get applications.argoproj.io -n argocd -o custom-columns='NAME:.metadata.name,PROJECT:.spec.project,SYNC:.status.sync.status,HEALTH:.status.health.status,AUTO:.spec.syncPolicy.automated,LAST:.status.operationState.finishedAt'
```

- Prometheus 에 Argo CD 메트릭(`argocd_app_info`)이 없어 이 항목만 kubectl 로 본다. 실행 전에 `kubectl config current-context` 가 스펙의 클러스터인지 확인한다. 데이터소스는 "kubectl(Application 리소스)", 시각은 실행 시각으로 적는다.
- 모든 앱이 `Synced` · `Healthy` 면 `정상`. 아닌 앱은 `확인 필요` 로 이름 · Sync · Health 를 적고 다음 단계로 `argocd app get <앱>` 또는 `/deploy-triage` 를 가리킨다.
- `AUTO` 가 `<none>` 인 앱은 수동 Sync 다(`specs/eks-demo.md`: `otel-demo-prod`). `OutOfSync` 여도 자동으로 맞춰지지 않는 것이 설계이므로 "수동 Sync 앱" 이라고 구분해 적는다. 의도된 상태인지는 사람이 판단한다.
- `LAST`(마지막 Sync 완료, UTC)가 24시간 안이면 "지난 24시간 안에 배포 있음" 으로 KST 로 바꿔 적는다. B1 · B4 가 나쁠 때 먼저 볼 단서다.
- `argocd app sync` 는 실행하지 않는다.

## 9. 판정 기준 (세 단계)

판정은 `정상` · `확인 필요` · `즉시 대응` 셋 중 하나다. 원칙은 하나다: **지금 벌어지고 있는 것만 판정을 올린다. 지나간 것은 `정상` 으로 두고 결과 칸에 기록만 한다.**

| 항목 | 즉시 대응 | 확인 필요 | 정상 (기록만) |
| --- | --- | --- | --- |
| B4 주문 | 24시간 실패율 · p95 가 9장 목표를 넘음, 또는 `OrderFailureRateHigh` 가 지금 firing | 10장 기준선은 넘었지만 9장 목표 안 | 기준선 안. 5분 창만 튄 것, 지금은 내려온 알람 firing 이력 |
| B1 재시작 | — | 지금도 CrashLoop (최근 10분) | 재시작은 있었지만 지금은 CrashLoop 아님 |
| B3 HPA | — | 지금 현재 replicas = 최대 | 24시간 최고만 최대에 닿았다가 내려옴 |
| B2 NotReady · Pending · OOMKilled | — | 지금 NotReady 노드 · Pending Pod | 24시간 안의 OOMKilled |
| B3 노드 여유 | — | — | 임계가 스펙에 없어 숫자만 보고 |
| firing 알람 (Watchdog · 주문 알람 제외) | — | 지금 firing | 없음 |
| Collector 전송 실패 | — | 최근 10분에도 실패, 또는 24시간 보낸 건수 0 | 24시간 안에 실패했지만 최근 10분은 0 |
| Argo CD 앱 | — | 지금 Synced · Healthy 가 아닌 앱 (수동 Sync 앱은 구분해 적는다) | 전부 Synced · Healthy |
| C 수집 · 데이터 없음 · 조회 실패 | — | 판정할 데이터가 없는 항목 | — |

- `즉시 대응` 은 **주문(B4)뿐**이다. 다른 항목은 아무리 나빠 보여도 `확인 필요` 까지만 올린다. 등급을 올리는 것은 사람이 정한다(스펙 6장 알람 등급 미정).
- 데이터가 없거나 조회가 실패한 항목은 `정상` 으로 쓰지 않는다. `확인 필요` 로 두고 결과 칸에 "데이터 없음" · "조회 실패" 를 적는다. 주문 메트릭이 비어 B4 를 판정할 수 없을 때도 `확인 필요` 다(`즉시 대응` 으로 올리지 않는다. 근거 수치가 없다).
- 요청자(@TeddySB2)가 정한 것은 주문 · 재시작 · HPA 세 줄과 "지나간 것은 정상으로 기록만" 이다. 나머지 줄은 같은 원칙을 옮겨 적은 구현값이며 PR 에서 확인받는다.
- 한 줄 결론은 가장 높은 판정을 따른다: `즉시 대응` 이 하나라도 있으면 "즉시 대응 N건(· 확인 필요 M건)", 없고 `확인 필요` 가 있으면 "확인 필요 M건", 둘 다 없으면 "정상".

## 10. 에스컬레이션

보고(11 단계)를 **대화에 먼저** 낸 뒤에 한다. 쓰기는 아래 두 가지뿐이고 둘 다 호출마다 사람이 승인한다(`.claude/settings.json` 의 `ask`). 승인이 거절되면 다시 시도하지 않고 "보내지 않음 / 만들지 않음" 으로 보고에 적는다.

### 10-1. 즉시 대응 → Slack `#ops-daily` 에 멘션

- CLAUDE.md "Slack 사용" 을 그대로 지킨다. 채널 ID 는 `slack_list_user_channels`(`name_prefix: "ops-daily"`)로 확인한다. 다른 채널 · DM · 스레드로는 보내지 않는다.
- 멘션 대상은 스펙 승인자(이 Slack MCP 로 로그인한 사람) 한 명이다. Slack 멘션은 `<@멤버ID>` 형식으로 쓴다. 멤버 ID 는 저장소에 적지 않고, 보낼 때마다 Slack MCP 로 로그인한 사용자 프로필을 읽어 확인한다(읽기도 승인). 이름만 글자로 쓰면 멘션이 되지 않는다. 다른 사람은 멘션하지 않는다. `@here` · `@channel` 도 쓰지 않는다.
- 보내기 전에 채널 이름과 메시지 전문을 대화에 보여 준다. 승인 화면의 `channel_id` 가 `#ops-daily` 인지는 사람이 확인한다.
- `즉시 대응` 이 여러 건이어도 메시지는 **한 번** 보낸다. `확인 필요` 항목은 메시지에 넣지 않는다(Issue 로 간다).
- 형식 (수치마다 쿼리 · 시간 범위 · 데이터소스를 붙인다. Secret · 토큰 · 개인정보는 넣지 않는다):

```
<@멤버ID> 아침 점검 <날짜> — 즉시 대응 N건
- 주문 실패율 <값> (목표 <9장 값>) / 주문 p95 <값> (목표 <9장 값>) / OrderFailureRateHigh firing (burn_rate <단계>)
범위: <시작> ~ <끝> KST (24시간) · 데이터소스: Prometheus
쿼리: `<판정에 쓴 쿼리 원문>`
다음: /obs-ask 로 원인 서비스 좁히기. 플래그 상태(`scenarios/flag.sh --list`)는 사람이 확인
```

### 10-2. 확인 필요 → GitHub Issue (같은 건이 열려 있으면 만들지 않는다)

- `확인 필요` 항목 **하나에 Issue 하나**다. 제목이 곧 "같은 건" 을 가르는 키이므로 아래 형식을 글자 그대로 지킨다. 날짜 · 횟수 · Pod 이름의 해시처럼 날마다 바뀌는 값은 제목에 넣지 않는다.

| 항목 | 제목 |
| --- | --- |
| B1 CrashLoop | `[daily-health] CrashLoop: <namespace>/<container>` |
| B3 HPA 최대 | `[daily-health] HPA 최대: <namespace>/<hpa>` |
| B2 NotReady | `[daily-health] NotReady: <node>` |
| B2 Pending | `[daily-health] Pending: <namespace>/<container 또는 워크로드>` |
| B4 기준선 밖 | `[daily-health] 주문 기준선 밖` |
| firing 알람 | `[daily-health] 알람 firing: <alertname> (<namespace>)` |
| Collector | `[daily-health] Collector 전송 실패: <exporter>` |
| Argo CD | `[daily-health] Argo CD: <app>` |
| 데이터 없음 | `[daily-health] 데이터 없음: <항목>` |

- 만들기 전에 열려 있는 Issue 를 **한 번** 조회해 제목을 정확히 비교한다:

```
gh issue list --state open --search '"[daily-health]" in:title' --json number,title,url --limit 100
```

- 같은 제목이 열려 있으면 만들지 않는다. 댓글도 달지 않는다. 보고에 "이미 열려 있음 #번호" 로 적는다. 닫힌 Issue 는 같은 건으로 보지 않는다(다시 생겼으면 새로 만든다).
- 조회가 실패하면 중복 여부를 알 수 없으므로 만들지 않고 "확인 필요(Issue 조회 실패)" 로 보고한다.
- 없으면 만든다. 만들기 전에 제목과 본문 전문을 대화에 보여 준다:

```
gh issue create --title '<위 제목>' --body-file <본문 파일>
```

- 본문: 무엇이 보였는지(리소스 이름 · 수치), 판정 근거(쿼리 원문 · 시간 범위 KST · 데이터소스), 다음에 볼 것(`/obs-ask` · `/deploy-triage` 또는 사람이 실행할 명령), 마지막 줄에 "아침 점검 <날짜> 에서 생성". 원인은 단정하지 않는다. Secret · 토큰 · 개인정보는 넣지 않는다.
- firing 알람이 다른 행과 같은 리소스를 가리키면(예: `KubePodCrashLooping` 과 B1 의 CrashLoop Pod) 그 행의 Issue 본문에 알람을 함께 적고 알람 Issue 는 따로 만들지 않는다.
- 수동 Sync 앱(`AUTO` 가 `<none>`)이 Synced · Healthy 가 아닌 것은 Issue 를 만들지 않는다. 의도된 상태일 수 있어 보고에 구분해 적고 사람이 판단한다.
- 라벨 · 담당자 · 마일스톤은 붙이지 않는다(저장소에 정해진 것이 없다). Issue 를 닫거나 고치는 일은 하지 않는다. 사람이 한다.
- **조회 실패**(Grafana 연결 · 권한 · 타임아웃, kubectl 오류)로 `확인 필요` 가 된 항목은 Issue 를 만들지 않는다. 실행한 사람의 연결 문제일 수 있고 관측한 사실이 없다. 대화의 "확인하지 못한 것" 에만 적는다.

## 11. 보고

```
아침 점검 <날짜> — <한 줄 결론: 정상 / 확인 필요 M건 / 즉시 대응 N건 · 확인 필요 M건>
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
- <즉시 대응 · 확인 필요 항목마다: 무엇을, 다음에 실행할 것(/obs-ask · /deploy-triage 또는 사람이 실행할 명령)>

지나간 것 (기록)
- <판정은 정상이지만 24시간 안에 있었던 일: 재시작 횟수, OOMKilled, HPA 최고치, 5분 창 최고값, 내려온 알람, 그친 전송 실패>

에스컬레이션
- Slack #ops-daily: <보냄(메시지 링크) / 대상 없음 / 보내지 않음(승인 거절 · 실패 사유)>
- GitHub Issue: <항목마다 새로 만듦 #번호 / 이미 열려 있음 #번호 / 만들지 않음(사유)>

확인하지 못한 것
- <데이터 없음, 조회 실패, 가정. 플래그 상태(`scenarios/flag.sh --list`)는 사람이 확인한다>

실행한 쿼리 (원문)
```

- 판정 칸에는 9 단계의 세 값만 쓴다. 한 행에 여러 건이 있으면 가장 높은 판정을 쓴다.
- 원인은 여기서 단정하지 않는다. 보이는 사실(어느 Pod 가 몇 번, 언제)까지만 적는다.
- 복구 · 변경은 하지 않는다. 필요하면 `gitops/` PR 이나 사람이 실행할 명령으로 제안한다.
- 표와 "오늘 볼 것" 까지를 먼저 대화에 내고, 10 단계를 마친 뒤 "에스컬레이션" 칸을 덧붙인다. 이 칸에는 실제로 일어난 일만 적는다(보낼 예정 · 만들 예정이라고 쓰지 않는다).
