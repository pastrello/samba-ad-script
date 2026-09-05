# Changelog

Este projeto está em fase pré-1.0. Installer e upgrader possuem versões independentes.

## Installer 0.6.2 — 2026-09-05

### Fixed
- corrige `SIGPIPE`/exit 141 ao iniciar `samba_provision` com `set -o pipefail`;
- centraliza a leitura de `smbd -b` em `samba_build_option()`, sem pipeline com consumidor que encerra cedo;
- corrige o mesmo padrão latente nas rotinas de TLS, logrotate e health-check;
- mantém compatibilidade com checkpoint v3, permitindo retomar uma instalação 0.6/0.6.1 que já concluiu o build do Samba;
- adiciona teste de regressão contra consumidores que encerram cedo (`awk ... exit`, `head`, `grep -m`) após `smbd -b`.

## Installer 0.6.1 — 2026-09-05

### Fixed
- corrige o primeiro bug encontrado no teste end-to-end Ubuntu: `systemd-resolved` permanecia ocupando `127.0.0.53/54:53` mesmo após `DNSStubListener=no`;
- usa drop-in local de alta prioridade `99-samba-ad.conf` e limpa `DNSStubListenerExtra`;
- identifica o proprietário real da porta 53 antes de tomar qualquer ação;
- quando apenas `systemd-resolved` insiste em manter a porta 53, aplica fallback controlado para DC dedicado: para/mascara o serviço e mantém `/etc/resolv.conf` estático;
- se outro daemon DNS ocupar a porta 53, o instalador continua abortando com diagnóstico em vez de desativá-lo;
- retomada de uma instalação 0.6 parcialmente executada continua suportada porque o formato de estado permanece v3.

## Installer 0.6.1 — 2026-09-05

### Fixed
- corrige o primeiro bug encontrado no teste end-to-end Ubuntu: `systemd-resolved` permanecia ocupando `127.0.0.53/54:53` mesmo após `DNSStubListener=no`;
- usa drop-in local de alta prioridade `99-samba-ad.conf` e limpa `DNSStubListenerExtra`;
- identifica o proprietário real da porta 53 antes de tomar qualquer ação;
- quando apenas `systemd-resolved` insiste em manter a porta 53, aplica fallback controlado para DC dedicado: para/mascara o serviço e mantém `/etc/resolv.conf` estático;
- se outro daemon DNS ocupar a porta 53, o instalador continua abortando com diagnóstico em vez de desativá-lo;
- retomada de uma instalação 0.6 parcialmente executada continua suportada porque o formato de estado permanece v3.

## Installer 0.6 — 2026-09-05

### Added
- Samba 4.24.6 como versão padrão do novo provisionamento;
- arquitetura multi-distribuição com dispatcher `scripts/install.sh`;
- biblioteca comum `scripts/lib/common.sh`;
- adapters `distro-rocky.sh` e `distro-ubuntu.sh`;
- suporte principal a Rocky Linux 10.x, Ubuntu 22.04 LTS e Ubuntu 24.04 LTS;
- tier experimental para Ubuntu posterior à matriz validada;
- `--check-platform` para diagnóstico sem instalação;
- adapter Ubuntu com APT/Universe, Apache2, UFW, AppArmor e `systemd-resolved`;
- desativação controlada de `DNSStubListener` no Ubuntu para liberar porta 53 ao Samba sem remover `systemd-resolved`;
- preservação das portas SSH detectadas antes de habilitar UFW;
- detecção defensiva de política UFW permissiva e regras `ALLOW Anywhere` em portas sensíveis;
- suporte aos nomes de pacote/serviço do `prometheus-node-exporter` no Ubuntu;
- manifesto com distribuição, tier, firewall, mecanismo MAC e hashes do wrapper/common/adapter/bundle;
- estado de resume v3 vinculado também à distribuição/versão;
- testes estáticos do contrato de adapters e matriz de detecção.

### Changed
- lógica Samba/AD deixa de depender diretamente de DNF, firewalld, SELinux ou httpd;
- preparação da porta DNS passa a ser um hook específico da plataforma;
- Grafana é reiniciado após remover o secret temporário de bootstrap do ambiente do systemd;
- documentação passa a separar suporte implementado de validação end-to-end.

### Compatibility
- Rocky Linux 10 mantém o comportamento da linha 0.5 através do adapter Rocky;
- estados de instalação 0.5 não são retomados cegamente pela 0.6 devido à mudança de formato.

## Upgrader 1.2 — 2026-09-05

### Added
- compatibilidade explícita com o manifesto multi-distribuição do installer 0.6;
- exibição da distribuição detectada/registrada na auditoria;
- criação do usuário de build usando o `nologin` disponível na distribuição;
- registro da distribuição em `build-info.txt` quando presente no manifesto.

### Compatibility
- continua aceitando instalações v0.5 com manifesto;
- mantém autodetecção para instalações legadas do projeto sem manifesto.

## Installer 0.5 — 2026-09-05

### Added
- checkpoint/resume versionado;
- lock contra execuções simultâneas;
- validação/normalização de CIDRs e bloqueio de `0.0.0.0/0`;
- proteção contra zona firewalld permissiva;
- build Samba sem privilégios;
- validação do fingerprint GPG do Samba;
- downloads atômicos e SHA-256 fixado para LAM;
- LAM e Grafana via HTTPS;
- Prometheus/node_exporter no loopback;
- manifesto, build-info, health-check e backup de configurações.

## Upgrader 1.1 — 2026-09-05

### Added
- manifesto, `--audit`, build sem privilégios, GPG rígido, backup AD, snapshot consistente, rollback, histórico e bloqueio de mudança de série/downgrade.

## Installer 0.3 — 2026-08

### Fixed
- validação inicial do FQDN antes do DNS AD;
- assinatura Samba `.tar.asc` validada contra o `.tar` descompactado.

### Validated
- Samba 4.24.5 em Rocky Linux 10;
- FSMO, `dbcheck --cross-ncs` com zero erros e SRV LDAP/Kerberos.

## Installer 0.2 — 2026-08

### Fixed
- validação inicial de `/etc/hosts` deixou de depender do DNS ainda não provisionado.

## Installer 0.1 — 2026-08

### Added
- primeira versão Rocky Linux 10 com Samba em `/opt/samba`, Chrony, Cockpit, LAM, observabilidade e backup.
