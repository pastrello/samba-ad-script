# Changelog

Este projeto ainda está em fase pré-1.0. O instalador e o atualizador possuem versões independentes.

O formato segue, quando possível, a ideia de [Keep a Changelog](https://keepachangelog.com/).

## Installer 0.5 — 2026-09-05

### Added
- checkpoint/resume versionado para retomada após falhas;
- lock para impedir duas execuções simultâneas;
- validação e normalização de CIDRs;
- proteção contra `0.0.0.0/0` por padrão;
- detecção da zona real da interface no firewalld;
- bloqueio defensivo de zonas `trusted`/`ACCEPT`;
- build do Samba com usuário sem privilégios;
- validação do fingerprint GPG do projeto Samba;
- downloads atômicos;
- SHA-256 fixado para versões suportadas do LAM;
- `php-gmp` e suporte ZIP para o LAM;
- LAM via HTTPS;
- Grafana via HTTPS e senha inicial aleatória;
- Prometheus em `127.0.0.1:9091`;
- node_exporter em `127.0.0.1:9100`;
- manifesto `/etc/samba-ad/installation.env`;
- `/etc/samba-ad/build-info.txt`;
- health-check periódico via systemd timer;
- backup de configurações do host junto do backup do AD;
- logrotate para logs do Samba;
- validações pós-instalação de DNS, SYSVOL, GC, Kerberos e backup.

### Changed
- DNS inicial continua sendo `SAMBA_INTERNAL`;
- SELinux e firewalld permanecem habilitados;
- administração web passa a ser restrita por CIDR.

## Upgrader 1.1 — 2026-09-05

### Added
- leitura e validação do manifesto criado pelo instalador;
- modo `--audit`, sem alterações;
- autodetecção para instalações legadas do mesmo projeto;
- build sem privilégios;
- reuso dos parâmetros originais de `./configure`;
- fingerprint GPG esperado e validação do signatário;
- backup do domínio antes do upgrade;
- snapshot consistente de `/opt/samba` com o DC parado;
- rollback automático em falha durante a janela crítica;
- atualização do manifesto após sucesso;
- histórico em `/etc/samba-ad/upgrade-history.log`;
- atualização do `build-info.txt`;
- bloqueio padrão de mudança de série e downgrade.

## Installer 0.3 — 2026-08

### Fixed
- validação inicial de hostname/FQDN antes de o DNS do AD existir;
- fluxo correto de assinatura do Samba (`.tar.asc` sobre o `.tar`, não `.tar.gz.asc`).

### Validated
- instalação real em Rocky Linux 10;
- Samba AD DC 4.24.5;
- FSMO;
- `samba-tool dbcheck --cross-ncs` com zero erros;
- registros SRV LDAP e Kerberos;
- Cockpit, LAM, Prometheus e Grafana em laboratório.

## Installer 0.2 — 2026-08

### Fixed
- validação de `/etc/hosts` deixou de depender de DNS ainda não provisionado.

## Installer 0.1 — 2026-08

### Added
- primeira versão do instalador para Rocky Linux 10;
- Samba AD DC compilado em `/opt/samba`;
- Kerberos, Chrony, Cockpit, LAM, observabilidade e backup.
