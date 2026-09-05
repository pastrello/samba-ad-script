# Troubleshooting

## O FQDN não resolve antes do provisionamento

Antes de o DNS do AD existir, a validação inicial depende de `/etc/hosts`.

Exemplo esperado:

```text
192.0.2.10    dc1.ad.example.com    dc1
```

Teste:

```bash
hostname -f
getent ahostsv4 dc1.ad.example.com
```

O instalador v0.5 valida `/etc/hosts` e faz a validação DNS definitiva depois do provisionamento.

## Download da assinatura retorna 404

O Samba publica, para uma versão `X.Y.Z`:

```text
samba-X.Y.Z.tar.gz
samba-X.Y.Z.tar.asc
```

A assinatura é verificada contra o `.tar` descompactado, não contra o `.tar.gz`.

O instalador atual já implementa esse fluxo.

## LAM reclama de GMP ou ZIP

Valide:

```bash
php -m | grep -Ei 'gmp|zip|ldap|openssl'
```

O instalador atual trata GMP e ZIP como dependências do LAM e executa autoteste.

## Windows não encontra o domínio

Primeiro confirme que o Windows usa somente o DNS do AD.

No cliente:

```cmd
ipconfig /all
nslookup dc1.ad.example.com
nslookup -type=SRV _ldap._tcp.ad.example.com
nslookup -type=SRV _kerberos._tcp.ad.example.com
```

No DC:

```bash
host -t SRV _ldap._tcp.ad.example.com 127.0.0.1
host -t SRV _kerberos._udp.ad.example.com 127.0.0.1
```

## Kerberos falha

Confira horário:

```bash
timedatectl
chronyc tracking
chronyc sources -v
```

Depois:

```bash
kinit Administrator
klist
```

DNS e tempo incorretos são causas frequentes de falha Kerberos.

## Samba não inicia

```bash
systemctl status samba-ad-dc --no-pager
journalctl -u samba-ad-dc -n 200 --no-pager
/opt/samba/bin/samba-tool testparm --suppress-prompt
```

Não execute `domain provision` novamente sobre um domínio existente para tentar reparar o serviço.

## Verificar integridade

```bash
samba-tool dbcheck --cross-ncs
```

Não use `--fix` automaticamente. Entenda primeiro os erros reportados e tenha backup.

## Verificar FSMO

```bash
samba-tool fsmo show
```

Em um domínio com um único DC, todos os papéis no mesmo servidor é esperado.

## Ver health-check

```bash
/usr/local/sbin/samba-ad-health
journalctl -u samba-ad-health.service
systemctl list-timers samba-ad-health.timer
```

## Firewalld

Veja a zona da interface:

```bash
firewall-cmd --get-active-zones
firewall-cmd --list-all
```

O instalador recusa por padrão zonas permissivas como `trusted` ou target `ACCEPT`, pois elas anulam a ideia de restringir serviços por CIDR.

## SELinux

O projeto não desativa SELinux.

```bash
getenforce
ausearch -m AVC -ts recent
```

Antes de criar exceções, determine exatamente qual acesso foi bloqueado.
