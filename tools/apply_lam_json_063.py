#!/usr/bin/env python3
from pathlib import Path

p = Path('scripts/lib/common.sh')
s = p.read_text()

old = '''    python3 - /var/www/html/lam/config/config.cfg "$lam_password_ssha" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
new_hash = sys.argv[2]
lines = path.read_text().splitlines()
done = False
out = []
for line in lines:
    if line.lstrip().startswith("password:"):
        out.append("password: " + new_hash)
        done = True
    else:
        out.append(line)
if not done:
    raise SystemExit("Linha 'password:' não encontrada no config.cfg do LAM")
path.write_text("\\n".join(out) + "\\n")
PY
'''

new = '''    # LAM 9.5.2/9.6 usa config.cfg em JSON e o sample não contém a chave
    # "password". O hash é enviado por ambiente para não aparecer na linha de
    # comando e o utilitário grava o JSON de forma atômica.
    LAM_PASSWORD_HASH="$lam_password_ssha" \\
        python3 "${SCRIPT_DIR}/lib/lam_config_json.py" /var/www/html/lam/config/config.cfg
'''

if old not in s:
    raise SystemExit('legacy LAM password block not found')
s = s.replace(old, new, 1)
s = s.replace('INSTALLER_REVISION="${INSTALLER_REVISION:-0.6.2}"', 'INSTALLER_REVISION="${INSTALLER_REVISION:-0.6.3}"', 1)
p.write_text(s)

p = Path('scripts/install.sh')
s = p.read_text()
s = s.replace('Samba AD Script - installer 0.6.2', 'Samba AD Script - installer 0.6.3', 1)
s = s.replace('INSTALLER_REVISION="0.6.2"', 'INSTALLER_REVISION="0.6.3"', 1)
p.write_text(s)

p = Path('CHANGELOG.md')
s = p.read_text()
if '## Installer 0.6.3 — 2026-09-05' not in s:
    marker = '## Installer 0.6.2 — 2026-09-05\n'
    entry = '''## Installer 0.6.3 — 2026-09-05

### Fixed
- corrige a configuração da senha mestre do LDAP Account Manager 9.6/9.5.2, cujo `config.cfg` é JSON e não possui uma linha `password:` no arquivo sample;
- adiciona/atualiza a chave JSON `password` preservando um arquivo válido e usando gravação atômica;
- mantém o hash fora da linha de comando e valida o JSON após a gravação;
- adiciona teste de regressão para criação, atualização e rejeição de configuração inválida;
- mantém `STATE_FORMAT_VERSION=3`, permitindo retomar instalações 0.6.2 interrompidas na etapa LAM sem reprovisionar o domínio ou recompilar o Samba.

'''
    if marker not in s:
        raise SystemExit('0.6.2 changelog marker not found')
    s = s.replace(marker, entry + marker, 1)
p.write_text(s)

Path('scripts/lib/lam_config_json.py').write_text(r'''#!/usr/bin/env python3
"""Safely set the LAM master-password hash in config.cfg (JSON)."""

from __future__ import annotations

import json
import os
from pathlib import Path
import sys


def fail(message: str) -> int:
    print(f"[ERRO] {message}", file=sys.stderr)
    return 1


def main() -> int:
    if len(sys.argv) != 2:
        return fail("Uso: lam_config_json.py /caminho/config.cfg")

    path = Path(sys.argv[1])
    password_hash = os.environ.get("LAM_PASSWORD_HASH", "")
    if not password_hash:
        return fail("LAM_PASSWORD_HASH não informado.")
    if not path.is_file():
        return fail(f"Arquivo de configuração do LAM não encontrado: {path}")

    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        return fail(f"config.cfg do LAM não é JSON válido: {exc}")

    if not isinstance(data, dict):
        return fail("config.cfg do LAM deve conter um objeto JSON no nível raiz.")

    data["password"] = password_hash
    tmp = path.with_name(path.name + ".tmp")

    try:
        tmp.write_text(
            json.dumps(data, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except OSError as exc:
        try:
            tmp.unlink(missing_ok=True)
        except OSError:
            pass
        return fail(f"Não foi possível gravar config.cfg do LAM: {exc}")

    try:
        check = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        return fail(f"Falha ao validar config.cfg após gravação: {exc}")

    if not isinstance(check, dict) or check.get("password") != password_hash:
        return fail("A chave 'password' não foi persistida corretamente no config.cfg do LAM.")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
''')

Path('tests/lam-config-json.sh').write_text(r'''#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tool="${repo_root}/scripts/lib/lam_config_json.py"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/config.cfg" <<'JSON'
{
  "default": "lam",
  "sessionTimeout": "30",
  "logLevel": "4"
}
JSON

hash1='{SSHA}ZmFrZWhhc2gx ZmFrZXNhbHQx'
LAM_PASSWORD_HASH="$hash1" python3 "$tool" "$tmp/config.cfg"
python3 - "$tmp/config.cfg" "$hash1" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
assert data["default"] == "lam"
assert data["sessionTimeout"] == "30"
assert data["password"] == sys.argv[2]
PY

hash2='{SSHA}ZmFrZWhhc2gy ZmFrZXNhbHQy'
LAM_PASSWORD_HASH="$hash2" python3 "$tool" "$tmp/config.cfg"
python3 - "$tmp/config.cfg" "$hash2" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
assert data["password"] == sys.argv[2]
PY

printf 'password: legacy\n' >"$tmp/invalid.cfg"
if LAM_PASSWORD_HASH="$hash1" python3 "$tool" "$tmp/invalid.cfg" >/dev/null 2>&1; then
    echo "[ERRO] configuração LAM não JSON foi aceita" >&2
    exit 1
fi

if grep -n "Linha 'password:' não encontrada" "${repo_root}/scripts/lib/common.sh"; then
    echo "[ERRO] parser legado de password: voltou ao common.sh" >&2
    exit 1
fi

echo "[OK] LAM JSON config contract validated"
''')
