# Contributing

Obrigado por considerar contribuir com o Samba AD Script.

Este projeto mexe com autenticação, DNS, Kerberos, firewall e backups. Mudanças devem privilegiar comportamento previsível e falha segura.

## Arquitetura

Não adicione condicionais de distribuição espalhadas em `common.sh` se a diferença puder ser tratada por adapter.

```text
scripts/lib/common.sh
scripts/lib/distro-rocky.sh
scripts/lib/distro-ubuntu.sh
```

Novos adapters devem implementar o mesmo contrato validado em `tests/platform-detection.sh`.

## Validação mínima

```bash
bash -n scripts/install.sh
bash -n scripts/lib/common.sh
bash -n scripts/lib/distro-rocky.sh
bash -n scripts/lib/distro-ubuntu.sh
bash -n scripts/upgrade.sh
bash -n tests/platform-detection.sh
./tests/platform-detection.sh
```

Se `shellcheck` estiver disponível, use-o também.

## Teste end-to-end

Em mudanças de plataforma, informe:

- distribuição e release exatas;
- VM limpa ou reaproveitada;
- método de rede/resolver;
- firewall e mecanismo MAC ativos;
- versão Samba;
- `samba-tool dbcheck --cross-ncs`;
- SRV LDAP/Kerberos/GC;
- teste Kerberos e SYSVOL;
- estado de LAM/Grafana/Prometheus;
- teste do backup.

## Estilo

- `set -Eeuo pipefail`;
- erros com ação corretiva;
- operações destrutivas explícitas;
- não esconder erro crítico com `|| true` sem justificativa;
- downloads com autenticidade/integridade quando possível;
- preservar compatibilidade do manifesto/upgrader.

## Dados sensíveis

Nunca envie senha Administrator, `sam.ldb`, chaves privadas, tickets Kerberos, secrets do Grafana/LAM ou dumps LDAP reais.

Use exemplos reservados como `ad.example.com` e `192.0.2.10`.
