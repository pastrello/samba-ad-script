# Contributing

Obrigado por considerar contribuir com o Samba AD Script.

## Antes de começar

Este projeto mexe com autenticação, DNS, Kerberos, firewall e backups. Uma alteração aparentemente pequena pode impedir o boot do serviço ou o login de um domínio inteiro. Por isso, mudanças devem privilegiar comportamento previsível e falha segura.

## Fluxo recomendado

1. Abra uma issue para bugs ou mudanças grandes.
2. Faça fork/branch da `main`.
3. Mantenha cada PR focado em um problema.
4. Explique como a mudança foi testada.
5. Não remova proteções de segurança apenas para contornar uma falha.

## Validação mínima

Antes do PR:

```bash
bash -n scripts/install.sh
bash -n scripts/upgrade.sh
```

Se `shellcheck` estiver disponível:

```bash
shellcheck -x scripts/install.sh scripts/upgrade.sh
```

Para mudanças no instalador, informe pelo menos:

- versão exata do Rocky Linux;
- versão do Samba;
- se a VM era limpa ou reaproveitada;
- modo SELinux;
- resultado de `samba-tool dbcheck --cross-ncs`;
- resultado dos testes DNS SRV relevantes.

## Estilo

- Bash com `set -Eeuo pipefail`;
- nomes de funções/variáveis descritivos;
- mensagens de erro que expliquem a ação corretiva;
- operações destrutivas devem ser explícitas;
- não mascarar erros críticos com `|| true` sem justificativa;
- novos downloads devem ter verificação de integridade/autenticidade quando possível.

## Dados sensíveis

Nunca inclua em issues, PRs ou commits:

- senha do `Administrator`;
- `/opt/samba/private/sam.ldb`;
- chaves privadas;
- arquivos de secrets do Grafana/LAM;
- tickets Kerberos;
- dumps LDAP não sanitizados;
- IPs/domínios reais quando a organização não autorizou a publicação.

Use valores fictícios como:

```text
ad.example.com
dc1.ad.example.com
192.0.2.10
```

## Compatibilidade

Mudanças que alterem caminhos, manifesto ou parâmetros de build precisam considerar compatibilidade com `scripts/upgrade.sh`.

Até o projeto atingir 1.0, mudanças incompatíveis ainda podem acontecer, mas devem ser documentadas no `CHANGELOG.md`.
