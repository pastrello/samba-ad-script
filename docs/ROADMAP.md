# Roadmap

Projeto pré-1.0. A prioridade é converter o que já funciona em laboratório em uma base reproduzível, multi-distribuição e auditável.

## Antes da 1.0

- [x] separar lógica comum de integração com a distribuição;
- [x] adapter Rocky Linux 10;
- [x] adapter Ubuntu 22.04/24.04;
- [x] testes estáticos do contrato dos adapters;
- [x] upgrader compatível com manifesto multi-distro;
- [ ] executar installer 0.6 end-to-end em Rocky Linux 10 limpo;
- [ ] executar installer 0.6 end-to-end em Ubuntu 22.04 limpo;
- [ ] executar installer 0.6 end-to-end em Ubuntu 24.04 limpo;
- [ ] validar UFW sem perda de acesso remoto em múltiplos perfis;
- [ ] validar AppArmor + Chrony/ntp_signd em Ubuntu;
- [ ] validar LAM + LDAPS de ponta a ponta nas três plataformas;
- [ ] validar upgrade real quando houver release Samba adequada;
- [ ] testar rollback deliberadamente;
- [ ] documentar restore completo em laboratório;
- [ ] dashboards Grafana básicos;
- [ ] revisar hardening das unidades systemd.

## Depois da 1.0

- [ ] adicionar segundo DC a domínio existente;
- [ ] `samba-tool drs showrepl` e saúde de replicação;
- [ ] estratégia SYSVOL multi-DC;
- [ ] BIND9_DLZ opcional;
- [ ] backup remoto Restic/Borg;
- [ ] adapter AlmaLinux/RHEL equivalente;
- [ ] avaliar Debian 12/13;
- [ ] release/tagging semântico e matriz CI mais ampla.

## Fora de escopo por enquanto

- substituir RSAT/GPMC;
- GPO integral por web;
- CUPS/Webmin;
- suporte comercial/SLA;
- configurar automaticamente credenciais de backup remoto.
