# Upgrade do Samba

O `scripts/upgrade.sh` atualiza somente o Samba compilado do projeto. Ele não reinstala LAM, Grafana, Cockpit ou Prometheus.

## Auditoria

Pode ser executada sem esperar uma nova versão:

```bash
sudo ./scripts/upgrade.sh --audit
```

O modo audit:

- não baixa fonte;
- não compila;
- não para o Samba;
- não altera banco AD;
- verifica serviço, manifesto, `dbcheck`, FSMO, DNS e configuração básica.

## Upgrade de patch

Exemplo:

```bash
sudo ./scripts/upgrade.sh 4.24.6
```

Fluxo:

```text
verificar ambiente
→ validar manifesto
→ baixar .tar.gz + .tar.asc
→ validar GPG
→ configure/make como usuário sem privilégios
→ dbcheck
→ samba-tool domain backup
→ parar DC
→ snapshot consistente de /opt/samba
→ make install
→ ldconfig
→ testparm/start
→ dbcheck/DNS pós-upgrade
→ atualizar manifesto/histórico
```

A compilação acontece com o DC online.

## Mudança de série

Por padrão:

```text
4.24.5 -> 4.24.6   permitido
4.24.x -> 4.25.x   bloqueado
```

Após ler as release notes e testar em laboratório:

```bash
sudo ./scripts/upgrade.sh 4.25.1 --allow-feature-upgrade
```

## Downgrade

É bloqueado por padrão:

```bash
sudo ./scripts/upgrade.sh 4.24.4 --allow-downgrade
```

Isso deve ser considerado excepcional. Uma versão nova pode alterar estruturas que tornam um downgrade inseguro.

## Manifesto

Instalações v0.5 mantêm:

```text
/etc/samba-ad/installation.env
```

O atualizador compara o manifesto com o Samba real antes de continuar.

Se houver divergência, investigue. Não use `--allow-manifest-mismatch` como primeira solução.

## Rollback

Antes do `make install`, com o DC parado, é criado:

```text
/var/backups/samba-upgrade/
```

Se o `make install`, `testparm` ou start falhar durante a janela crítica, o atualizador tenta restaurar o prefixo anterior.

Após a nova versão iniciar e passar do ponto de segurança, o script deixa de fazer rollback automático. Isso evita voltar binários antigos sobre um AD que já possa ter sido aberto/alterado pela versão nova.

## Pós-upgrade

Confira:

```bash
samba-tool --version
samba-tool dbcheck --cross-ncs
samba-tool fsmo show
samba-tool domain level show
systemctl status samba-ad-dc --no-pager
```

E veja:

```text
/etc/samba-ad/upgrade-history.log
/etc/samba-ad/build-info.txt
/etc/samba-ad/installation.env
```

## Regra prática

Atualizações de patch na mesma série são o caso mais simples. Mudanças de série devem sempre ser tratadas como manutenção planejada e testadas previamente.
