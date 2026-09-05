# Arquitetura

## Modelo multi-distribuição

A partir do installer 0.6, a lógica foi dividida em três camadas:

```text
scripts/install.sh
       │
       ├── detecta /etc/os-release
       │
       ▼
scripts/lib/common.sh
       │
       ├── Samba/AD
       ├── provisionamento
       ├── GPG
       ├── backup/health
       ├── LAM/Grafana/Prometheus (orquestração)
       └── manifesto/resume
       │
       └──────── hooks de plataforma ────────┐
                                             │
                  ┌──────────────────────────┴─────────────────────────┐
                  ▼                                                    ▼
       distro-rocky.sh                                      distro-ubuntu.sh
       DNF / firewalld                                      APT / UFW
       SELinux                                              AppArmor
       httpd                                                apache2
       NetworkManager                                       systemd-resolved/Netplan
```

O objetivo é evitar dois instaladores independentes divergindo ao longo do tempo.

## Contrato dos adapters

Cada adapter implementa hooks para:

- validar a plataforma;
- habilitar repositórios e instalar pacotes;
- descobrir DNS/rede;
- verificar mecanismo MAC;
- detectar pacotes Samba conflitantes;
- preparar porta 53;
- configurar resolver;
- integrar CA/TLS;
- configurar Chrony/ntp_signd;
- configurar firewall;
- instalar Cockpit/LAM/monitoramento/Grafana;
- executar testes específicos da plataforma.

`tests/platform-detection.sh` valida esse contrato estaticamente.

## Samba AD

O Samba permanece instalado em:

```text
/opt/samba
```

com serviço:

```text
samba-ad-dc.service
```

A distribuição escolhida não altera o formato do domínio nem a estratégia de upgrade.

## Manifesto

```text
/etc/samba-ad/installation.env
/etc/samba-ad/build-info.txt
```

Além da versão do Samba, a 0.6 registra distribuição, tier, firewall, mecanismo MAC e hashes do wrapper, biblioteca comum e adapter. O upgrader usa esses metadados sem apagar chaves que não conhece.

## DNS

Backend inicial:

```text
SAMBA_INTERNAL
```

Rocky integra o resolver via NetworkManager. Ubuntu desativa o stub DNS do `systemd-resolved`, mantendo o serviço e usando o DC diretamente em `/etc/resolv.conf` após o provisionamento.

## Segurança da plataforma

```text
Rocky 10  -> SELinux + firewalld
Ubuntu    -> AppArmor + UFW
```

Nenhum adapter desativa deliberadamente o mecanismo MAC para "fazer funcionar".

## Observabilidade

```text
node_exporter 127.0.0.1:9100
          │
          ▼
Prometheus 127.0.0.1:9091
          │
          ▼
Grafana HTTPS :3000
```

## Upgrade

O `scripts/upgrade.sh` é propositalmente pouco dependente da distribuição. Ele lê o manifesto, compila em usuário sem privilégios e só precisa de root para snapshot/instalação/restart.

```text
build online
→ dbcheck + backup AD
→ stop Samba
→ snapshot consistente /opt/samba
→ make install
→ testparm/start
→ pós-checks
```
