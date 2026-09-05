# Samba AD Script

[![Validate Bash](https://github.com/pastrello/samba-ad-script/actions/workflows/validate.yml/badge.svg)](https://github.com/pastrello/samba-ad-script/actions/workflows/validate.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Rocky Linux 10](https://img.shields.io/badge/Rocky%20Linux-10-10B981)
![Samba](https://img.shields.io/badge/Samba-AD%20DC-0B5CAD)

Scripts para instalar, manter e atualizar um **Samba Active Directory Domain Controller no Rocky Linux 10**, com uma pilha administrativa e de observabilidade totalmente baseada em software open source.

O projeto surgiu de um laboratório prático com o objetivo de tornar um Samba AD compilado do fonte mais fácil de instalar e manter em distribuições RHEL-like, sem esconder o funcionamento do Samba atrás de um appliance.

> **Status:** projeto experimental / pré-1.0. Use primeiro em laboratório. O instalador v0.5 contém melhorias que ainda precisam de validação end-to-end em mais ambientes Rocky Linux 10 antes de ser recomendado para produção.

## O que é instalado

O instalador monta a seguinte pilha:

```text
Rocky Linux 10
│
├── Samba AD DC em /opt/samba
│   ├── Active Directory
│   ├── Kerberos
│   ├── LDAP
│   ├── DNS interno do Samba
│   ├── SYSVOL
│   └── NETLOGON
│
├── Chrony + MS-SNTP / ntp_signd
├── Cockpit
├── LDAP Account Manager Community
├── rsyslog + journald persistente
├── Prometheus + node_exporter
├── Grafana OSS
├── BorgBackup + Restic
└── backup e health-check via systemd timers
```

**Não são instalados:** Webmin, CUPS e BIND9_DLZ. O DNS inicial é o `SAMBA_INTERNAL`.

## Por que o Samba é compilado?

O projeto instala o Samba em `/opt/samba` a partir do fonte oficial e valida a assinatura GPG antes da compilação. Isso mantém o AD DC isolado dos pacotes Samba do sistema e permite controlar a versão usada pelo domínio.

Documentação oficial relevante:

- Samba: https://www.samba.org/
- Downloads: https://download.samba.org/pub/samba/stable/
- Samba Wiki: https://wiki.samba.org/
- Rocky Linux: https://rockylinux.org/
- LDAP Account Manager: https://www.ldap-account-manager.org/
- Cockpit: https://cockpit-project.org/
- Prometheus: https://prometheus.io/
- Grafana OSS: https://grafana.com/oss/grafana/

## Quick start

Use uma **VM Rocky Linux 10 nova**, com IP estático e DNS/networking previamente definidos.

```bash
git clone https://github.com/pastrello/samba-ad-script.git
cd samba-ad-script
chmod +x scripts/*.sh
sudo ./scripts/install.sh
```

Exemplo não interativo:

```bash
sudo \
  HOSTNAME_SHORT=dc1 \
  AD_DNS_DOMAIN=ad.empresa.com.br \
  NETBIOS_DOMAIN=EMPRESA \
  DC_IP=192.168.10.10 \
  DNS_FORWARDER=192.168.10.1 \
  CLIENT_CIDRS="192.168.10.0/24,192.168.20.0/24" \
  MGMT_CIDRS="192.168.10.0/24" \
  ./scripts/install.sh
```

A senha do `Administrator` do domínio é solicitada de forma oculta.

Leia antes: **[Guia de instalação](docs/INSTALLATION.md)**.

## Upgrade do Samba

O atualizador foi feito para preservar os parâmetros registrados pelo instalador, compilar a nova versão com o DC online e reduzir a indisponibilidade ao momento de instalação/restart.

Auditoria sem alterações:

```bash
sudo ./scripts/upgrade.sh --audit
```

Upgrade de patch na mesma série:

```bash
sudo ./scripts/upgrade.sh 4.24.6
```

Mudanças de série, por exemplo `4.24 -> 4.25`, são bloqueadas por padrão e exigem uma opção explícita após leitura das release notes.

Leia: **[Guia de upgrade](docs/UPGRADE.md)**.

## Segurança por padrão

O projeto procura manter alguns princípios simples:

- SELinux **não é desativado**;
- `firewalld` permanece ativo;
- redes de clientes e administração são restritas por CIDR;
- `0.0.0.0/0` é bloqueado por padrão;
- zonas `trusted`/`ACCEPT` do firewalld são recusadas por padrão;
- fonte do Samba é validado por GPG;
- build do Samba é executado com usuário sem privilégios;
- Prometheus e node_exporter ficam restritos ao loopback;
- LAM e Grafana usam HTTPS;
- backups consistentes do AD são criados com `samba-tool domain backup`;
- o upgrade cria snapshot de rollback antes do `make install`.

Veja **[SECURITY.md](SECURITY.md)** para limites e política de reporte.

## Interfaces após a instalação

Por padrão:

```text
Cockpit : https://IP_DO_DC:9090/
LAM     : https://FQDN_DO_DC/lam/
Grafana : https://FQDN_DO_DC:3000/

Prometheus   : 127.0.0.1:9091
node_exporter: 127.0.0.1:9100
```

LAM/Grafana começam com certificado administrativo self-signed. O instalador informa onde encontrar o certificado para importação nos clientes.

## Estrutura do repositório

```text
.
├── scripts/
│   ├── install.sh
│   └── upgrade.sh
├── docs/
│   ├── ARCHITECTURE.md
│   ├── INSTALLATION.md
│   ├── UPGRADE.md
│   ├── BACKUP-RESTORE.md
│   ├── TROUBLESHOOTING.md
│   └── ROADMAP.md
├── .github/
│   ├── workflows/
│   └── ISSUE_TEMPLATE/
├── CHANGELOG.md
├── CONTRIBUTING.md
├── SECURITY.md
└── LICENSE
```

## Estado de testes

| Item | Estado |
|---|---|
| Rocky Linux 10 | alvo principal |
| Samba 4.24.x | alvo atual |
| Provisionamento de AD/DNS/Kerberos | validado em laboratório |
| FSMO / dbcheck / SRV LDAP/Kerberos | validado em laboratório |
| Instalador v0.5 completo | aguardando mais testes end-to-end |
| Upgrade v1.1 | auditoria disponível; upgrade real depende de uma versão Samba posterior |
| Multi-DC | roadmap |
| BIND9_DLZ | roadmap / opcional futuro |

Esse quadro é deliberadamente conservador: um teste bem-sucedido em laboratório não equivale a suporte de produção.

## Contribuindo

Issues e pull requests são bem-vindos. Antes de enviar mudanças, leia **[CONTRIBUTING.md](CONTRIBUTING.md)**.

Em especial, não envie senhas, dumps de `sam.ldb`, chaves privadas, logs com credenciais ou informações de um domínio real sem sanitização.

## Licença

MIT. Consulte [LICENSE](LICENSE).

## Aviso

Este projeto é independente e não é afiliado ao Samba Team, Rocky Linux, LDAP Account Manager, Grafana Labs, Prometheus ou Red Hat. Os nomes pertencem aos respectivos projetos/proprietários.
