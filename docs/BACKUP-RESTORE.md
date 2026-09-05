# Backup e recuperação

## O que o instalador cria

O instalador agenda backup local consistente do domínio em:

```text
/var/backups/samba-ad
```

O mecanismo usa `samba-tool domain backup`.

BorgBackup e Restic são instalados, mas nenhum repositório remoto é configurado automaticamente.

## Por que separar backup e cópia externa?

O processo recomendado é:

```text
Samba AD
   │
   ├─ samba-tool domain backup
   ▼
backup local consistente
   │
   ├─ Restic/Borg
   ▼
destino externo/off-site
```

Não use apenas uma cópia recursiva de `/opt/samba/private` com o DC em atividade como estratégia de disaster recovery.

## Validar timer

```bash
systemctl list-timers samba-ad-backup.timer
systemctl status samba-ad-backup.service
ls -lh /var/backups/samba-ad/
```

## Testar restore

Um backup só deve ser considerado confiável depois de um restore de laboratório.

A recuperação de um AD deve ser feita em host/VM isolado e seguindo a documentação da mesma série do Samba usada no backup. Consulte:

https://wiki.samba.org/index.php/Back_up_and_Restoring_a_Samba_AD_DC

Não restaure um domínio de teste na mesma rede de produção com identidade/IP conflitantes.

## Upgrade

O `scripts/upgrade.sh` também cria um snapshot de rollback de `/opt/samba` com o DC parado. Esse snapshot serve para a janela de upgrade; ele **não substitui** a estratégia regular de disaster recovery.

## Recomendações

- mantenha cópia fora do servidor;
- use criptografia no repositório remoto;
- limite credenciais do destino;
- teste restore periodicamente;
- registre RPO/RTO esperado;
- não armazene senha de repositório em argumentos de processo;
- monitore falhas do timer de backup.
