#!/usr/bin/env bash
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
