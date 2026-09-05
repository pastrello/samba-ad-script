#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
common="${repo_root}/scripts/lib/common.sh"

required=(
  'chown root:grafana /etc/grafana/provisioning /etc/grafana/provisioning/datasources'
  'chmod 750 /etc/grafana/provisioning /etc/grafana/provisioning/datasources'
  'chown root:grafana /etc/grafana/provisioning/datasources/prometheus.yml'
  'chmod 640 /etc/grafana/provisioning/datasources/prometheus.yml'
  'runuser -u grafana -- test -r /etc/grafana/provisioning/datasources/prometheus.yml'
)

for needle in "${required[@]}"; do
    grep -Fq "$needle" "$common" || {
        echo "[ERRO] contrato de permissões Grafana ausente: $needle" >&2
        exit 1
    }
done

python3 - "$common" <<'PY'
from pathlib import Path
import sys
s = Path(sys.argv[1]).read_text()
start = s.index('cat >/etc/grafana/provisioning/datasources/prometheus.yml')
end = s.index('local fqdn="${HOSTNAME_SHORT}.${AD_DNS_DOMAIN}"', start)
block = s[start:end]
assert 'chown root:grafana /etc/grafana/provisioning/datasources/prometheus.yml' in block
assert 'chmod 640 /etc/grafana/provisioning/datasources/prometheus.yml' in block
assert 'runuser -u grafana -- test -r /etc/grafana/provisioning/datasources/prometheus.yml' in block
PY

echo "[OK] Grafana provisioning permissions contract validated"
