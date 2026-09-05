# Ubuntu Server

## Suporte

O installer 0.6 possui adapters para:

- Ubuntu Server 22.04 LTS;
- Ubuntu Server 24.04 LTS.

Versões posteriores são aceitas como experimentais e devem ser testadas em laboratório.

## systemd-resolved e porta 53

O Samba AD DC precisa escutar DNS em TCP/UDP 53. Em Ubuntu, `systemd-resolved` normalmente fornece um stub local em loopback.

O adapter **não remove nem desabilita o serviço**. Ele cria:

```text
/etc/systemd/resolved.conf.d/60-samba-ad.conf
```

com `DNSStubListener=no`.

Durante build/provisionamento, o host usa o `DNS_FORWARDER` diretamente. Depois que o Samba está ativo, o resolver local passa a usar `DC_IP` e o domínio AD.

Uma cópia do `/etc/resolv.conf` anterior é tentada em:

```text
/etc/resolv.conf.pre-samba-ad
```

Não restaure esse arquivo em um DC ativo sem entender o impacto no DNS do AD.

## Netplan

O instalador detecta `/etc/netplan`, mas não reescreve automaticamente a configuração de IP. Configure endereço estático antes da instalação.

## UFW

O adapter:

- detecta política de entrada `ACCEPT`;
- procura regras amplas `ALLOW Anywhere` em portas sensíveis;
- preserva as portas SSH reportadas por `sshd -T`;
- libera portas AD apenas para `CLIENT_CIDRS`;
- libera LAM/Grafana/Cockpit apenas para `MGMT_CIDRS`;
- habilita/recarrega UFW ao final.

Revise acesso remoto antes de executar em um host fora de console.

## AppArmor

O projeto não desativa AppArmor. Quando há perfil de `chronyd`, o adapter tenta adicionar uma regra local para o diretório `ntp_signd` e recarregar o perfil.

Se houver negação:

```bash
aa-status
journalctl -k | grep -i apparmor
```

Não coloque o perfil globalmente em complain/disabled sem investigar.

## Apache/PHP/LAM

No Ubuntu são usados:

```text
apache2
www-data:www-data
php-gmp
php-zip
php-ldap
```

O site default é desabilitado e é criado `samba-ad-lam.conf` para HTTP->HTTPS e LAM em HTTPS.

## Prometheus

O pacote do exporter no Ubuntu usa a nomenclatura `prometheus-node-exporter`. O installer cria override para que ele escute apenas em `127.0.0.1:9100`.

## Diagnóstico rápido

```bash
sudo ./scripts/install.sh --check-platform
systemctl status systemd-resolved
ss -lntup | grep ':53 '
ufw status verbose
systemctl status apparmor
systemctl status apache2
systemctl status prometheus-node-exporter
```
