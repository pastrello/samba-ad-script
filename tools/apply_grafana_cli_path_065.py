#!/usr/bin/env python3
from pathlib import Path

p = Path('scripts/lib/common.sh')
s = p.read_text()

s = s.replace('INSTALLER_REVISION="${INSTALLER_REVISION:-0.6.4}"', 'INSTALLER_REVISION="${INSTALLER_REVISION:-0.6.5}"', 1)

marker = '''install_monitoring() {
'''
helper = r'''find_grafana_binary() {
    local resolved="" candidate

    if resolved="$(command -v grafana 2>/dev/null)" && [[ -n "$resolved" && -x "$resolved" ]]; then
        printf '%s\n' "$resolved"
        return 0
    fi

    # Pacotes oficiais DEB/RPM atuais instalam o binário principal aqui.
    # Mantemos /usr/bin/grafana como fallback para layouts que forneçam symlink.
    for candidate in /usr/share/grafana/bin/grafana /usr/bin/grafana; do
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}


install_monitoring() {
'''
if 'find_grafana_binary() {' not in s:
    if marker not in s:
        raise SystemExit('install_monitoring marker not found')
    s = s.replace(marker, helper, 1)

old = r'''    printf '%s\n' "$GRAFANA_ADMIN_PASSWORD" | \
        /usr/bin/grafana cli --homepath /usr/share/grafana --config /etc/grafana/grafana.ini \
        admin reset-admin-password --password-from-stdin >/dev/null
'''
new = r'''    local grafana_bin
    if ! grafana_bin="$(find_grafana_binary)"; then
        die "Binário principal do Grafana não encontrado após a instalação."
    fi

    printf '%s\n' "$GRAFANA_ADMIN_PASSWORD" | \
        "$grafana_bin" cli --homepath /usr/share/grafana --config /etc/grafana/grafana.ini \
        admin reset-admin-password --password-from-stdin >/dev/null
'''
if old not in s:
    raise SystemExit('hardcoded Grafana CLI block not found')
s = s.replace(old, new, 1)
p.write_text(s)

p = Path('scripts/install.sh')
s = p.read_text()
s = s.replace('Samba AD Script - installer 0.6.4', 'Samba AD Script - installer 0.6.5', 1)
s = s.replace('INSTALLER_REVISION="0.6.4"', 'INSTALLER_REVISION="0.6.5"', 1)
p.write_text(s)

p = Path('CHANGELOG.md')
s = p.read_text()
if '## Installer 0.6.5 — 2026-09-05' not in s:
    marker = '## Installer 0.6.4 — 2026-09-05\n'
    entry = '''## Installer 0.6.5 — 2026-09-05

### Fixed
- remove o caminho fixo `/usr/bin/grafana` usado para resetar a senha administrativa;
- detecta o binário principal do Grafana pelo `PATH` e pelo layout atual de pacotes em `/usr/share/grafana/bin/grafana`;
- mantém `grafana cli ... --password-from-stdin`, sem expor a senha na linha de comando;
- adiciona teste de regressão para impedir retorno do caminho fixo;
- mantém `STATE_FORMAT_VERSION=3`, permitindo retomar instalações 0.6.4 interrompidas na etapa de monitoramento.

'''
    if marker not in s:
        raise SystemExit('0.6.4 changelog marker not found')
    s = s.replace(marker, entry + marker, 1)
p.write_text(s)

Path('tests/grafana-cli-path.sh').write_text(r'''#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
common="${repo_root}/scripts/lib/common.sh"

grep -Fq 'find_grafana_binary() {' "$common" || {
    echo '[ERRO] helper find_grafana_binary ausente' >&2
    exit 1
}
grep -Fq '/usr/share/grafana/bin/grafana' "$common" || {
    echo '[ERRO] layout atual do pacote Grafana não contemplado' >&2
    exit 1
}
grep -Fq '"$grafana_bin" cli --homepath /usr/share/grafana' "$common" || {
    echo '[ERRO] reset da senha não usa o binário detectado' >&2
    exit 1
}
if grep -Eq '^[[:space:]]*/usr/bin/grafana[[:space:]]+cli' "$common"; then
    echo '[ERRO] regressão: chamada fixa /usr/bin/grafana cli encontrada' >&2
    exit 1
fi
grep -Fq -- '--password-from-stdin' "$common" || {
    echo '[ERRO] reset da senha deixou de usar stdin' >&2
    exit 1
}

echo '[OK] Grafana CLI path contract validated'
''')
