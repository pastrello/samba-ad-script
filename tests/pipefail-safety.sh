#!/usr/bin/env bash
set -Eeuo pipefail

f="scripts/lib/common.sh"

if grep -nE "smbd.*-b.*\|.*(awk.*exit|head([[:space:]]|$)|grep[[:space:]]+-m)" "$f"; then
    echo "[ERRO] consumidor que encerra cedo após smbd -b voltou ao código" >&2
    exit 1
fi

grep -q "samba_build_option()" "$f"
grep -q "samba_build_option CONFIGFILE" "$f"
grep -q "samba_build_option PRIVATE_DIR" "$f"
grep -q "samba_build_option LOGFILEBASE" "$f"

echo "[OK] pipefail/SIGPIPE regression contract validated"
