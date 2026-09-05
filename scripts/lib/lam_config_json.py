#!/usr/bin/env python3
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
