#!/usr/bin/env bash
# 알람 단위 테스트: gitops/manifests/observability 의 PrometheusRule 에서 규칙을 꺼내 promtool 로 시나리오를 돌린다.
# 클러스터 없이 돈다. 필요: promtool, python3 + PyYAML
#   ./tests/alerts/run.sh
set -euo pipefail
cd "$(dirname "$0")"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
python3 - "$work" <<'PY'
import sys, yaml, glob, os
out = sys.argv[1]
for f in glob.glob('../../gitops/manifests/observability/*.yaml'):
    d = yaml.safe_load(open(f))
    if d and d.get('kind') == 'PrometheusRule':
        name = os.path.basename(f).replace('.yaml', '.rules.yaml')
        yaml.safe_dump({'groups': d['spec']['groups']}, open(os.path.join(out, name), 'w'), allow_unicode=True)
        print('rules:', name)
PY
cp ./*.test.yaml "$work"/
cd "$work"
for t in *.test.yaml; do promtool test rules "$t"; done
