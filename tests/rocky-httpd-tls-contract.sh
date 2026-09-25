#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
rocky="${repo_root}/scripts/lib/distro-rocky.sh"

required=(
  'local stock_ssl_conf="/etc/httpd/conf.d/ssl.conf"'
  'local stock_ssl_backup="/etc/httpd/conf.d/ssl.conf.samba-ad-original"'
  'local stock_ssl_disabled="/etc/httpd/conf.d/ssl.conf.disabled-by-samba-ad"'
  'cp -a "$stock_ssl_conf" "$stock_ssl_backup"'
  'mv -f "$stock_ssl_conf" "$stock_ssl_disabled"'
  'Listen 443 https'
  'httpd -t'
)

for needle in "${required[@]}"; do
    grep -Fq "$needle" "$rocky" || {
        echo "[ERRO] contrato Rocky/httpd ausente: $needle" >&2
        exit 1
    }
done

if grep -Fq 'install_pkg_optional php-curl' "$rocky"; then
    echo "[ERRO] Rocky 10 não deve tentar instalar o pacote separado php-curl." >&2
    exit 1
fi

python3 - "$rocky" <<'PY'
from pathlib import Path
import sys

s = Path(sys.argv[1]).read_text()
start = s.index("distro_configure_lam_webserver() {")
end = s.index("distro_install_monitoring_packages() {", start)
block = s[start:end]

assert block.index('mv -f "$stock_ssl_conf" "$stock_ssl_disabled"') < block.index("\n    httpd -t\n")
assert block.index("Listen 443 https") < block.index("\n    httpd -t\n")
assert "/etc/pki/tls/certs/localhost.crt" in block
PY

echo "[OK] Rocky Apache TLS contract validated"
