# Roadmap

O projeto está em fase pré-1.0. A prioridade é transformar o fluxo atual de laboratório em uma base reproduzível e auditável.

## Antes da 1.0

- [ ] executar o instalador v0.5 end-to-end em múltiplas VMs Rocky Linux 10 limpas;
- [ ] validar instalação em Rocky 10 com diferentes perfis de rede;
- [ ] validar um upgrade real assim que houver versão Samba adequada para teste;
- [ ] testar rollback do upgrade de forma deliberada;
- [ ] criar teste automatizado de funções puras do instalador;
- [ ] ampliar CI estática;
- [ ] documentar restore completo em laboratório;
- [ ] validar LAM + LDAPS de ponta a ponta;
- [ ] dashboards Grafana básicos para o host;
- [ ] revisar permissões e unidades systemd.

## Depois da 1.0

- [ ] modo "adicionar segundo DC" a domínio existente;
- [ ] verificação de replicação (`samba-tool drs showrepl`);
- [ ] estratégia documentada para SYSVOL em múltiplos DCs;
- [ ] suporte opcional a BIND9_DLZ;
- [ ] integração opcional de backup remoto via Restic/Borg;
- [ ] suporte estudado para AlmaLinux/RHEL equivalentes;
- [ ] empacotamento/instalador mais modular;
- [ ] releases/tagging semântico do projeto.

## Fora de escopo por enquanto

- substituir RSAT/GPMC;
- administrar GPO integralmente por interface web;
- CUPS/Webmin;
- oferecer suporte comercial/SLA;
- configurar automaticamente um destino de backup com credenciais.
