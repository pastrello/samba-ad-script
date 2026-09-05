#!/usr/bin/env bash
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
