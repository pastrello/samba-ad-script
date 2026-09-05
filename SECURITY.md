# Security Policy

## Escopo

O projeto automatiza um Samba Active Directory Domain Controller e integra DNS, Kerberos, firewall, TLS, monitoring e backup. Bugs podem afetar autenticação, confidencialidade ou disponibilidade do domínio.

O projeto é **experimental / pré-1.0** e não possui SLA.

## Princípios

- não desabilitar SELinux/AppArmor como solução genérica;
- manter firewalld/UFW com política restritiva;
- restringir serviços por CIDR;
- não confiar em download de código sem validação apropriada;
- não persistir credenciais em linha de comando quando evitável;
- preferir falha segura a continuar com ambiente inconsistente.

## Reportando vulnerabilidade

Não publique credenciais, chaves, bancos AD ou material de domínio real em issue pública.

Para vulnerabilidade com impacto de segurança, use **GitHub Security Advisories / Report a vulnerability** se o recurso estiver habilitado. Caso contrário, contate o mantenedor por um canal privado indicado no perfil do repositório.

Inclua, de forma sanitizada:

- distribuição/release;
- versão do installer/upgrader e Samba;
- impacto;
- passos mínimos para reproduzir;
- logs estritamente necessários.

## Plataformas

Rocky 10 usa SELinux/firewalld. Ubuntu 22.04/24.04 usa AppArmor/UFW. Um comportamento seguro em uma plataforma não deve ser presumido equivalente na outra sem teste.
