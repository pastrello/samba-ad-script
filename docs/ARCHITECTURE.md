# Arquitetura

## Visão geral

O projeto mantém o Samba AD isolado em `/opt/samba`, enquanto serviços auxiliares continuam integrados ao Rocky Linux através de RPMs/systemd.

```text
                           Windows / RSAT
                                │
               DNS / Kerberos / LDAP / SMB
                                │
                                ▼
                       Samba AD DC
                       /opt/samba
                      ┌────────────┐
                      │ DNS interno│
                      │ Kerberos   │
                      │ LDAP       │
                      │ SYSVOL     │
                      │ NETLOGON   │
                      └────────────┘
                         │       │
                  Chrony │       │ LDAPS
                         │       ▼
                         │      LAM
                         │    HTTPS :443
                         │
        ┌────────────────┴────────────────┐
        │                                 │
    systemd/journal                  health/backup
                                          │
                          ┌───────────────┴──────────────┐
                          │                              │
                  samba-tool domain backup        config snapshot
                          │
                          ▼
                 /var/backups/samba-ad

        node_exporter                Prometheus
        127.0.0.1:9100 ───────────► 127.0.0.1:9091
                                          │
                                          ▼
                                      Grafana
                                     HTTPS :3000

        Cockpit
        HTTPS :9090
```

## Samba

O Samba é compilado do fonte oficial e instalado em:

```text
/opt/samba
```

O serviço principal é:

```text
samba-ad-dc.service
```

O instalador registra metadados em:

```text
/etc/samba-ad/installation.env
/etc/samba-ad/build-info.txt
```

Esses arquivos são consumidos pelo atualizador para preservar os parâmetros de build.

## DNS

A implementação inicial usa:

```text
SAMBA_INTERNAL
```

O DNS forwarder é configurado no Samba para consultas externas. Clientes Windows do domínio devem usar o(s) DNS do AD, e não DNS público diretamente.

BIND9_DLZ não faz parte do escopo inicial.

## Portas

Portas típicas do AD são liberadas somente para `CLIENT_CIDRS`. As interfaces administrativas são limitadas a `MGMT_CIDRS`.

Serviços locais:

| Serviço | Bind |
|---|---|
| Prometheus | `127.0.0.1:9091` |
| node_exporter | `127.0.0.1:9100` |

Interfaces administrativas:

| Serviço | Porta |
|---|---:|
| HTTPS/LAM | 443 |
| Cockpit | 9090 |
| Grafana | 3000 |

As portas do AD incluem DNS, Kerberos, LDAP, SMB, Global Catalog e faixa RPC dinâmica. Consulte o `scripts/install.sh` para a lista efetivamente aplicada.

## TLS

LAM e Grafana usam um certificado administrativo self-signed criado durante a instalação. O Samba também gera material TLS próprio para LDAPS.

Em produção, considere substituir o certificado administrativo por uma CA corporativa ou outra cadeia confiável.

## Backups

Dois conceitos são separados:

1. **Backup lógico/consistente do domínio**, via `samba-tool domain backup`.
2. **Snapshot de rollback do prefixo**, usado pelo atualizador durante uma janela de manutenção.

BorgBackup e Restic são instalados, mas o destino remoto não é configurado automaticamente.

## Upgrade

O build da nova versão ocorre com o DC online. A janela de indisponibilidade começa somente após:

- download;
- GPG;
- `configure`;
- `make`;
- `dbcheck`;
- backup do AD.

Na janela crítica:

```text
stop Samba
→ snapshot consistente /opt/samba
→ make install
→ testparm
→ start Samba
```

Se a instalação/start falhar antes de o novo serviço ficar estável, o script tenta restaurar o snapshot anterior.
