# Security Policy

## Escopo

Este repositório automatiza a implantação de um Active Directory compatível via Samba. Bugs podem afetar autenticação, DNS, Kerberos, firewall, TLS, backup e disponibilidade do domínio.

O projeto está em fase **experimental / pré-1.0**. Não há SLA nem garantia de adequação a ambientes de produção.

## Reportando uma vulnerabilidade

Não publique credenciais, chaves privadas ou material de um domínio real em uma issue pública.

Para problemas que exponham informação sensível ou permitam comprometimento, prefira o mecanismo privado de **GitHub Security Advisories / Report a vulnerability**, quando disponível no repositório. Caso não esteja disponível, entre em contato com o mantenedor pelo perfil GitHub antes de publicar detalhes exploráveis.

Para bugs não sensíveis, abra uma issue normalmente.

## O que enviar

Inclua, quando possível e sanitizado:

- versão do Rocky Linux;
- versão do instalador/atualizador;
- versão do Samba;
- passo em que ocorreu a falha;
- logs relevantes sem segredos;
- impacto observado;
- forma segura de reproduzir.

## Princípios do projeto

As correções devem tentar preservar:

- SELinux habilitado;
- firewalld habilitado;
- mínimo de exposição de portas;
- validação de downloads;
- ausência de senha na linha de comando;
- backup consistente antes de operações de risco;
- rollback previsível;
- execução sem privilégios sempre que viável.

## Dependências

O projeto instala software de terceiros. Vulnerabilidades no Samba, Rocky Linux, PHP, LAM, Grafana, Prometheus, Cockpit, Borg ou Restic devem também ser acompanhadas nos respectivos projetos upstream.
