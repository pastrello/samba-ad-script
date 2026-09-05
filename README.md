# Samba AD Script

[![Validate Bash](https://github.com/pastrello/samba-ad-script/actions/workflows/validate.yml/badge.svg)](https://github.com/pastrello/samba-ad-script/actions/workflows/validate.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Rocky Linux 10](https://img.shields.io/badge/Rocky%20Linux-10-10B981)
![Ubuntu LTS](https://img.shields.io/badge/Ubuntu-22.04%20%7C%2024.04-E95420)
![Samba](https://img.shields.io/badge/Samba-AD%20DC-0B5CAD)

Scripts para instalar, manter e atualizar um **Samba Active Directory Domain Controller** compilado do fonte oficial, com uma pilha administrativa e de observabilidade baseada em software open source.

O instalador 0.6 introduz uma arquitetura por adapters de distribuição. O núcleo do Samba/AD permanece comum e a integração com pacotes, firewall, resolver, servidor web e mecanismo MAC é tratada por plataforma.

> **Status:** projeto experimental / pré-1.0. Rocky Linux 10 possui validação real de laboratório em versões anteriores do instalador. Os adapters Ubuntu 22.04/24.04 possuem validação estática/CI e ainda precisam de testes end-to-end em VMs limpas antes de recomendação para produção.

## Matriz de suporte

| Plataforma | Tier | Estado |
|---|---|---|
| Rocky Linux 10.x | supported | base original; validação de laboratório disponível |
| Ubuntu Server 22.04 LTS | supported | adapter implementado; validação end-to-end pendente |
| Ubuntu Server 24.04 LTS | supported | adapter implementado; validação end-to-end pendente |
| Ubuntu > 24.04 | experimental | aceito com aviso; não faz parte da matriz principal |
| outras distribuições | unsupported | adapter ainda não implementado |

O comando abaixo não altera o servidor e mostra como a plataforma foi classificada:

```bash
sudo ./scripts/install.sh --check-platform
```

## O que é instalado

```text
Rocky Linux 10 / Ubuntu Server 22.04 ou 24.04
│
├── Samba AD DC em /opt/samba
│   ├── Active Directory
│   ├── Kerberos
│   ├── LDAP / LDAPS
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

**Não são instalados:** Webmin, CUPS e BIND9_DLZ. O backend DNS inicial é `SAMBA_INTERNAL`.

## Integração por distribuição

| Função | Rocky Linux 10 | Ubuntu 22.04/24.04 |
|---|---|---|
| Pacotes | DNF / EPEL / CRB | APT / Universe |
| Firewall | firewalld | UFW |
| Segurança MAC | SELinux | AppArmor |
| Servidor web | httpd | apache2 |
| Resolver | NetworkManager | systemd-resolved / resolv.conf |
| node exporter | node_exporter | prometheus-node-exporter |

No Ubuntu, o instalador mantém `systemd-resolved`, mas desativa o DNS stub local para liberar TCP/UDP 53 para o Samba. Consulte [docs/UBUNTU.md](docs/UBUNTU.md).

## Quick start

Use uma **VM limpa**, com IPv4 estático e acesso à Internet.

```bash
git clone https://github.com/pastrello/samba-ad-script.git
cd samba-ad-script
chmod +x scripts/*.sh tests/*.sh
sudo ./scripts/install.sh --check-platform
sudo ./scripts/install.sh
```

Exemplo com variáveis:

```bash
sudo \
  HOSTNAME_SHORT=dc1 \
  AD_DNS_DOMAIN=ad.example.com \
  NETBIOS_DOMAIN=EXAMPLE \
  DC_IP=192.0.2.10 \
  DNS_FORWARDER=192.0.2.1 \
  CLIENT_CIDRS="192.0.2.0/24" \
  MGMT_CIDRS="192.0.2.0/24" \
  ./scripts/install.sh
```

A senha do `Administrator` é solicitada de forma oculta. Leia o [Guia de instalação](docs/INSTALLATION.md) antes de usar fora de laboratório.

## Upgrade do Samba

O atualizador 1.2 é compatível com o manifesto multi-distribuição do installer 0.6 e também mantém modo legado para instalações anteriores do projeto.

Auditoria sem alterações:

```bash
sudo ./scripts/upgrade.sh --audit
```

Upgrade de patch na mesma série:

```bash
sudo ./scripts/upgrade.sh 4.24.6
```

O build ocorre com o DC online; a janela de indisponibilidade fica concentrada em snapshot, `make install` e restart. Mudanças de série continuam bloqueadas por padrão.

Leia [docs/UPGRADE.md](docs/UPGRADE.md).

## Segurança por padrão

- SELinux/AppArmor **não são desativados**;
- firewalld/UFW permanecem ativos;
- acesso AD e administrativo é limitado por CIDR;
- `0.0.0.0/0` é recusado por padrão;
- configurações de firewall permissivas são detectadas defensivamente;
- fonte do Samba é autenticada por GPG e fingerprint esperado;
- build é executado como usuário sem privilégios;
- Prometheus e node_exporter ficam no loopback;
- LAM e Grafana usam HTTPS;
- a senha inicial do Grafana não permanece no ambiente do processo após o bootstrap;
- backups consistentes usam `samba-tool domain backup`;
- o upgrader cria snapshot consistente antes do `make install`.

Veja [SECURITY.md](SECURITY.md).

## Estrutura

```text
.
├── scripts/
│   ├── install.sh                 # dispatcher / CLI
│   ├── upgrade.sh                 # upgrader multi-distro
│   └── lib/
│       ├── common.sh              # lógica comum Samba/AD
│       ├── distro-rocky.sh        # integração Rocky 10
│       └── distro-ubuntu.sh       # integração Ubuntu LTS
├── tests/
│   └── platform-detection.sh
├── docs/
│   ├── ARCHITECTURE.md
│   ├── INSTALLATION.md
│   ├── UBUNTU.md
│   ├── UPGRADE.md
│   ├── BACKUP-RESTORE.md
│   ├── TROUBLESHOOTING.md
│   └── ROADMAP.md
├── CHANGELOG.md
├── CONTRIBUTING.md
├── SECURITY.md
└── LICENSE
```

## Estado de testes

| Item | Estado |
|---|---|
| `bash -n` de installer/upgrader/adapters | CI |
| contrato dos adapters | CI |
| detecção Rocky 10 / Ubuntu 22.04 / 24.04 | CI |
| provisionamento Samba 4.24.5 em Rocky 10 | validado em laboratório em geração anterior |
| FSMO / dbcheck / SRV LDAP/Kerberos em Rocky 10 | validado em laboratório |
| installer 0.6 Rocky 10 | refatorado; nova rodada end-to-end pendente |
| installer 0.6 Ubuntu 22.04 | end-to-end pendente |
| installer 0.6 Ubuntu 24.04 | end-to-end pendente |
| upgrader 1.2 | `--audit` disponível; upgrade real depende de release Samba adequada |
| Multi-DC | roadmap |

Esse quadro é deliberadamente conservador: teste estático não substitui um provisionamento real de AD.

## Contribuindo

Issues e pull requests são bem-vindos. Consulte [CONTRIBUTING.md](CONTRIBUTING.md). Não envie senhas, dumps de `sam.ldb`, chaves privadas ou logs não sanitizados.

## Licença

MIT. Consulte [LICENSE](LICENSE).

## Aviso

Projeto independente, sem afiliação com Samba Team, Rocky Linux, Canonical/Ubuntu, LDAP Account Manager, Grafana Labs, Prometheus ou Red Hat.
