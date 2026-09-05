# Troubleshooting

## Descobrir adapter/plataforma

```bash
sudo ./scripts/install.sh --check-platform
```

## FQDN antes do provisionamento

Antes de o DNS AD existir, `/etc/hosts` precisa permitir a resolução inicial:

```text
192.0.2.10    dc1.ad.example.com    dc1
```

## Assinatura Samba 404

O release usa:

```text
samba-X.Y.Z.tar.gz
samba-X.Y.Z.tar.asc
```

A assinatura corresponde ao `.tar` descompactado. O installer/upgrader atuais implementam esse fluxo.

## LAM reclama GMP/ZIP

```bash
php -m | grep -Ei 'gmp|zip|ldap|openssl'
```

Rocky usa seu provider RPM; Ubuntu usa `php-gmp` e `php-zip`.

## Ubuntu: porta 53 ocupada por systemd-resolved

```bash
systemctl status systemd-resolved
ss -lntup | grep ':53 '
cat /etc/systemd/resolved.conf.d/60-samba-ad.conf
cat /etc/resolv.conf
```

Esperado após a preparação:

```text
DNSStubListener=no
```

e nenhuma escuta `127.0.0.53:53`/`127.0.0.54:53` competindo com Samba.

## Ubuntu: perdi SSH ao mexer no UFW

O installer tenta preservar portas reportadas por:

```bash
sshd -T | grep '^port '
```

Antes de uma instalação remota, confirme o SSH real e revise:

```bash
ufw status verbose
```

## Rocky: firewalld

```bash
firewall-cmd --get-active-zones
firewall-cmd --list-all
```

Zonas `trusted`/target `ACCEPT` são recusadas por padrão.

## SELinux

```bash
getenforce
ausearch -m AVC -ts recent
```

## AppArmor

```bash
aa-status
journalctl -k | grep -i apparmor
```

## Windows não encontra o domínio

No cliente, use somente DNS do AD e valide SRV:

```cmd
nslookup -type=SRV _ldap._tcp.ad.example.com
nslookup -type=SRV _kerberos._tcp.ad.example.com
```

No DC:

```bash
host -t SRV _ldap._tcp.ad.example.com 127.0.0.1
host -t SRV _kerberos._udp.ad.example.com 127.0.0.1
```

## Kerberos

```bash
timedatectl
chronyc tracking
kinit Administrator
klist
```

## Samba não inicia

```bash
systemctl status samba-ad-dc --no-pager
journalctl -u samba-ad-dc -n 200 --no-pager
/opt/samba/bin/samba-tool testparm --suppress-prompt
```

Nunca reprovisione sobre um domínio existente como tentativa de reparo.

## Integridade / FSMO

```bash
samba-tool dbcheck --cross-ncs
samba-tool fsmo show
```

Não use `dbcheck --fix` automaticamente.
