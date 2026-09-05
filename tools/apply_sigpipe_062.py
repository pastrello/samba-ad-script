#!/usr/bin/env python3
from pathlib import Path

p = Path('scripts/lib/common.sh')
s = p.read_text()

helper = '''samba_build_option() {
    local key="$1"
    local build_info

    # Avoid producer pipelines here. With pipefail, an early-exiting
    # consumer can make smbd receive SIGPIPE and return 141.
    build_info="$("${SAMBA_PREFIX}/sbin/smbd" -b 2>/dev/null)" || return 1
    awk -F': ' -v key="$key" '$1 ~ "^[[:space:]]*" key "$" {print $2}' <<<"$build_info"
}

'''
marker = 'provision_domain() {\n'
if 'samba_build_option() {' not in s:
    if marker not in s:
        raise SystemExit('provision_domain marker not found')
    s = s.replace(marker, helper + marker, 1)

replacements = {
    'smb_conf="$("${SAMBA_PREFIX}/sbin/smbd" -b | awk -F\': \' \'/CONFIGFILE:/ {print $2; exit}\')"': 'smb_conf="$(samba_build_option CONFIGFILE)"',
    'private_dir="$("${SAMBA_PREFIX}/sbin/smbd" -b | awk -F\': \' \'/PRIVATE_DIR:/ {print $2; exit}\')"': 'private_dir="$(samba_build_option PRIVATE_DIR)"',
    'samba_logbase="$("${SAMBA_PREFIX}/sbin/smbd" -b 2>/dev/null | awk -F\': \' \'/LOGFILEBASE:/ {print $2; exit}\' || true)"': 'samba_logbase="$(samba_build_option LOGFILEBASE || true)"',
}
for old, new in replacements.items():
    s = s.replace(old, new)

for needle in (
    "| awk -F': ' '/CONFIGFILE:/ {print $2; exit}'",
    "| awk -F': ' '/PRIVATE_DIR:/ {print $2; exit}'",
    "| awk -F': ' '/LOGFILEBASE:/ {print $2; exit}'",
):
    if needle in s:
        raise SystemExit(f'early-exit smbd pipeline remains: {needle}')

s = s.replace('INSTALLER_REVISION="${INSTALLER_REVISION:-0.6.1}"', 'INSTALLER_REVISION="${INSTALLER_REVISION:-0.6.2}"', 1)
p.write_text(s)

p = Path('scripts/install.sh')
s = p.read_text()
s = s.replace('Samba AD Script - installer 0.6.1', 'Samba AD Script - installer 0.6.2', 1)
s = s.replace('INSTALLER_REVISION="0.6.1"', 'INSTALLER_REVISION="0.6.2"', 1)
p.write_text(s)

p = Path('CHANGELOG.md')
s = p.read_text()
if '## Installer 0.6.2 — 2026-09-05' not in s:
    entry = '''## Installer 0.6.2 — 2026-09-05

### Fixed
- corrige `SIGPIPE`/exit 141 ao iniciar `samba_provision` com `set -o pipefail`;
- centraliza a leitura de `smbd -b` em `samba_build_option()`, sem pipeline com consumidor que encerra cedo;
- corrige o mesmo padrão latente nas rotinas de TLS, logrotate e health-check;
- mantém compatibilidade com checkpoint v3, permitindo retomar uma instalação 0.6/0.6.1 que já concluiu o build do Samba;
- adiciona teste de regressão contra consumidores que encerram cedo (`awk ... exit`, `head`, `grep -m`) após `smbd -b`.

'''
    marker = '## Installer 0.6.1 — 2026-09-05\n'
    if marker not in s:
        raise SystemExit('changelog marker not found')
    s = s.replace(marker, entry + marker, 1)
p.write_text(s)

Path('tests/pipefail-safety.sh').write_text('''#!/usr/bin/env bash
set -Eeuo pipefail

f="scripts/lib/common.sh"

if grep -nE "smbd.*-b.*\\|.*(awk.*exit|head([[:space:]]|$)|grep[[:space:]]+-m)" "$f"; then
    echo "[ERRO] consumidor que encerra cedo após smbd -b voltou ao código" >&2
    exit 1
fi

grep -q "samba_build_option()" "$f"
grep -q "samba_build_option CONFIGFILE" "$f"
grep -q "samba_build_option PRIVATE_DIR" "$f"
grep -q "samba_build_option LOGFILEBASE" "$f"

echo "[OK] pipefail/SIGPIPE regression contract validated"
''')
