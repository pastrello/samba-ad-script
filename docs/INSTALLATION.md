# Instalação

## Requisitos

Use preferencialmente uma VM nova com:

- Rocky Linux 10;
- IP IPv4 estático;
- hostname ainda não associado a outro domínio;
- acesso aos repositórios Rocky/EPEL e à Internet para downloads upstream;
- horário correto;
- DNS forwarder funcional;
- root/sudo;
- recursos suficientes para compilar o Samba.

Para laboratório, 4 vCPU, 8 GiB de RAM e 40–80 GiB de disco costumam ser uma base confortável. O tamanho adequado depende do domínio e dos dados armazenados.

## Nomenclatura

Recomendado:

```text
Hostname curto : dc1
Domínio AD     : ad.example.com
FQDN do DC     : dc1.ad.example.com
NetBIOS        : EXAMPLE
```

Evite `.local` e escolha o realm com cuidado: renomear um AD depois não é uma operação trivial.

## Preparar o host

Confirme o endereço:

```bash
ip -br addr
ip route
hostnamectl
```

Configure IP estático antes de criar o domínio.

## Executar

```bash
git clone https://github.com/pastrello/samba-ad-script.git
cd samba-ad-script
chmod +x scripts/*.sh
sudo ./scripts/install.sh
```

O instalador é interativo e pede:

- hostname;
- domínio DNS do AD;
- domínio NetBIOS;
- IP do DC;
- DNS forwarder;
- CIDRs dos clientes;
- CIDRs administrativos;
- senha do `Administrator`.

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

Variáveis defensivas existem para exceções, por exemplo `ALLOW_WIDE_CLIENT_CIDR`, mas não devem ser usadas apenas para "fazer funcionar".

## Retomada após falha

O instalador mantém estado em:

```text
/var/lib/samba-ad-installer/
```

Etapas concluídas recebem checkpoints. Ao executar novamente, o script tenta retomar sem reprovisionar um domínio parcialmente criado.

Leia cuidadosamente a saída antes de apagar o estado manualmente.

## Validação pós-instalação

### Serviço

```bash
systemctl status samba-ad-dc --no-pager
```

### Integridade

```bash
samba-tool dbcheck --cross-ncs
samba-tool fsmo show
samba-tool domain level show
```

### DNS

```bash
host -t SRV _ldap._tcp.ad.example.com 192.0.2.10
host -t SRV _kerberos._udp.ad.example.com 192.0.2.10
host -t SRV _gc._tcp.ad.example.com 192.0.2.10
```

### Kerberos

```bash
kinit Administrator
klist
kdestroy
```

### SMB

```bash
smbclient -L localhost -U Administrator
smbclient //localhost/sysvol -U Administrator
```

### Horário

```bash
chronyc tracking
chronyc sources -v
```

### Health-check

```bash
/usr/local/sbin/samba-ad-health
systemctl list-timers samba-ad-health.timer
```

### Backup

```bash
ls -lh /var/backups/samba-ad/
systemctl list-timers samba-ad-backup.timer
```

## LAM

Acesse:

```text
https://FQDN_DO_DC/lam/
```

O instalador troca a senha mestre padrão. Se ela foi gerada automaticamente:

```bash
sudo cat /root/lam-master-password.txt
```

Depois de armazená-la em local seguro:

```bash
sudo rm -f /root/lam-master-password.txt
```

Configure o perfil para Samba 4 / Active Directory e use o LDAP indicado pelo resumo final.

## Grafana

Acesse:

```text
https://FQDN_DO_DC:3000/
```

Se a senha inicial foi gerada automaticamente:

```bash
sudo cat /root/grafana-initial-admin.txt
```

Troque-a e remova o arquivo.

## Windows

O cliente Windows deve usar o DNS do AD:

```text
DNS primário = IP_DO_DC
```

Não combine DNS do AD com `8.8.8.8`, `1.1.1.1` etc. no adaptador do cliente. O DNS do Samba encaminha consultas externas ao forwarder.

Depois, ingresse a estação em:

```text
ad.example.com
```

e use RSAT para ADUC/GPMC/DNS quando necessário.

## Observação sobre produção

Antes de produção, valide pelo menos:

- restore de backup em VM separada;
- segundo DC;
- políticas de firewall reais;
- CA/TLS corporativa;
- monitoramento externo;
- destino remoto de backup;
- procedimento de atualização e rollback.
