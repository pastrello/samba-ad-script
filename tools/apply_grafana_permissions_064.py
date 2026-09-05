#!/usr/bin/env python3
from pathlib import Path

p = Path('scripts/lib/common.sh')
s = p.read_text()

s = s.replace('INSTALLER_REVISION="${INSTALLER_REVISION:-0.6.3}"', 'INSTALLER_REVISION="${INSTALLER_REVISION:-0.6.4}"', 1)

old = '''    mkdir -p /etc/grafana/provisioning/datasources
    cat >/etc/grafana/provisioning/datasources/prometheus.yml <<'EOF'
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://127.0.0.1:9091
    isDefault: true
    editable: true
EOF

    local fqdn="${HOSTNAME_SHORT}.${AD_DNS_DOMAIN}"
'''

new = '''    mkdir -p /etc/grafana/provisioning/datasources
    cat >/etc/grafana/provisioning/datasources/prometheus.yml <<'EOF'
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://127.0.0.1:9091
    isDefault: true
    editable: true
EOF

    # O instalador roda com umask 027. Sem ownership explícito, arquivos e
    # diretórios de provisioning criados aqui podem ficar root:root e o usuário
    # grafana não consegue atravessar/ler prometheus.yml, entrando em restart loop.
    chown root:grafana /etc/grafana/provisioning /etc/grafana/provisioning/datasources
    chmod 750 /etc/grafana/provisioning /etc/grafana/provisioning/datasources
    chown root:grafana /etc/grafana/provisioning/datasources/prometheus.yml
    chmod 640 /etc/grafana/provisioning/datasources/prometheus.yml

    if command -v runuser >/dev/null 2>&1; then
        runuser -u grafana -- test -r /etc/grafana/provisioning/datasources/prometheus.yml || \
            die "Usuário grafana não consegue ler o datasource provisionado."
    fi

    local fqdn="${HOSTNAME_SHORT}.${AD_DNS_DOMAIN}"
'''

if old not in s:
    raise SystemExit('Grafana datasource block not found')
s = s.replace(old, new, 1)
p.write_text(s)

p = Path('scripts/install.sh')
s = p.read_text()
s = s.replace('Samba AD Script - installer 0.6.3', 'Samba AD Script - installer 0.6.4', 1)
s = s.replace('INSTALLER_REVISION="0.6.3"', 'INSTALLER_REVISION="0.6.4"', 1)
p.write_text(s)

p = Path('CHANGELOG.md')
s = p.read_text()
if '## Installer 0.6.4 — 2026-09-05' not in s:
    marker = '## Installer 0.6.3 — 2026-09-05\n'
    entry = '''## Installer 0.6.4 — 2026-09-05

### Fixed
- corrige permissões do datasource do Grafana criado pelo instalador com `umask 027`;
- garante `root:grafana`, diretórios `0750` e `prometheus.yml` `0640`, permitindo que o serviço leia o provisioning sem abrir permissões para outros usuários;
- valida a leitura do datasource como usuário `grafana` antes de iniciar o serviço;
- mantém `STATE_FORMAT_VERSION=3`, permitindo retomar instalações 0.6.3 interrompidas na etapa de monitoramento.

'''
    if marker not in s:
        raise SystemExit('0.6.3 changelog marker not found')
    s = s.replace(marker, entry + marker, 1)
p.write_text(s)

Path('tests/grafana-provisioning-permissions.sh').write_text(r'''#!/usr/bin/env bash
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
''')
