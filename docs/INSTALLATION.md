# Instalação

## Plataformas

A matriz principal do installer 0.6 é:

- Rocky Linux 10.x;
- Ubuntu Server 22.04 LTS;
- Ubuntu Server 24.04 LTS.

Ubuntu posterior a 24.04 é classificado como experimental até validação específica. Outras distribuições são recusadas.

Antes de instalar:

```bash
sudo ./scripts/install.sh --check-platform
```

## Requisitos

Use preferencialmente uma VM nova com:

- IPv4 estático;
- hostname ainda não associado a outro AD;
- acesso à Internet/repositórios da distribuição;
- horário correto;
- DNS forwarder funcional;
- root/sudo;
- recursos suficientes para compilação do Samba.

Para laboratório, 4 vCPU, 8 GiB RAM e 40–80 GiB de disco são uma base razoável. Ajuste ao tamanho real do domínio.

## Nomenclatura

```text
Hostname curto : dc1
Domínio AD     : ad.example.com
FQDN do DC     : dc1.ad.example.com
NetBIOS        : EXAMPLE
```

Evite `.local` e escolha o realm com cuidado.

## Rede

Configure o IP estático **antes** do domínio.

```bash
ip -br addr
ip route
hostnamectl
```

O instalador não deve ser usado como substituto do gerenciamento de IP do host. Em Rocky, ele inspeciona NetworkManager; em Ubuntu, reconhece Netplan mas não reescreve arbitrariamente o YAML de endereçamento.

### Ubuntu e DNS local

Ubuntu normalmente usa `systemd-resolved`. O adapter:

1. preserva a configuração original de `/etc/resolv.conf` quando possível;
2. desativa apenas `DNSStubListener` para liberar porta 53;
3. mantém resolução externa via `DNS_FORWARDER` durante build/provisionamento;
4. após o Samba iniciar, passa `/etc/resolv.conf` a apontar para o próprio DC.

Detalhes: [UBUNTU.md](UBUNTU.md).

## Executar

```bash
git clone https://github.com/pastrello/samba-ad-script.git
cd samba-ad-script
chmod +x scripts/*.sh tests/*.sh
sudo ./scripts/install.sh --check-platform
sudo ./scripts/install.sh
```

O instalador pede hostname, domínio DNS, NetBIOS, IP, forwarder, redes de clientes/administração e senha do `Administrator`.

## Execução com variáveis

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

Overrides de segurança, como `ALLOW_WIDE_CLIENT_CIDR`, existem para exceções conscientes e não devem ser usados apenas para contornar uma validação.

## Retomada após falha

Estado:

```text
/var/lib/samba-ad-installer/
```

O formato v3 registra também distribuição/versão. Um estado criado por revisão/formato incompatível é recusado em vez de ser retomado cegamente.

## Validação pós-instalação

```bash
systemctl status samba-ad-dc --no-pager
samba-tool dbcheck --cross-ncs
samba-tool fsmo show
samba-tool domain level show
host -t SRV _ldap._tcp.ad.example.com 192.0.2.10
host -t SRV _kerberos._udp.ad.example.com 192.0.2.10
host -t SRV _gc._tcp.ad.example.com 192.0.2.10
kinit Administrator
klist
kdestroy
smbclient -L localhost -U Administrator
chronyc tracking
/usr/local/sbin/samba-ad-health
```

## Firewall

- Rocky: firewalld, com rich rules por CIDR.
- Ubuntu: UFW, preservando portas SSH detectadas antes de habilitá-lo.

O instalador recusa configurações permissivas que tornariam as regras por CIDR ilusórias, salvo override explícito.

## Interfaces

```text
Cockpit : https://IP_DO_DC:9090/
LAM     : https://FQDN_DO_DC/lam/
Grafana : https://FQDN_DO_DC:3000/
```

Prometheus e node exporter permanecem no loopback.

## Windows

Clientes devem usar o DNS do AD como DNS do adaptador. Não misture DNS público diretamente no cliente de domínio.

## Produção

Antes de produção, valide restore em VM separada, segundo DC, firewall real, CA corporativa, monitoramento externo, backup remoto e procedimento de upgrade/rollback.
