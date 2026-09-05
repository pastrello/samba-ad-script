# Upgrade do Samba

O `scripts/upgrade.sh` 1.2 atualiza apenas o Samba compilado. LAM, Grafana, Cockpit e Prometheus não são reinstalados.

Ele foi mantido propositalmente multi-distribuição: instalações 0.6 registram a plataforma no manifesto, mas o fluxo de build/backup/rollback continua comum.

## Auditoria

```bash
sudo ./scripts/upgrade.sh --audit
```

Não baixa fonte, não compila, não para Samba e não altera o AD.

## Upgrade de patch

```bash
sudo ./scripts/upgrade.sh 4.24.6
```

Fluxo:

```text
manifesto/ambiente
→ .tar.gz + .tar.asc
→ GPG/fingerprint
→ configure/make sem privilégios
→ dbcheck + domain backup
→ stop DC
→ snapshot /opt/samba
→ make install
→ ldconfig + testparm + start
→ dbcheck/DNS
→ manifesto/histórico
```

## Compatibilidade de instalação

- installer 0.6: lê manifesto multi-distro;
- installer 0.5: lê manifesto anterior;
- instalações antigas do projeto: modo legado/autodetecção.

O upgrader preserva chaves adicionais do manifesto para não perder metadados da plataforma.

## Mudança de série

```text
4.24.5 -> 4.24.6   permitido
4.24.x -> 4.25.x   bloqueado
```

Após release notes e laboratório:

```bash
sudo ./scripts/upgrade.sh 4.25.1 --allow-feature-upgrade
```

Downgrade também é bloqueado por padrão e deve ser excepcional.

## Rollback

Com o DC parado, antes do `make install`:

```text
/var/backups/samba-upgrade/
```

é criado um snapshot consistente do prefixo. Falhas na janela crítica tentam restaurar o snapshot. Depois que a nova versão já iniciou e passou do ponto de segurança, rollback automático é desativado para evitar voltar binários antigos sobre dados potencialmente tocados pela versão nova.

## Arquivos de auditoria

```text
/etc/samba-ad/installation.env
/etc/samba-ad/build-info.txt
/etc/samba-ad/upgrade-history.log
```
