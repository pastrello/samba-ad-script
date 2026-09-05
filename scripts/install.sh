#!/usr/bin/env bash
#
# scripts/install.sh
# Installer revision: 0.5
#
# Melhorias v0.5:
#   - validação de CIDRs, DNS forwarder e possíveis colisões com AD existente
#   - checagem mais completa de portas e ambiente de rede
#   - php-gmp + php-pecl-zip obrigatórios para o LAM, com autoteste
#   - zona real da interface no firewalld (não apenas a zona default)
#   - NetworkManager-wait-online e testparm antes do start do Samba
#   - validação de SYSVOL, Global Catalog, DNS e backups
#   - health-check periódico do AD via systemd timer
#   - snapshot das configurações do host junto do backup do domínio
#   - logrotate para logs do Samba compilado
#   - senha inicial aleatória do Grafana em vez de admin/admin
#   - manifesto de instalação/build para facilitar manutenção e upgrades
#   - retomada segura (checkpoint/resume) após falhas não destrutivas
#   - build do Samba executado como usuário sem privilégios; make install continua root
#   - teste de disponibilidade do DNS forwarder antes de criar o domínio
#   - HTTPS próprio do LAM com certificado self-signed contendo SAN do FQDN/IP
#   - trust local da CA LDAP do Samba e orientação do LAM para LDAPS
#   - normalização/bloqueio defensivo de CIDRs amplos (0.0.0.0/0)
#   - bloqueio de zonas firewalld permissivas (trusted/ACCEPT) por padrão
#   - downloads atômicos do fonte Samba e checksum fixado para LAM 9.6/9.5.2
#   - Grafana em HTTPS reutilizando o certificado administrativo do LAM
#   - node_exporter restrito ao loopback (Prometheus local)
#   - lock de execução para impedir dois instaladores simultâneos
#   - estado de resume versionado e manifesto de auditoria ampliado
#
# Instala um Samba Active Directory Domain Controller completo em Rocky Linux 10,
# mantendo o Samba isolado em /opt/samba e usando somente componentes Open Source.
#
# Componentes:
#   - Samba AD DC compilado do fonte oficial (DNS interno + Heimdal embutido)
#   - Kerberos
#   - Chrony com MS-SNTP/ntp_signd
#   - Cockpit
#   - LDAP Account Manager Community (LAM)
#   - rsyslog + journald persistente
#   - Prometheus + node_exporter
#   - Grafana OSS
#   - BorgBackup + Restic
#   - backup local consistente do AD via samba-tool domain backup offline
#
# NÃO instala:
#   - Webmin
#   - CUPS
#   - BIND9_DLZ (a primeira versão usa o DNS interno do Samba)
#
# IMPORTANTE:
#   1. Execute em uma instalação NOVA do Rocky Linux 10.
#   2. O servidor deve ter IP estático.
#   3. Não use um domínio AD que você pretenda renomear depois.
#   4. Não use ".local" como domínio AD.
#   5. Teste primeiro em uma VM/laboratório.
#
# Exemplo não-interativo:
#
#   HOSTNAME_SHORT=dc1 \
#   AD_DNS_DOMAIN=ad.empresa.com.br \
#   NETBIOS_DOMAIN=EMPRESA \
#   DC_IP=192.168.10.10 \
#   DNS_FORWARDER=192.168.10.1 \
#   CLIENT_CIDRS="192.168.10.0/24,192.168.20.0/24" \
#   MGMT_CIDRS="192.168.10.0/24" \
#   ./scripts/install.sh
#
# A senha do Administrator do domínio será solicitada de forma oculta.
#
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# ---------------------------------------------------------------------------
# Versões fixadas
# ---------------------------------------------------------------------------
SAMBA_VERSION="${SAMBA_VERSION:-4.24.5}"
SAMBA_PREFIX="${SAMBA_PREFIX:-/opt/samba}"

# LAM 9.6 é a versão pretendida. Caso o tarball não esteja disponível,
# o instalador tenta 9.5.2 como fallback.
LAM_VERSION="${LAM_VERSION:-9.6}"
LAM_FALLBACK_VERSION="${LAM_FALLBACK_VERSION:-9.5.2}"
LAM_REQUESTED_VERSION="$LAM_VERSION"
LAM_REQUESTED_FALLBACK_VERSION="$LAM_FALLBACK_VERSION"

# ---------------------------------------------------------------------------
# Configurações gerais
# ---------------------------------------------------------------------------
HOSTNAME_SHORT="${HOSTNAME_SHORT:-}"
AD_DNS_DOMAIN="${AD_DNS_DOMAIN:-}"
NETBIOS_DOMAIN="${NETBIOS_DOMAIN:-}"
DC_IP="${DC_IP:-}"
DNS_FORWARDER="${DNS_FORWARDER:-}"
CLIENT_CIDRS="${CLIENT_CIDRS:-}"
MGMT_CIDRS="${MGMT_CIDRS:-}"

BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"
STRICT_STATIC_IP="${STRICT_STATIC_IP:-0}"
ALLOW_EXISTING_AD_DNS="${ALLOW_EXISTING_AD_DNS:-0}"
ALLOW_UNREACHABLE_DNS_FORWARDER="${ALLOW_UNREACHABLE_DNS_FORWARDER:-0}"
ALLOW_WIDE_CLIENT_CIDR="${ALLOW_WIDE_CLIENT_CIDR:-0}"
ALLOW_WIDE_ADMIN_CIDR="${ALLOW_WIDE_ADMIN_CIDR:-0}"
ALLOW_PERMISSIVE_FIREWALL_ZONE="${ALLOW_PERMISSIVE_FIREWALL_ZONE:-0}"
DNS_TEST_NAME="${DNS_TEST_NAME:-www.samba.org}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-}"
LAM_MASTER_PASSWORD="${LAM_MASTER_PASSWORD:-}"
LAM_SHA256="${LAM_SHA256:-}"
LAM_FALLBACK_SHA256="${LAM_FALLBACK_SHA256:-}"
LAM_EFFECTIVE_SHA256=""
INSTALLER_REVISION="0.5"
STATE_FORMAT_VERSION="2"
INSTALLER_SELF_SHA256=""
SAMBA_SOURCE_SHA256=""
SAMBA_GPG_FINGERPRINT="${SAMBA_GPG_FINGERPRINT:-81F5E2832BD2545A1897B713AA99442FB680B620}"
FIREWALL_ZONE=""
BUILD_USER="${BUILD_USER:-samba-build}"
BUILD_HOME="${BUILD_HOME:-/var/lib/samba-build}"

STATE_DIR="${STATE_DIR:-/var/lib/samba-ad-installer}"
STATE_CONFIG="${STATE_DIR}/config.env"
STATE_STEPS="${STATE_DIR}/steps"
RESUME_MODE=0

WORKDIR="${WORKDIR:-/usr/local/src/samba-ad-build}"
LOG_DIR="/var/log/samba-ad-installer"
LOG_FILE="${LOG_DIR}/install-$(date +%Y%m%d-%H%M%S).log"
INSTALLER_LOCK_FD=9

mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

# ---------------------------------------------------------------------------
# Utilitários
# ---------------------------------------------------------------------------
info()  { printf '\n\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[AVISO]\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31m[ERRO]\033[0m %s\n' "$*" >&2; exit 1; }

on_error() {
    local rc=$?
    printf '\n\033[1;31m[ERRO]\033[0m Falha na linha %s. Código=%s\n' "${BASH_LINENO[0]}" "$rc" >&2
    printf 'Consulte o log: %s\n' "$LOG_FILE" >&2
    exit "$rc"
}
trap on_error ERR

cleanup_secrets() {
    unset ADMIN_PASS ADMIN_PASS_2 GRAFANA_ADMIN_PASSWORD LAM_MASTER_PASSWORD 2>/dev/null || true
}
trap cleanup_secrets EXIT

require_root() {
    [[ $EUID -eq 0 ]] || die "Execute como root."
}


acquire_installer_lock() {
    mkdir -p /run/lock
    if command -v flock >/dev/null 2>&1; then
        eval "exec ${INSTALLER_LOCK_FD}>/run/lock/samba-ad-installer.lock"
        flock -n "$INSTALLER_LOCK_FD" || die "Já existe outro instalador Samba AD em execução."
        ok "Lock exclusivo do instalador adquirido."
    else
        warn "Comando flock não encontrado; proteção contra execução simultânea indisponível."
    fi
}

check_rocky10() {
    [[ -r /etc/os-release ]] || die "/etc/os-release não encontrado."
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ "${ID:-}" == "rocky" ]] || die "Este script foi feito para Rocky Linux. Detectado: ${ID:-desconhecido}"
    [[ "${VERSION_ID%%.*}" == "10" ]] || die "Este script requer Rocky Linux 10. Detectado: ${VERSION_ID:-desconhecido}"
}

load_resume_state() {
    if [[ -f "$STATE_CONFIG" ]]; then
        # Arquivo root-only criado pelo próprio instalador e sem senhas.
        # shellcheck disable=SC1090
        source "$STATE_CONFIG"

        local saved_format="${STATE_FORMAT_VERSION_SAVED:-0}"
        local saved_revision="${INSTALLER_REVISION_SAVED:-desconhecida}"
        if [[ "$saved_format" != "$STATE_FORMAT_VERSION" ]]; then
            die "Estado de instalação incompatível (formato=$saved_format, esperado=$STATE_FORMAT_VERSION; revisão=$saved_revision). Use uma VM limpa ou conclua com a mesma revisão que criou o estado."
        fi

        info "Instalação anterior gerenciada pelo instalador v${saved_revision} detectada; ativando modo RESUME."
        RESUME_MODE=1
        mkdir -p "$STATE_STEPS"
    fi
}

save_state_config() {
    mkdir -p "$STATE_STEPS"
    chmod 700 "$STATE_DIR" "$STATE_STEPS"

    {
        printf 'STATE_FORMAT_VERSION_SAVED=%q\n' "$STATE_FORMAT_VERSION"
        printf 'INSTALLER_REVISION_SAVED=%q\n' "$INSTALLER_REVISION"
        printf 'HOSTNAME_SHORT=%q\n' "$HOSTNAME_SHORT"
        printf 'AD_DNS_DOMAIN=%q\n' "$AD_DNS_DOMAIN"
        printf 'NETBIOS_DOMAIN=%q\n' "$NETBIOS_DOMAIN"
        printf 'DC_IP=%q\n' "$DC_IP"
        printf 'DC_IFACE=%q\n' "$DC_IFACE"
        printf 'DNS_FORWARDER=%q\n' "$DNS_FORWARDER"
        printf 'CLIENT_CIDRS=%q\n' "$CLIENT_CIDRS"
        printf 'MGMT_CIDRS=%q\n' "$MGMT_CIDRS"
        printf 'SAMBA_VERSION=%q\n' "$SAMBA_VERSION"
        printf 'SAMBA_PREFIX=%q\n' "$SAMBA_PREFIX"
        printf 'SAMBA_SOURCE_SHA256=%q\n' "$SAMBA_SOURCE_SHA256"
        printf 'SAMBA_GPG_FINGERPRINT=%q\n' "$SAMBA_GPG_FINGERPRINT"
        printf 'LAM_VERSION=%q\n' "$LAM_VERSION"
        printf 'LAM_EFFECTIVE_SHA256=%q\n' "$LAM_EFFECTIVE_SHA256"
        printf 'FIREWALL_ZONE=%q\n' "$FIREWALL_ZONE"
        printf 'BUILD_USER=%q\n' "$BUILD_USER"
        printf 'BUILD_HOME=%q\n' "$BUILD_HOME"
        printf 'BACKUP_RETENTION_DAYS=%q\n' "$BACKUP_RETENTION_DAYS"
    } >"$STATE_CONFIG"
    chmod 600 "$STATE_CONFIG"
}

step_done() {
    [[ -f "${STATE_STEPS}/$1.done" ]]
}

mark_step() {
    mkdir -p "$STATE_STEPS"
    # Persiste também valores descobertos durante a etapa (hash do fonte,
    # versão efetiva do LAM, zona do firewall etc.) para uma retomada fiel.
    save_state_config
    printf '%s\n' "$(date -Is)" >"${STATE_STEPS}/$1.done"
    chmod 600 "${STATE_STEPS}/$1.done"
}

run_step() {
    local name="$1"
    shift
    if step_done "$name"; then
        ok "Etapa já concluída anteriormente: $name"
        return 0
    fi

    info "Etapa: $name"
    "$@"
    mark_step "$name"
}

prompt_value() {
    local var_name="$1"
    local prompt="$2"
    local default="${3:-}"
    local current="${!var_name:-}"
    local value=""

    [[ -n "$current" ]] && return 0

    if [[ -n "$default" ]]; then
        read -r -p "$prompt [$default]: " value
        value="${value:-$default}"
    else
        while [[ -z "$value" ]]; do
            read -r -p "$prompt: " value
        done
    fi

    printf -v "$var_name" '%s' "$value"
}

validate_domain() {
    local d="$1"
    local rc=0
    python3 - "$d" <<'PY' || rc=$?
import sys
d = sys.argv[1].rstrip(".")
if len(d) > 253 or "." not in d:
    raise SystemExit(1)
if d.lower().endswith(".local"):
    raise SystemExit(2)
for label in d.split("."):
    if not (1 <= len(label) <= 63):
        raise SystemExit(1)
    if not label[0].isalnum() or not label[-1].isalnum():
        raise SystemExit(1)
    if any(not (c.isalnum() or c == "-") for c in label):
        raise SystemExit(1)
PY
    case "$rc" in
        0) ;;
        2) die "Não use .local como domínio AD." ;;
        *) die "Domínio AD inválido: $d. Ex.: ad.empresa.com.br" ;;
    esac
}

validate_netbios() {
    local n="$1"
    [[ ${#n} -ge 1 && ${#n} -le 15 ]] || die "NETBIOS_DOMAIN deve ter entre 1 e 15 caracteres."
    [[ "$n" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*[A-Za-z0-9]$ || ${#n} -eq 1 && "$n" =~ ^[A-Za-z0-9]$ ]] || \
        die "NETBIOS_DOMAIN inválido; use letras/números e, internamente, '-' ou '_'."
}

validate_hostname_short() {
    local n="$1"
    [[ ${#n} -ge 1 && ${#n} -le 15 ]] || die "HOSTNAME_SHORT deve ter entre 1 e 15 caracteres."
    [[ "$n" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || \
        die "Hostname curto inválido; não use hífen no início/fim."
}

validate_ipv4() {
    python3 - "$1" <<'PY'
import ipaddress, sys
try:
    ipaddress.IPv4Address(sys.argv[1])
except Exception:
    raise SystemExit(1)
PY
}

validate_cidr_list() {
    local list="$1"
    python3 - "$list" <<'PY'
import ipaddress, sys
items = [x.strip() for x in sys.argv[1].split(",") if x.strip()]
if not items:
    raise SystemExit(1)
for item in items:
    try:
        net = ipaddress.ip_network(item, strict=False)
        if net.version != 4:
            raise ValueError("IPv6 não suportado")
    except Exception:
        print(f"CIDR inválido: {item}", file=sys.stderr)
        raise SystemExit(1)
PY
}


normalize_cidr_list() {
    local list="$1"
    python3 - "$list" <<'PY'
import ipaddress, sys
items = [x.strip() for x in sys.argv[1].split(",") if x.strip()]
seen = set()
out = []
for item in items:
    net = ipaddress.ip_network(item, strict=False)
    if net.version != 4:
        raise SystemExit("IPv6 não suportado")
    canonical = str(net)
    if canonical not in seen:
        seen.add(canonical)
        out.append(canonical)
print(",".join(out))
PY
}

guard_wide_cidrs() {
    if grep -qx '0.0.0.0/0' < <(split_csv "$CLIENT_CIDRS"); then
        if [[ "$ALLOW_WIDE_CLIENT_CIDR" != "1" ]]; then
            die "CLIENT_CIDRS inclui 0.0.0.0/0. Isso exporia as portas do AD a qualquer IPv4. Use ALLOW_WIDE_CLIENT_CIDR=1 somente se for realmente intencional."
        fi
        warn "CLIENT_CIDRS contém 0.0.0.0/0 por autorização explícita."
    fi

    if grep -qx '0.0.0.0/0' < <(split_csv "$MGMT_CIDRS"); then
        if [[ "$ALLOW_WIDE_ADMIN_CIDR" != "1" ]]; then
            die "MGMT_CIDRS inclui 0.0.0.0/0. Isso exporia as interfaces administrativas. Use ALLOW_WIDE_ADMIN_CIDR=1 somente se for realmente intencional."
        fi
        warn "MGMT_CIDRS contém 0.0.0.0/0 por autorização explícita."
    fi
}

validate_admin_password() {
    local pw="$1"
    local classes=0

    (( ${#pw} >= 12 )) || die "A senha do Administrator deve ter pelo menos 12 caracteres."
    [[ "$pw" =~ [A-Z] ]] && ((classes+=1))
    [[ "$pw" =~ [a-z] ]] && ((classes+=1))
    [[ "$pw" =~ [0-9] ]] && ((classes+=1))
    [[ "$pw" =~ [^A-Za-z0-9] ]] && ((classes+=1))
    (( classes >= 3 )) || die "Use ao menos 3 classes na senha: maiúsculas, minúsculas, números e símbolos."
}

check_selinux_mode() {
    if command -v getenforce >/dev/null 2>&1; then
        local mode
        mode="$(getenforce)"
        if [[ "$mode" == "Enforcing" ]]; then
            ok "SELinux está Enforcing."
        else
            warn "SELinux está em modo '$mode'. O instalador não o desativa, mas recomenda Enforcing."
        fi
    fi
}

check_multiple_ipv4() {
    local count
    count="$(ip -o -4 addr show scope global | wc -l)"
    if (( count > 1 )); then
        warn "Foram encontrados ${count} endereços IPv4 globais neste host."
        warn "DCs multihomed exigem atenção especial ao registro DNS. Interface escolhida: ${DC_IFACE}."
        ip -o -4 addr show scope global || true
    fi
}

check_system_resources() {
    mkdir -p "$WORKDIR"
    local mem_mb disk_mb
    mem_mb="$(awk '/MemAvailable:/ {printf "%d", $2/1024}' /proc/meminfo)"
    disk_mb="$(df -Pm "$WORKDIR" | awk 'NR==2 {print $4}')"

    info "Recursos para compilação"
    printf '  Memória disponível : %s MB\n' "${mem_mb:-0}"
    printf '  Disco livre build  : %s MB\n' "${disk_mb:-0}"
    printf '  Jobs make          : %s\n' "$BUILD_JOBS"

    (( disk_mb >= 2048 )) || die "Menos de 2 GB livres em $WORKDIR; não é seguro iniciar a compilação."
    (( disk_mb >= 4096 )) || warn "Menos de 4 GB livres em $WORKDIR; acompanhe o espaço durante o build."
    (( mem_mb >= 2048 )) || warn "Menos de 2 GB de RAM disponível; a compilação pode sofrer OOM/swap excessivo."

    local suggested_jobs=$(( mem_mb / 768 ))
    (( suggested_jobs < 1 )) && suggested_jobs=1
    if (( BUILD_JOBS > suggested_jobs )); then
        warn "BUILD_JOBS=$BUILD_JOBS pode ser agressivo para ${mem_mb} MB disponíveis; sugestão conservadora: ${suggested_jobs}."
    fi
}

prepare_build_user() {
    if ! id "$BUILD_USER" >/dev/null 2>&1; then
        info "Criando usuário sem privilégios para compilação: $BUILD_USER"
        useradd --system --home-dir "$BUILD_HOME" --create-home --shell /sbin/nologin "$BUILD_USER"
    fi
    mkdir -p "$BUILD_HOME" "$WORKDIR"
    chown "$BUILD_USER:$BUILD_USER" "$BUILD_HOME"
    chmod 750 "$BUILD_HOME"
    # WORKDIR continua root-owned, mas o build user precisa atravessá-lo para
    # acessar apenas a árvore de fontes que será chown'ed explicitamente.
    chmod 755 "$WORKDIR"
}

detect_network() {
    local detected_iface detected_ip detected_cidr detected_subnet

    detected_iface="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')"
    [[ -n "$detected_iface" ]] || detected_iface="$(ip -o -4 addr show scope global | awk '{print $2; exit}')"
    [[ -n "$detected_iface" ]] || die "Não foi possível detectar a interface IPv4."

    detected_cidr="$(ip -o -4 addr show dev "$detected_iface" scope global | awk '{print $4; exit}')"
    [[ -n "$detected_cidr" ]] || die "Nenhum IPv4 global encontrado em $detected_iface."
    detected_ip="${detected_cidr%/*}"

    detected_subnet="$(python3 - "$detected_cidr" <<'PY'
import ipaddress, sys
print(ipaddress.ip_interface(sys.argv[1]).network)
PY
)"

    DC_IFACE="$detected_iface"
    DETECTED_IP="$detected_ip"
    DETECTED_SUBNET="$detected_subnet"
}

get_current_dns() {
    awk '/^nameserver[[:space:]]+/ {print $2}' /etc/resolv.conf 2>/dev/null \
        | grep -Ev '^(127\.|::1$)' | head -n1 || true
}

split_csv() {
    tr ',' '\n' <<< "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/d'
}

check_static_ip_hint() {
    local con
    con="$(nmcli -g GENERAL.CONNECTION device show "$DC_IFACE" 2>/dev/null | head -n1 || true)"
    if [[ -n "$con" && "$con" != "--" ]]; then
        local method
        method="$(nmcli -g ipv4.method connection show "$con" 2>/dev/null || true)"
        if [[ "$method" != "manual" ]]; then
            warn "A conexão NetworkManager '$con' usa ipv4.method=$method."
            warn "Para um AD estável, o endereço $DC_IP deve permanecer fixo (IP manual ou reserva DHCP confiável)."
            if [[ "$STRICT_STATIC_IP" == "1" ]]; then
                die "STRICT_STATIC_IP=1 e a conexão não usa ipv4.method=manual."
            fi
        else
            ok "IPv4 da conexão NetworkManager está configurado manualmente."
        fi
    fi
}

preflight_dns_collision_check() {
    local fqdn="${HOSTNAME_SHORT}.${AD_DNS_DOMAIN}"
    info "Verificando DNS forwarder e possíveis colisões DNS/AD"

    [[ "$DNS_FORWARDER" != "$DC_IP" ]] || die "DNS_FORWARDER não pode ser o próprio DC ($DC_IP) antes do provisionamento."
    [[ "$DNS_FORWARDER" != "127.0.0.1" ]] || die "DNS_FORWARDER não pode ser 127.0.0.1."

    # Confirma que há um servidor DNS respondendo no endereço informado. O nome
    # consultado pode retornar NXDOMAIN e ainda assim a resposta é válida; o que
    # queremos distinguir aqui é resposta DNS de timeout/conexão impossível.
    local probe=""
    probe="$(dig @"$DNS_FORWARDER" "$AD_DNS_DOMAIN" SOA +time=2 +tries=1 +comments 2>&1 || true)"
    if grep -q 'status:' <<<"$probe"; then
        ok "DNS forwarder $DNS_FORWARDER respondeu ao preflight."
    elif [[ "$ALLOW_UNREACHABLE_DNS_FORWARDER" == "1" ]]; then
        warn "DNS forwarder $DNS_FORWARDER não respondeu; prosseguindo por ALLOW_UNREACHABLE_DNS_FORWARDER=1."
    else
        printf '%s\n' "$probe" >&2
        die "DNS forwarder $DNS_FORWARDER não respondeu. Corrija-o ou, somente se intencional, use ALLOW_UNREACHABLE_DNS_FORWARDER=1."
    fi

    local existing_a=""
    existing_a="$(host -W 2 -t A "$fqdn" "$DNS_FORWARDER" 2>/dev/null | awk '/has address/ {print $NF; exit}' || true)"
    if [[ -n "$existing_a" && "$existing_a" != "$DC_IP" ]]; then
        warn "$fqdn já resolve no DNS upstream para $existing_a, diferente de $DC_IP."
        warn "Isso pode causar ambiguidade de DNS."
    fi

    local existing_srv=""
    existing_srv="$(host -W 2 -t SRV "_ldap._tcp.${AD_DNS_DOMAIN}" "$DNS_FORWARDER" 2>/dev/null | grep 'SRV record' || true)"
    if [[ -n "$existing_srv" ]]; then
        warn "Já existem registros _ldap._tcp para ${AD_DNS_DOMAIN} no DNS upstream:"
        printf '%s\n' "$existing_srv"
        if [[ "$ALLOW_EXISTING_AD_DNS" != "1" ]]; then
            die "Possível AD existente detectado. Se isto for intencional, revise a topologia; para ignorar somente o bloqueio use ALLOW_EXISTING_AD_DNS=1."
        fi
    else
        ok "Nenhum AD existente foi detectado para ${AD_DNS_DOMAIN} no DNS forwarder."
    fi
}

ensure_fresh_dc() {
    if [[ -e "${SAMBA_PREFIX}/private/sam.ldb" || -e "${SAMBA_PREFIX}/etc/samba/smb.conf" ]]; then
        if (( RESUME_MODE == 1 )); then
            ok "Samba existente reconhecido como instalação v0.5 em retomada."
        else
            die "Já há indícios de um domínio Samba em ${SAMBA_PREFIX}. O script não sobrescreve um DC existente que não tenha estado de instalação v0.5."
        fi
    fi

    local rpm_pkg
    for rpm_pkg in samba samba-dc samba-common; do
        if rpm -q "$rpm_pkg" >/dev/null 2>&1; then
            warn "Foi detectado o pacote Samba do sistema: $rpm_pkg"
            die "Use uma instalação limpa do Rocky 10 ou remova os pacotes Samba antes de continuar."
        fi
    done
}

install_pkg_required() {
    local pkg="$1"
    if rpm -q "$pkg" >/dev/null 2>&1; then
        return 0
    fi
    info "Instalando pacote obrigatório: $pkg"
    dnf -y install "$pkg"
}

install_pkg_list_required() {
    (( $# > 0 )) || return 0
    info "Instalando lote de pacotes obrigatórios (${#} itens)"
    dnf -y install "$@"
}

install_pkg_optional() {
    local pkg="$1"
    if rpm -q "$pkg" >/dev/null 2>&1; then
        return 0
    fi
    if dnf -q list --available "$pkg" >/dev/null 2>&1; then
        dnf -y install "$pkg"
    else
        warn "Pacote opcional não disponível: $pkg"
    fi
}

port_conflict_check() {
    local conflict
    conflict="$(ss -H -lntup 2>/dev/null | grep -E ':(53|88|135|137|138|139|389|445|464|636|3268|3269)([[:space:]]|$)' || true)"
    if [[ -n "$conflict" ]]; then
        printf '%s\n' "$conflict"
        die "Há serviços ocupando uma ou mais portas essenciais do AD."
    fi
}

# ---------------------------------------------------------------------------
# Repositórios e dependências
# ---------------------------------------------------------------------------
enable_repositories() {
    info "Habilitando CRB e EPEL"
    dnf -y install dnf-plugins-core epel-release

    if command -v crb >/dev/null 2>&1; then
        crb enable || warn "O comando 'crb enable' retornou erro; tentando config-manager."
    fi

    if dnf repolist --all 2>/dev/null | grep -qE '^crb[[:space:]]'; then
        dnf config-manager --set-enabled crb 2>/dev/null || \
        dnf config-manager setopt crb.enabled=1 2>/dev/null || true
    fi

    dnf -y makecache
}

install_build_dependencies() {
    info "Instalando dependências para compilar o Samba AD DC"

    local required=(
        gcc gcc-c++ make
        python3 python3-devel
        perl perl-ExtUtils-MakeMaker perl-Parse-Yapp
        acl attr
        gnutls-devel
        zlib-devel
        flex
        jansson-devel
        libacl-devel
        libattr-devel
        libarchive-devel
        libblkid-devel
        libtasn1-devel
        libxml2-devel
        libxslt-devel
        lmdb-devel
        pam-devel
        popt-devel
        readline-devel
        systemd-devel
        keyutils-libs-devel
        libaio-devel
        openldap-devel
        rpcgen
        pkgconf-pkg-config
        curl wget tar gzip bzip2 xz zstd util-linux
        gnupg2 openssl logrotate ca-certificates
        krb5-workstation
        bind-utils
        chrony
        firewalld
        NetworkManager
        rsyslog
        policycoreutils-python-utils
    )

    install_pkg_list_required "${required[@]}"

    local p
    local optional=(
        gpgme-devel
        libtasn1-tools
        docbook-style-xsl
        python3-cryptography
        python3-dns
        python3-gpg
        python3-markdown
        libcap-devel
        libtirpc-devel
        rpcsvc-proto-devel
        dbus-devel
    )
    for p in "${optional[@]}"; do
        install_pkg_optional "$p"
    done
    install_pkg_optional glibc-langpack-pt
}

# ---------------------------------------------------------------------------
# Hostname e hosts
# ---------------------------------------------------------------------------
configure_hostname() {
    local fqdn="${HOSTNAME_SHORT}.${AD_DNS_DOMAIN}"

    info "Configurando hostname: $fqdn"
    hostnamectl set-hostname "$fqdn"

    cp -a /etc/hosts "/etc/hosts.pre-samba-ad.$(date +%s)"

    python3 - "$DC_IP" "$fqdn" "$HOSTNAME_SHORT" <<'PY'
from pathlib import Path
import sys, re
ip, fqdn, short = sys.argv[1:]
p = Path("/etc/hosts")
lines = p.read_text().splitlines()
out = []
for line in lines:
    if line.lstrip().startswith("#") or not line.strip():
        out.append(line)
        continue
    fields = re.split(r"\s+", line.strip())
    names = fields[1:]
    if fqdn in names or short in names:
        continue
    out.append(line)
out.append(f"{ip}\t{fqdn}\t{short}")
p.write_text("\n".join(out) + "\n")
PY

    # Nesta etapa o DNS do novo AD ainda não existe. Portanto, a fonte
    # autoritativa para a validação inicial é /etc/hosts. O teste via NSS/getent
    # é útil como diagnóstico, mas não deve impedir o provisionamento.
    if ! awk -v ip="$DC_IP" -v fqdn="$fqdn" '
        $0 !~ /^[[:space:]]*#/ && $1 == ip {
            for (i = 2; i <= NF; i++) {
                if ($i == fqdn) found = 1
            }
        }
        END { exit(found ? 0 : 1) }
    ' /etc/hosts; then
        die "A entrada esperada '$DC_IP $fqdn $HOSTNAME_SHORT' não foi gravada corretamente em /etc/hosts."
    fi

    local nss_ip=""
    nss_ip="$(getent ahostsv4 "$fqdn" 2>/dev/null | awk 'NR==1 {print $1}' || true)"

    if [[ "$nss_ip" == "$DC_IP" ]]; then
        ok "Resolução local inicial confirmada: $fqdn -> $DC_IP"
    else
        warn "O NSS/getent ainda não retornou $DC_IP para $fqdn nesta etapa."
        warn "A entrada correta existe em /etc/hosts; prosseguindo. O DNS será validado novamente após o provisionamento do Samba AD."
    fi

    local hf
    hf="$(hostname -f 2>/dev/null || true)"
    [[ "${hf,,}" == "${fqdn,,}" ]] || die "hostname -f retornou '$hf'; esperado '$fqdn'."
    ok "Hostname FQDN confirmado: $hf"
}

# ---------------------------------------------------------------------------
# Samba
# ---------------------------------------------------------------------------
download_and_verify_samba() {
    mkdir -p "$WORKDIR"
    cd "$WORKDIR"

    local gz_file="samba-${SAMBA_VERSION}.tar.gz"
    local tar_file="samba-${SAMBA_VERSION}.tar"
    local sig_file="${tar_file}.asc"

    local base_url="https://download.samba.org/pub/samba/stable"
    local gz_url="${base_url}/${gz_file}"
    local sig_url="${base_url}/${sig_file}"

    if [[ ! -f "$gz_file" ]]; then
        info "Baixando Samba ${SAMBA_VERSION}"
        curl -fL --retry 3 --retry-delay 2 -o "${gz_file}.part" "$gz_url"
        mv -f "${gz_file}.part" "$gz_file"
    else
        ok "Fonte compactado já existe: ${WORKDIR}/${gz_file}"
    fi

    if [[ ! -f "$sig_file" ]]; then
        info "Baixando assinatura oficial: ${sig_file}"
        curl -fL --retry 3 --retry-delay 2 -o "${sig_file}.part" "$sig_url"
        mv -f "${sig_file}.part" "$sig_file"
    else
        ok "Assinatura já existe: ${WORKDIR}/${sig_file}"
    fi

    local gnupg_dir="${WORKDIR}/gnupg"
    mkdir -p "$gnupg_dir"
    chmod 700 "$gnupg_dir"

    info "Baixando chave pública de distribuição do Samba"
    curl -fL --retry 3 --retry-delay 2 \
        -o "${WORKDIR}/samba-pubkey.asc.part" \
        "https://www.samba.org/samba/ftp/samba-pubkey.asc"
    mv -f "${WORKDIR}/samba-pubkey.asc.part" "${WORKDIR}/samba-pubkey.asc"

    GNUPGHOME="$gnupg_dir" \
        gpg --batch --import "${WORKDIR}/samba-pubkey.asc" >/dev/null 2>&1 || true

    local imported_fingerprint
    imported_fingerprint="$(GNUPGHOME="$gnupg_dir" gpg --batch --with-colons --fingerprint \
        "Samba Distribution Verification Key" 2>/dev/null | awk -F: '$1=="fpr" {print $10; exit}')"
    [[ "${imported_fingerprint^^}" == "${SAMBA_GPG_FINGERPRINT^^}" ]] || \
        die "Fingerprint da chave Samba inesperado: ${imported_fingerprint:-não encontrado}."
    ok "Fingerprint da chave Samba confirmado: ${imported_fingerprint}"

    # O Samba assina o .tar DESCOMPACTADO, não o .tar.gz.
    # Criamos o .tar sem destruir o .tar.gz para permitir reexecução do script.
    info "Preparando tarball descompactado para validação GPG"
    gzip -dc "$gz_file" > "${tar_file}.tmp"
    mv -f "${tar_file}.tmp" "$tar_file"

    info "Verificando assinatura GPG oficial do Samba"
    if ! GNUPGHOME="$gnupg_dir" \
        gpg --batch --verify "$sig_file" "$tar_file"; then
        rm -f "$tar_file" "$gz_file" "$sig_file"
        die "A assinatura GPG do Samba ${SAMBA_VERSION} NÃO pôde ser validada. Os arquivos baixados foram removidos."
    fi

    ok "Assinatura GPG do Samba ${SAMBA_VERSION} validada."
    SAMBA_SOURCE_SHA256="$(sha256sum "$gz_file" | awk '{print $1}')"
    printf 'SHA256 do fonte: %s\n' "$SAMBA_SOURCE_SHA256"

    rm -rf "samba-${SAMBA_VERSION}"
    tar xf "$tar_file"
}

build_samba() {
    if [[ -x "${SAMBA_PREFIX}/bin/samba-tool" ]]; then
        local existing
        existing="$("${SAMBA_PREFIX}/bin/samba-tool" --version 2>/dev/null || true)"
        if [[ "$existing" == "$SAMBA_VERSION" ]]; then
            ok "Samba $SAMBA_VERSION já está instalado em $SAMBA_PREFIX."
            if [[ -f "${WORKDIR}/samba-${SAMBA_VERSION}.tar.gz" ]]; then
                SAMBA_SOURCE_SHA256="$(sha256sum "${WORKDIR}/samba-${SAMBA_VERSION}.tar.gz" | awk '{print $1}')"
            elif [[ -z "$SAMBA_SOURCE_SHA256" ]]; then
                SAMBA_SOURCE_SHA256="unknown-resumed-install"
            fi
            return 0
        fi
        die "Há outra versão do Samba em $SAMBA_PREFIX ($existing). Atualização automática não será feita."
    fi

    download_and_verify_samba

    local source_dir="${WORKDIR}/samba-${SAMBA_VERSION}"
    chown -R "$BUILD_USER:$BUILD_USER" "$source_dir"
    cd "$source_dir"

    info "Configurando compilação do Samba em ${SAMBA_PREFIX} como usuário $BUILD_USER"
    runuser -u "$BUILD_USER" -- env HOME="$BUILD_HOME" \
        ./configure \
            --prefix="$SAMBA_PREFIX" \
            --disable-cups

    info "Compilando Samba com ${BUILD_JOBS} jobs como usuário $BUILD_USER"
    runuser -u "$BUILD_USER" -- env HOME="$BUILD_HOME" make -j"$BUILD_JOBS"

    info "Instalando Samba como root"
    make install

    cat >/etc/ld.so.conf.d/samba-ad.conf <<EOF
${SAMBA_PREFIX}/lib
${SAMBA_PREFIX}/lib64
EOF
    ldconfig

    cat >/etc/profile.d/samba-ad.sh <<EOF
export PATH="${SAMBA_PREFIX}/bin:${SAMBA_PREFIX}/sbin:\$PATH"
EOF
    chmod 644 /etc/profile.d/samba-ad.sh

    export PATH="${SAMBA_PREFIX}/bin:${SAMBA_PREFIX}/sbin:${PATH}"

    "${SAMBA_PREFIX}/bin/samba-tool" --version
    "${SAMBA_PREFIX}/sbin/smbd" -b | grep -E 'CONFIGFILE|PRIVATE_DIR|LOCKDIR|STATEDIR|CACHEDIR' || true
}

set_smb_global_value() {
    local conf="$1"
    local key="$2"
    local value="$3"

    python3 - "$conf" "$key" "$value" <<'PY'
from pathlib import Path
import sys, re

path, key, value = sys.argv[1:]
p = Path(path)
lines = p.read_text().splitlines()
key_re = re.compile(r"^\s*" + re.escape(key) + r"\s*=", re.I)

in_global = False
done = False
out = []

for line in lines:
    stripped = line.strip()
    if stripped.startswith("[") and stripped.endswith("]"):
        if in_global and not done:
            out.append(f"\t{key} = {value}")
            done = True
        in_global = stripped.lower() == "[global]"
        out.append(line)
        continue

    if in_global and key_re.match(line):
        if not done:
            out.append(f"\t{key} = {value}")
            done = True
        continue

    out.append(line)

if in_global and not done:
    out.append(f"\t{key} = {value}")
    done = True

if not done:
    raise SystemExit(f"Não encontrei [global] em {path}")

p.write_text("\n".join(out) + "\n")
PY
}

provision_domain() {
    export PATH="${SAMBA_PREFIX}/bin:${SAMBA_PREFIX}/sbin:${PATH}"

    local realm="${AD_DNS_DOMAIN^^}"
    local fqdn="${HOSTNAME_SHORT}.${AD_DNS_DOMAIN}"
    local smb_conf
    local private_dir
    local samdb

    smb_conf="$("${SAMBA_PREFIX}/sbin/smbd" -b | awk -F': ' '/CONFIGFILE:/ {print $2; exit}')"
    private_dir="$("${SAMBA_PREFIX}/sbin/smbd" -b | awk -F': ' '/PRIVATE_DIR:/ {print $2; exit}')"
    [[ -n "$smb_conf" && -n "$private_dir" ]] || die "Não foi possível descobrir CONFIGFILE/PRIVATE_DIR do Samba."
    samdb="${private_dir}/sam.ldb"

    if [[ -e "$samdb" ]]; then
        # Uma queda pode ocorrer depois de 'domain provision' e antes do marker da
        # etapa. Nunca reprovisionamos. Se smb.conf/realm/workgroup forem coerentes,
        # apenas retomamos as ações pós-provisionamento de forma idempotente.
        [[ -f "$smb_conf" ]] || die "sam.ldb existe, mas smb.conf não existe; intervenção manual necessária."

        local existing_realm existing_workgroup
        existing_realm="$("${SAMBA_PREFIX}/bin/testparm" -s --parameter-name=realm "$smb_conf" 2>/dev/null | tr -d '[:space:]' || true)"
        existing_workgroup="$("${SAMBA_PREFIX}/bin/testparm" -s --parameter-name=workgroup "$smb_conf" 2>/dev/null | tr -d '[:space:]' || true)"

        [[ "${existing_realm^^}" == "$realm" ]] || \
            die "Provisionamento parcial aponta para realm '$existing_realm', esperado '$realm'. Não vou alterar o banco."
        [[ "${existing_workgroup^^}" == "${NETBIOS_DOMAIN^^}" ]] || \
            die "Provisionamento parcial aponta para workgroup '$existing_workgroup', esperado '$NETBIOS_DOMAIN'."

        warn "Banco AD já existe e corresponde aos parâmetros esperados; retomando pós-provisionamento sem recriar o domínio."
    else
        if [[ -f "$smb_conf" ]]; then
            mv "$smb_conf" "${smb_conf}.pre-provision.$(date +%s)"
        fi

        info "Provisionando novo domínio AD: ${AD_DNS_DOMAIN} / ${NETBIOS_DOMAIN}"
        "${SAMBA_PREFIX}/bin/samba-tool" domain provision \
            --server-role=dc \
            --use-rfc2307 \
            --dns-backend=SAMBA_INTERNAL \
            --realm="$realm" \
            --domain="$NETBIOS_DOMAIN" \
            --adminpass="$ADMIN_PASS"
    fi

    set_smb_global_value "$smb_conf" "dns forwarder" "$DNS_FORWARDER"

    # Mantém o comportamento padrão moderno de RPC, mas deixa explícito para o firewall.
    set_smb_global_value "$smb_conf" "rpc server dynamic port range" "49152-65535"

    info "Validando smb.conf"
    "${SAMBA_PREFIX}/bin/samba-tool" testparm --suppress-prompt

    [[ -f "${private_dir}/krb5.conf" ]] || die "krb5.conf gerado pelo Samba não encontrado em ${private_dir}."

    if [[ -f /etc/krb5.conf ]] && ! cmp -s "${private_dir}/krb5.conf" /etc/krb5.conf; then
        cp -a /etc/krb5.conf "/etc/krb5.conf.pre-samba-ad.$(date +%s)"
    fi
    cp -f "${private_dir}/krb5.conf" /etc/krb5.conf
    chmod 644 /etc/krb5.conf

    ok "Domínio provisionado/validado."
    printf 'FQDN do DC: %s\n' "$fqdn"
}

install_samba_systemd() {
    info "Criando serviço systemd do Samba AD DC"

    cat >/etc/systemd/system/samba-ad-dc.service <<EOF
[Unit]
Description=Samba Active Directory Domain Controller
Documentation=https://www.samba.org/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=${SAMBA_PREFIX}/bin/samba-tool testparm --suppress-prompt
ExecStart=${SAMBA_PREFIX}/sbin/samba --foreground --no-process-group
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5s
TimeoutStopSec=60s
LimitNOFILE=16384

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable NetworkManager-wait-online.service 2>/dev/null || true
    systemctl enable --now samba-ad-dc.service
    sleep 3

    systemctl is-active --quiet samba-ad-dc.service || {
        systemctl --no-pager -l status samba-ad-dc.service || true
        journalctl -u samba-ad-dc.service -n 100 --no-pager || true
        die "Samba AD DC não iniciou."
    }

    ok "Samba AD DC ativo."
}

configure_resolver_to_self() {
    info "Configurando o próprio DC como resolvedor DNS"

    local con
    con="$(nmcli -g GENERAL.CONNECTION device show "$DC_IFACE" 2>/dev/null | head -n1 || true)"

    if [[ -n "$con" && "$con" != "--" ]]; then
        nmcli connection modify "$con" \
            ipv4.ignore-auto-dns yes \
            ipv4.dns "$DC_IP" \
            ipv4.dns-search "$AD_DNS_DOMAIN"
        nmcli device reapply "$DC_IFACE" || true
        sleep 1
    else
        warn "Conexão NetworkManager não encontrada. Gravando /etc/resolv.conf diretamente."
        cp -a /etc/resolv.conf "/etc/resolv.conf.pre-samba-ad.$(date +%s)" || true
        cat >/etc/resolv.conf <<EOF
search ${AD_DNS_DOMAIN}
nameserver ${DC_IP}
EOF
    fi

    if ! grep -Eq "^nameserver[[:space:]]+${DC_IP//./\\.}([[:space:]]|$)" /etc/resolv.conf; then
        warn "/etc/resolv.conf ainda não aponta diretamente para $DC_IP. Verifique o NetworkManager."
    else
        ok "Resolver local aponta para o DNS do próprio DC."
    fi

    if ! host -t A "${HOSTNAME_SHORT}.${AD_DNS_DOMAIN}" "$DC_IP" >/dev/null 2>&1; then
        die "O DNS Samba não respondeu corretamente pelo endereço $DC_IP após configurar o resolver."
    fi
}


configure_samba_tls_trust() {
    info "Confiando localmente na CA TLS gerada pelo Samba para LDAPS"

    local private_dir ca cert anchor
    private_dir="$("${SAMBA_PREFIX}/sbin/smbd" -b | awk -F': ' '/PRIVATE_DIR:/ {print $2; exit}')"
    ca="${private_dir}/tls/ca.pem"
    cert="${private_dir}/tls/cert.pem"
    anchor="/etc/pki/ca-trust/source/anchors/samba-ad-local-ca.pem"

    # O Samba normalmente cria os arquivos TLS no primeiro start. Damos alguns
    # segundos para a geração antes de considerar que há um problema.
    local i
    for i in {1..10}; do
        [[ -s "$ca" && -s "$cert" ]] && break
        sleep 1
    done

    [[ -s "$ca" && -s "$cert" ]] || die "Certificados TLS automáticos do Samba não foram encontrados em ${private_dir}/tls."

    cp -f "$ca" "$anchor"
    chmod 644 "$anchor"
    restorecon "$anchor" 2>/dev/null || true
    update-ca-trust extract

    openssl x509 -in "$cert" -noout -subject -issuer -dates
    if openssl x509 -checkend 2592000 -noout -in "$cert" >/dev/null; then
        ok "Certificado LDAP TLS do Samba válido por mais de 30 dias."
    else
        warn "Certificado LDAP TLS do Samba expira em menos de 30 dias. Planeje substituição/renovação."
    fi
}

# ---------------------------------------------------------------------------
# Chrony / tempo assinado
# ---------------------------------------------------------------------------
configure_chrony() {
    info "Configurando Chrony para clientes do domínio"

    systemctl enable --now chronyd

    local ntp_dir
    ntp_dir="$(find "$SAMBA_PREFIX" -type d -name ntp_signd -print -quit 2>/dev/null || true)"

    if [[ -z "$ntp_dir" ]]; then
        warn "Diretório ntp_signd ainda não encontrado. Reiniciando Samba e tentando novamente."
        systemctl restart samba-ad-dc
        sleep 2
        ntp_dir="$(find "$SAMBA_PREFIX" -type d -name ntp_signd -print -quit 2>/dev/null || true)"
    fi

    if [[ -z "$ntp_dir" ]]; then
        warn "Não foi possível localizar ntp_signd. Chrony ficará ativo, mas MS-SNTP assinado exigirá ajuste manual."
        return 0
    fi

    if getent group chrony >/dev/null; then
        chown root:chrony "$ntp_dir"
    fi
    chmod 0750 "$ntp_dir"

    local chrony_conf="/etc/chrony.conf"
    cp -a "$chrony_conf" "${chrony_conf}.pre-samba-ad.$(date +%s)"

    # Remove somente blocos anteriormente criados por este script.
    sed -i '/^# BEGIN SAMBA-AD$/,/^# END SAMBA-AD$/d' "$chrony_conf"

    {
        echo
        echo "# BEGIN SAMBA-AD"
        while IFS= read -r cidr; do
            echo "allow ${cidr}"
        done < <(split_csv "$CLIENT_CIDRS")
        echo "ntpsigndsocket ${ntp_dir}"
        echo "# END SAMBA-AD"
    } >>"$chrony_conf"

    # A Wiki do Samba documenta ntpd_t para o diretório ntp_signd.
    # Não tornamos falha de SELinux fatal aqui, pois políticas modernas podem variar.
    if command -v semanage >/dev/null 2>&1; then
        semanage fcontext -a -t ntpd_t "${ntp_dir}(/.*)?" 2>/dev/null || \
        semanage fcontext -m -t ntpd_t "${ntp_dir}(/.*)?" 2>/dev/null || true
        restorecon -RF "$ntp_dir" 2>/dev/null || true
    fi

    systemctl restart chronyd
    sleep 1
    chronyc tracking || true
}

# ---------------------------------------------------------------------------
# Firewall
# ---------------------------------------------------------------------------
configure_firewall() {
    info "Configurando firewalld"

    systemctl enable --now firewalld

    cat >/etc/firewalld/services/samba-ad.xml <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<service>
  <short>Samba AD DC</short>
  <description>Samba Active Directory Domain Controller</description>
  <port protocol="tcp" port="53"/>
  <port protocol="udp" port="53"/>
  <port protocol="tcp" port="88"/>
  <port protocol="udp" port="88"/>
  <port protocol="udp" port="123"/>
  <port protocol="tcp" port="135"/>
  <port protocol="udp" port="137"/>
  <port protocol="udp" port="138"/>
  <port protocol="tcp" port="139"/>
  <port protocol="tcp" port="389"/>
  <port protocol="udp" port="389"/>
  <port protocol="tcp" port="445"/>
  <port protocol="tcp" port="464"/>
  <port protocol="udp" port="464"/>
  <port protocol="tcp" port="636"/>
  <port protocol="tcp" port="3268"/>
  <port protocol="tcp" port="3269"/>
  <port protocol="tcp" port="49152-65535"/>
</service>
EOF

    cat >/etc/firewalld/services/samba-admin.xml <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<service>
  <short>Samba AD Admin</short>
  <description>Admin web UIs: HTTP/HTTPS, Cockpit and Grafana</description>
  <port protocol="tcp" port="80"/>
  <port protocol="tcp" port="443"/>
  <port protocol="tcp" port="9090"/>
  <port protocol="tcp" port="3000"/>
</service>
EOF

    firewall-cmd --reload

    FIREWALL_ZONE="$(firewall-cmd --get-zone-of-interface="$DC_IFACE" 2>/dev/null || true)"
    if [[ -z "$FIREWALL_ZONE" || "$FIREWALL_ZONE" == "no zone" ]]; then
        FIREWALL_ZONE="$(firewall-cmd --get-default-zone)"
        warn "A interface $DC_IFACE não tem zona explícita; usando zona default '$FIREWALL_ZONE'."
    fi

    local zone_target
    zone_target="$(firewall-cmd --permanent --zone="$FIREWALL_ZONE" --get-target 2>/dev/null || echo default)"
    if [[ "$FIREWALL_ZONE" == "trusted" || "${zone_target^^}" == "ACCEPT" ]]; then
        if [[ "$ALLOW_PERMISSIVE_FIREWALL_ZONE" != "1" ]]; then
            die "A interface $DC_IFACE está na zona firewalld '$FIREWALL_ZONE' (target=$zone_target). Nessa zona as restrições por CIDR podem ser ineficazes. Mova a interface para uma zona restritiva ou use ALLOW_PERMISSIVE_FIREWALL_ZONE=1 conscientemente."
        fi
        warn "Zona firewalld permissiva '$FIREWALL_ZONE' aceita por autorização explícita."
    fi

    # Evita que serviços administrativos fiquem globalmente expostos por uma
    # regra pré-existente da zona (Cockpit costuma vir permitido em alguns perfis).
    local svc port
    for svc in cockpit http https samba samba-client; do
        firewall-cmd --permanent --zone="$FIREWALL_ZONE" --remove-service="$svc" >/dev/null 2>&1 || true
    done
    for port in 80/tcp 443/tcp 3000/tcp 9090/tcp; do
        firewall-cmd --permanent --zone="$FIREWALL_ZONE" --remove-port="$port" >/dev/null 2>&1 || true
    done

    local cidr rule
    while IFS= read -r cidr; do
        rule="rule family=\"ipv4\" source address=\"${cidr}\" service name=\"samba-ad\" accept"
        firewall-cmd --permanent --zone="$FIREWALL_ZONE" --query-rich-rule="$rule" >/dev/null 2>&1 || \
            firewall-cmd --permanent --zone="$FIREWALL_ZONE" --add-rich-rule="$rule"
    done < <(split_csv "$CLIENT_CIDRS")

    while IFS= read -r cidr; do
        rule="rule family=\"ipv4\" source address=\"${cidr}\" service name=\"samba-admin\" accept"
        firewall-cmd --permanent --zone="$FIREWALL_ZONE" --query-rich-rule="$rule" >/dev/null 2>&1 || \
            firewall-cmd --permanent --zone="$FIREWALL_ZONE" --add-rich-rule="$rule"
    done < <(split_csv "$MGMT_CIDRS")

    firewall-cmd --reload
    ok "Firewall configurado na zona: $FIREWALL_ZONE"
}

# ---------------------------------------------------------------------------
# Cockpit
# ---------------------------------------------------------------------------
install_cockpit() {
    info "Instalando Cockpit"
    install_pkg_required cockpit
    install_pkg_optional cockpit-storaged
    install_pkg_optional cockpit-selinux

    systemctl enable --now cockpit.socket
}

# ---------------------------------------------------------------------------
# LDAP Account Manager Community
# ---------------------------------------------------------------------------
expected_lam_sha256() {
    local version="$1"
    if [[ -n "$LAM_SHA256" && "$version" == "$LAM_REQUESTED_VERSION" ]]; then
        printf '%s\n' "$LAM_SHA256"
        return 0
    fi
    if [[ -n "$LAM_FALLBACK_SHA256" && "$version" == "$LAM_REQUESTED_FALLBACK_VERSION" ]]; then
        printf '%s\n' "$LAM_FALLBACK_SHA256"
        return 0
    fi

    # Hashes fixados para as versões padrão desta revisão. Se LAM_VERSION for
    # alterada manualmente, forneça LAM_SHA256 para manter a verificação forte.
    case "$version" in
        9.6)   printf '%s\n' 'a7a793c8d516ed5f0603e37f6298f701502f56e07ea3ab55e9aa35cabdb8ba82' ;;
        9.5.2) printf '%s\n' 'b5d35377f3f6da12bd128bf1f7e84c527b7fc7fa91bfd98b1539040736a1b713' ;;
        *) return 1 ;;
    esac
}

verify_lam_tarball() {
    local version="$1" target="$2" expected actual
    expected="$(expected_lam_sha256 "$version" || true)"
    [[ -n "$expected" ]] || die "Não há SHA256 fixado para LAM $version. Informe LAM_SHA256 (ou LAM_FALLBACK_SHA256 para o fallback) antes de instalar uma versão personalizada."
    actual="$(sha256sum "$target" | awk '{print $1}')"
    if [[ "${actual,,}" != "${expected,,}" ]]; then
        rm -f "$target"
        die "SHA256 do LAM $version não confere. Esperado=$expected Obtido=$actual. O arquivo foi removido."
    fi
    LAM_EFFECTIVE_SHA256="$actual"
    ok "SHA256 do LAM $version validado: $actual"
}

download_lam() {
    local version="$1"
    local target="$2"
    local url_github="https://github.com/LDAPAccountManager/lam/releases/download/${version}/ldap-account-manager-${version}.tar.bz2"
    local url_sf="https://downloads.sourceforge.net/project/lam/LAM/${version}/ldap-account-manager-${version}.tar.bz2"

    if curl -fL --retry 3 --retry-delay 2 -o "${target}.part" "$url_github"; then
        mv "${target}.part" "$target"
        return 0
    fi

    warn "Download via GitHub falhou; tentando mirror oficial do SourceForge."
    rm -f "${target}.part"
    curl -fL --retry 3 --retry-delay 2 -o "${target}.part" "$url_sf"
    mv "${target}.part" "$target"
}

install_lam() {
    info "Instalando LDAP Account Manager Community"

    local packages=(
        httpd mod_ssl
        php php-cli php-common php-ldap php-xml php-mbstring php-gd php-opcache
        php-gmp php-pecl-zip php-intl
    )
    install_pkg_list_required "${packages[@]}"
    install_pkg_optional php-curl
    install_pkg_optional php-process

    mkdir -p "$WORKDIR/lam"
    local tarball="$WORKDIR/lam/ldap-account-manager-${LAM_VERSION}.tar.bz2"

    if ! download_lam "$LAM_VERSION" "$tarball"; then
        warn "LAM ${LAM_VERSION} não pôde ser baixado. Tentando ${LAM_FALLBACK_VERSION}."
        LAM_VERSION="$LAM_FALLBACK_VERSION"
        tarball="$WORKDIR/lam/ldap-account-manager-${LAM_VERSION}.tar.bz2"
        download_lam "$LAM_VERSION" "$tarball"
    fi
    verify_lam_tarball "$LAM_VERSION" "$tarball"

    rm -rf "$WORKDIR/lam/extracted"
    mkdir -p "$WORKDIR/lam/extracted"
    tar xjf "$tarball" -C "$WORKDIR/lam/extracted"

    local src
    src="$(find "$WORKDIR/lam/extracted" -mindepth 1 -maxdepth 1 -type d -name 'ldap-account-manager-*' | head -n1)"
    [[ -n "$src" ]] || die "Estrutura do tarball do LAM inesperada."

    rm -rf /var/www/html/lam
    mkdir -p /var/www/html/lam
    cp -a "${src}/." /var/www/html/lam/

    if [[ ! -f /var/www/html/lam/config/config.cfg ]]; then
        cp /var/www/html/lam/config/config.cfg.sample /var/www/html/lam/config/config.cfg
    fi

    # Troca a senha mestre padrão "lam" por uma senha aleatória (ou fornecida
    # em LAM_MASTER_PASSWORD). O formato SSHA é o mesmo utilizado pelo LAM.
    local generated_lam_password=0
    if [[ -z "$LAM_MASTER_PASSWORD" ]]; then
        LAM_MASTER_PASSWORD="$(openssl rand -base64 24 | tr -d '\n')"
        generated_lam_password=1
    fi

    local lam_password_ssha
    lam_password_ssha="$(LAM_PASSWORD="$LAM_MASTER_PASSWORD" php -r '
        $password = getenv("LAM_PASSWORD");
        $salt = random_bytes(4);
        echo "{SSHA}" . base64_encode(sha1($password . $salt, true)) . " " . base64_encode($salt);
    ')"

    python3 - /var/www/html/lam/config/config.cfg "$lam_password_ssha" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
new_hash = sys.argv[2]
lines = path.read_text().splitlines()
done = False
out = []
for line in lines:
    if line.lstrip().startswith("password:"):
        out.append("password: " + new_hash)
        done = True
    else:
        out.append(line)
if not done:
    raise SystemExit("Linha 'password:' não encontrada no config.cfg do LAM")
path.write_text("\n".join(out) + "\n")
PY

    if (( generated_lam_password == 1 )); then
        cat >/root/lam-master-password.txt <<EOF
URL: https://${HOSTNAME_SHORT}.${AD_DNS_DOMAIN}/lam/
Senha mestre inicial do LAM: ${LAM_MASTER_PASSWORD}
EOF
        chmod 600 /root/lam-master-password.txt
    fi

    chmod +x /var/www/html/lam/lib/lamdaemon.pl 2>/dev/null || true

    chown -R root:root /var/www/html/lam
    for d in config sess tmp; do
        if [[ -d "/var/www/html/lam/$d" ]]; then
            chown -R apache:apache "/var/www/html/lam/$d"
            chmod 750 "/var/www/html/lam/$d"
        fi
    done
    find /var/www/html/lam/config -type f -exec chmod 640 {} + 2>/dev/null || true

    local admin_cert="/etc/pki/tls/certs/samba-ad-admin.crt"
    local admin_key="/etc/pki/tls/private/samba-ad-admin.key"
    local fqdn="${HOSTNAME_SHORT}.${AD_DNS_DOMAIN}"

    if [[ ! -s "$admin_cert" || ! -s "$admin_key" ]]; then
        info "Gerando certificado TLS self-signed para a interface administrativa LAM"
        openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 825 \
            -subj "/CN=${fqdn}" \
            -addext "subjectAltName=DNS:${fqdn},IP:${DC_IP}" \
            -keyout "$admin_key" \
            -out "$admin_cert"
        chmod 600 "$admin_key"
        chmod 644 "$admin_cert"
        restorecon "$admin_key" "$admin_cert" 2>/dev/null || true
    fi

    # O certificado administrativo é self-signed. Confiamos nele localmente no
    # próprio servidor; clientes remotos ainda precisarão importar o certificado
    # ou substituí-lo futuramente por um certificado de CA confiável.
    cp -f "$admin_cert" /etc/pki/ca-trust/source/anchors/samba-ad-admin-local.crt
    chmod 644 /etc/pki/ca-trust/source/anchors/samba-ad-admin-local.crt
    restorecon /etc/pki/ca-trust/source/anchors/samba-ad-admin-local.crt 2>/dev/null || true
    update-ca-trust extract

    rm -f /etc/httpd/conf.d/lam.conf
    cat >/etc/httpd/conf.d/00-samba-ad-lam.conf <<EOF
ServerName ${fqdn}

<VirtualHost *:80>
    ServerName ${fqdn}
    ServerAlias ${DC_IP}
    Redirect permanent /lam https://${fqdn}/lam
</VirtualHost>

<VirtualHost *:443>
    ServerName ${fqdn}
    ServerAlias ${DC_IP}
    SSLEngine on
    SSLProtocol -all +TLSv1.2 +TLSv1.3
    SSLCertificateFile ${admin_cert}
    SSLCertificateKeyFile ${admin_key}

    Alias /lam /var/www/html/lam

    <Directory /var/www/html/lam>
        Options FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>

    <Directory /var/www/html/lam/config>
        Require all denied
    </Directory>

    <Directory /var/www/html/lam/lib>
        Require all denied
    </Directory>

    <Directory /var/www/html/lam/help>
        Require all denied
    </Directory>

    <Directory /var/www/html/lam/locale>
        Require all denied
    </Directory>

    <Directory /var/www/html/lam/sess>
        Require all denied
    </Directory>

    <Directory /var/www/html/lam/tmp>
        Require all denied
    </Directory>
</VirtualHost>
EOF

    # SELinux permanece ENFORCING.
    setsebool -P httpd_can_network_connect 1

    if command -v semanage >/dev/null 2>&1; then
        semanage fcontext -a -t httpd_sys_content_t '/var/www/html/lam(/.*)?' 2>/dev/null || \
        semanage fcontext -m -t httpd_sys_content_t '/var/www/html/lam(/.*)?' 2>/dev/null || true

        for d in config sess tmp; do
            semanage fcontext -a -t httpd_sys_rw_content_t "/var/www/html/lam/${d}(/.*)?" 2>/dev/null || \
            semanage fcontext -m -t httpd_sys_rw_content_t "/var/www/html/lam/${d}(/.*)?" 2>/dev/null || true
        done
        restorecon -RF /var/www/html/lam
    fi

    cat >/etc/php.d/99-lam-security.ini <<'EOF'
; Ajustes conservadores para a interface administrativa LAM
memory_limit = 256M
session.cookie_httponly = 1
session.cookie_secure = 1
session.use_strict_mode = 1
session.cookie_samesite = Lax
expose_php = Off
EOF

    httpd -t
    systemctl enable --now httpd
    systemctl restart httpd

    info "Validando extensões PHP necessárias ao LAM"
    local ext
    for ext in ldap xml mbstring gd gmp zip openssl; do
        php -r "exit(extension_loaded('${ext}') ? 0 : 1);" || die "Extensão PHP obrigatória ausente: ${ext}"
    done
    ok "Extensões PHP do LAM validadas: LDAP/XML/MBString/GD/GMP/ZIP/OpenSSL."

    ok "LAM instalado em /lam."
}

# ---------------------------------------------------------------------------
# Logs
# ---------------------------------------------------------------------------
configure_logging() {
    info "Ativando rsyslog e journal persistente"
    systemctl enable --now rsyslog

    mkdir -p /etc/systemd/journald.conf.d
    cat >/etc/systemd/journald.conf.d/10-persistent.conf <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=1G
Compress=yes
EOF

    systemctl restart systemd-journald

    local samba_logbase
    samba_logbase="$("${SAMBA_PREFIX}/sbin/smbd" -b 2>/dev/null | awk -F': ' '/LOGFILEBASE:/ {print $2; exit}' || true)"
    if [[ -n "$samba_logbase" ]]; then
        cat >/etc/logrotate.d/samba-ad-custom <<EOF
${samba_logbase}/log.* ${samba_logbase}/*.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
        ok "Logrotate configurado para ${samba_logbase}."
    fi
}

# ---------------------------------------------------------------------------
# Monitoramento
# ---------------------------------------------------------------------------
install_monitoring() {
    info "Instalando Prometheus e node_exporter"
    install_pkg_required prometheus
    install_pkg_required node-exporter

    mkdir -p /etc/prometheus /var/lib/prometheus
    chown -R prometheus:prometheus /var/lib/prometheus

    cat >/etc/prometheus/prometheus.yml <<'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: "rocky-samba-ad"
    static_configs:
      - targets: ["127.0.0.1:9100"]
EOF

    # Cockpit usa TCP/9090. Mantemos o Prometheus somente no loopback:9091.
    systemctl disable --now prometheus.service 2>/dev/null || true

    cat >/etc/systemd/system/prometheus-local.service <<'EOF'
[Unit]
Description=Prometheus local for Samba AD host
After=network-online.target node_exporter.service
Wants=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple
ExecStart=/usr/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus \
  --storage.tsdb.retention.time=15d \
  --web.listen-address=127.0.0.1:9091
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    # O exporter só é consumido pelo Prometheus local, então não há motivo para
    # deixá-lo escutando em todas as interfaces mesmo com o firewall fechado.
    local node_exporter_bin
    node_exporter_bin="$(command -v node_exporter || true)"
    [[ -x "$node_exporter_bin" ]] || die "Binário node_exporter não encontrado após instalar o pacote."
    mkdir -p /etc/systemd/system/node_exporter.service.d
    cat >/etc/systemd/system/node_exporter.service.d/20-local-only.conf <<EOF
[Service]
ExecStart=
ExecStart=${node_exporter_bin} --web.listen-address=127.0.0.1:9100
EOF

    systemctl daemon-reload
    systemctl enable --now node_exporter.service
    systemctl restart node_exporter.service
    systemctl enable --now prometheus-local.service

    info "Instalando Grafana OSS"
    curl -fsSL https://rpm.grafana.com/gpg.key -o "$WORKDIR/grafana-gpg.key.part"
    mv -f "$WORKDIR/grafana-gpg.key.part" "$WORKDIR/grafana-gpg.key"
    rpm --import "$WORKDIR/grafana-gpg.key"

    cat >/etc/yum.repos.d/grafana.repo <<'EOF'
[grafana]
name=Grafana OSS
baseurl=https://rpm.grafana.com
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://rpm.grafana.com/gpg.key
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
EOF
    dnf -y install grafana

    mkdir -p /etc/grafana/provisioning/datasources
    cat >/etc/grafana/provisioning/datasources/prometheus.yml <<'EOF'
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://127.0.0.1:9091
    isDefault: true
    editable: true
EOF

    local fqdn="${HOSTNAME_SHORT}.${AD_DNS_DOMAIN}"
    local admin_cert="/etc/pki/tls/certs/samba-ad-admin.crt"
    local admin_key="/etc/pki/tls/private/samba-ad-admin.key"
    local grafana_cert="/etc/grafana/samba-ad-admin.crt"
    local grafana_key="/etc/grafana/samba-ad-admin.key"
    [[ -s "$admin_cert" && -s "$admin_key" ]] || die "Certificado administrativo TLS não encontrado para configurar Grafana HTTPS."

    cp -f "$admin_cert" "$grafana_cert"
    cp -f "$admin_key" "$grafana_key"
    chown root:grafana "$grafana_cert" "$grafana_key"
    chmod 640 "$grafana_cert" "$grafana_key"
    restorecon "$grafana_cert" "$grafana_key" 2>/dev/null || true

    local generated_grafana_password=0
    if [[ -z "$GRAFANA_ADMIN_PASSWORD" ]]; then
        GRAFANA_ADMIN_PASSWORD="$(openssl rand -base64 24 | tr -d '\n')"
        generated_grafana_password=1
    fi

    mkdir -p /etc/systemd/system/grafana-server.service.d
    printf 'GF_SECURITY_ADMIN_PASSWORD=%s\n' "$GRAFANA_ADMIN_PASSWORD" >/etc/grafana/initial-admin.env
    chmod 600 /etc/grafana/initial-admin.env
    cat >/etc/systemd/system/grafana-server.service.d/10-initial-admin.conf <<'EOF'
[Service]
EnvironmentFile=-/etc/grafana/initial-admin.env
EOF

    cat >/etc/systemd/system/grafana-server.service.d/20-tls.conf <<EOF
[Service]
Environment=GF_SERVER_PROTOCOL=https
Environment=GF_SERVER_DOMAIN=${fqdn}
Environment=GF_SERVER_ROOT_URL=https://${fqdn}:3000/
Environment=GF_SERVER_CERT_FILE=${grafana_cert}
Environment=GF_SERVER_CERT_KEY=${grafana_key}
EOF

    systemctl daemon-reload
    systemctl enable grafana-server.service
    systemctl restart grafana-server.service

    local i
    for i in {1..30}; do
        if curl -fsS --cacert "$grafana_cert" --resolve "${fqdn}:3000:127.0.0.1" \
            "https://${fqdn}:3000/api/health" >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done
    curl -fsS --cacert "$grafana_cert" --resolve "${fqdn}:3000:127.0.0.1" \
        "https://${fqdn}:3000/api/health" >/dev/null || die "Grafana HTTPS não respondeu ao health check."

    # Torna a etapa idempotente: mesmo que uma execução anterior tenha criado o
    # banco do Grafana antes de falhar, a senha conhecida abaixo é aplicada de
    # forma explícita. --password-from-stdin evita expor o segredo no ps.
    printf '%s\n' "$GRAFANA_ADMIN_PASSWORD" | \
        /usr/bin/grafana cli --homepath /usr/share/grafana --config /etc/grafana/grafana.ini \
        admin reset-admin-password --password-from-stdin >/dev/null

    if (( generated_grafana_password == 1 )); then
        cat >/root/grafana-initial-admin.txt <<EOF
URL: https://${fqdn}:3000/
Usuario: admin
Senha inicial: ${GRAFANA_ADMIN_PASSWORD}
EOF
        chmod 600 /root/grafana-initial-admin.txt
    fi

    # A senha já foi persistida pelo Grafana. Removemos apenas o override
    # temporário; o override TLS permanece de forma permanente.
    rm -f /etc/grafana/initial-admin.env \
          /etc/systemd/system/grafana-server.service.d/10-initial-admin.conf
    systemctl daemon-reload

    ok "Grafana ativo em HTTPS; senha inicial não usa admin/admin."
}

# ---------------------------------------------------------------------------
# Backup
# ---------------------------------------------------------------------------
install_backup_tools() {
    info "Instalando BorgBackup e Restic"
    install_pkg_required borgbackup
    install_pkg_required restic

    mkdir -p /var/backups/samba-ad
    chmod 700 /var/backups/samba-ad

    cat >/usr/local/sbin/samba-ad-backup-local <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export PATH="${SAMBA_PREFIX}/bin:${SAMBA_PREFIX}/sbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin"

BACKUP_DIR="/var/backups/samba-ad"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS}"

mkdir -p "\$BACKUP_DIR"

# dbcheck não usa --fix automaticamente. Se houver inconsistência, registra aviso,
# mas ainda gera o backup para preservar o estado para análise/recuperação.
if ! samba-tool dbcheck --cross-ncs >/var/log/samba-dbcheck-last.log 2>&1; then
    logger -p auth.warning -t samba-ad-backup "samba-tool dbcheck encontrou problemas. Consulte /var/log/samba-dbcheck-last.log"
fi

# Apesar do nome "offline", o Samba usa locking apropriado e este comando pode
# ser executado com o DC ativo.
samba-tool domain backup offline --targetdir="\$BACKUP_DIR"

# Snapshot pequeno da configuração do host. Não substitui o backup nativo do AD,
# mas facilita reconstruir o sistema operacional em caso de desastre.
TS="\$(date +%Y%m%d-%H%M%S)"
CONFIG_LIST="\$(mktemp)"
for f in \
    /etc/hosts \
    /etc/krb5.conf \
    /etc/chrony.conf \
    /etc/NetworkManager/system-connections \
    /etc/ld.so.conf.d/samba-ad.conf \
    /etc/profile.d/samba-ad.sh \
    /etc/systemd/system/samba-ad-dc.service \
    /etc/firewalld/services/samba-ad.xml \
    /etc/firewalld/services/samba-admin.xml \
    /etc/firewalld/zones \
    /etc/httpd/conf.d/00-samba-ad-lam.conf \
    /var/www/html/lam/config \
    /etc/php.d/99-lam-security.ini \
    /etc/pki/tls/certs/samba-ad-admin.crt \
    /etc/pki/tls/private/samba-ad-admin.key \
    /etc/pki/ca-trust/source/anchors/samba-ad-local-ca.pem \
    /etc/pki/ca-trust/source/anchors/samba-ad-admin-local.crt \
    /etc/prometheus/prometheus.yml \
    /etc/grafana/provisioning/datasources/prometheus.yml \
    /etc/grafana/samba-ad-admin.crt \
    /etc/grafana/samba-ad-admin.key \
    /etc/systemd/system/grafana-server.service.d/20-tls.conf \
    /etc/systemd/system/node_exporter.service.d/20-local-only.conf \
    /etc/systemd/system/prometheus-local.service \
    /etc/systemd/system/samba-ad-backup.service \
    /etc/systemd/system/samba-ad-backup.timer \
    /etc/systemd/system/samba-ad-health.service \
    /etc/systemd/system/samba-ad-health.timer \
    /usr/local/sbin/samba-ad-backup-local \
    /usr/local/sbin/samba-ad-health \
    /etc/samba-ad/installation.env \
    /etc/samba-ad/build-info.txt; do
    [[ -e "\$f" ]] && printf '%s\\n' "\${f#/}" >>"\$CONFIG_LIST"
done
if [[ -s "\$CONFIG_LIST" ]]; then
    tar -C / -czf "\$BACKUP_DIR/host-config-\${TS}.tar.gz" -T "\$CONFIG_LIST"
fi
rm -f "\$CONFIG_LIST"

find "\$BACKUP_DIR" -maxdepth 1 -type f -mtime "+\$RETENTION_DAYS" -delete
find "\$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name 'INCOMPLETE*' -mtime +2 -exec rm -rf -- {} +
EOF
    chmod 700 /usr/local/sbin/samba-ad-backup-local

    cat >/etc/systemd/system/samba-ad-backup.service <<'EOF'
[Unit]
Description=Local consistent backup of Samba AD DC
After=samba-ad-dc.service
Requires=samba-ad-dc.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/samba-ad-backup-local
EOF

    cat >/etc/systemd/system/samba-ad-backup.timer <<'EOF'
[Unit]
Description=Daily Samba AD backup

[Timer]
OnCalendar=*-*-* 02:30:00
Persistent=true
RandomizedDelaySec=10m

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now samba-ad-backup.timer

    # Faz um primeiro backup agora para validar o mecanismo.
    systemctl start samba-ad-backup.service

    local backup_count
    backup_count="$(find /var/backups/samba-ad -maxdepth 1 -type f -size +0c | wc -l)"
    (( backup_count > 0 )) || die "O primeiro backup não produziu arquivos válidos."
    ok "Primeiro backup do AD/configuração validado."
}

# ---------------------------------------------------------------------------
# Resolver/Firewalld helper e testes
# ---------------------------------------------------------------------------
install_command_links() {
    local cmd
    for cmd in samba-tool smbclient wbinfo ldbsearch ldbmodify testparm; do
        if [[ -x "${SAMBA_PREFIX}/bin/${cmd}" ]]; then
            ln -sfn "${SAMBA_PREFIX}/bin/${cmd}" "/usr/local/bin/${cmd}"
        fi
    done
}

write_install_manifest() {
    info "Gravando manifesto de instalação"
    mkdir -p /etc/samba-ad
    chmod 755 /etc/samba-ad

    {
        printf 'INSTALLER_REVISION=%q\n' "$INSTALLER_REVISION"
        printf 'SAMBA_VERSION=%q\n' "$SAMBA_VERSION"
        printf 'SAMBA_PREFIX=%q\n' "$SAMBA_PREFIX"
        printf 'SAMBA_SOURCE_SHA256=%q\n' "$SAMBA_SOURCE_SHA256"
        printf 'SAMBA_GPG_FINGERPRINT=%q\n' "$SAMBA_GPG_FINGERPRINT"
        printf 'HOSTNAME_SHORT=%q\n' "$HOSTNAME_SHORT"
        printf 'FQDN=%q\n' "${HOSTNAME_SHORT}.${AD_DNS_DOMAIN}"
        printf 'AD_DNS_DOMAIN=%q\n' "$AD_DNS_DOMAIN"
        printf 'NETBIOS_DOMAIN=%q\n' "$NETBIOS_DOMAIN"
        printf 'DC_IP=%q\n' "$DC_IP"
        printf 'DC_IFACE=%q\n' "$DC_IFACE"
        printf 'DNS_FORWARDER=%q\n' "$DNS_FORWARDER"
        printf 'CLIENT_CIDRS=%q\n' "$CLIENT_CIDRS"
        printf 'MGMT_CIDRS=%q\n' "$MGMT_CIDRS"
        printf 'FIREWALL_ZONE=%q\n' "$FIREWALL_ZONE"
        printf 'BUILD_USER=%q\n' "$BUILD_USER"
        printf 'LAM_VERSION=%q\n' "$LAM_VERSION"
        printf 'LAM_SHA256=%q\n' "$LAM_EFFECTIVE_SHA256"
        printf 'GRAFANA_URL=%q\n' "https://${HOSTNAME_SHORT}.${AD_DNS_DOMAIN}:3000/"
        printf 'INSTALLER_SELF_SHA256=%q\n' "$INSTALLER_SELF_SHA256"
        printf 'SAMBA_CONFIGURE_ARGS=%q\n' "--prefix=${SAMBA_PREFIX} --disable-cups"
    } >/etc/samba-ad/installation.env
    chmod 644 /etc/samba-ad/installation.env

    {
        echo "Samba build information"
        echo "Generated: $(date -Is)"
        echo "Installer: ${INSTALLER_REVISION}"
        echo "Source SHA256: ${SAMBA_SOURCE_SHA256}"
        echo "GPG fingerprint: ${SAMBA_GPG_FINGERPRINT}"
        echo "LAM SHA256: ${LAM_EFFECTIVE_SHA256}"
        echo "Installer SHA256: ${INSTALLER_SELF_SHA256}"
        echo
        "${SAMBA_PREFIX}/bin/samba-tool" --version
        echo
        "${SAMBA_PREFIX}/sbin/smbd" -b
    } >/etc/samba-ad/build-info.txt
    chmod 644 /etc/samba-ad/build-info.txt
}

install_healthcheck() {
    info "Instalando health-check do Samba AD"

    local private_dir
    private_dir="$("${SAMBA_PREFIX}/sbin/smbd" -b | awk -F': ' '/PRIVATE_DIR:/ {print $2; exit}')"

    cat >/usr/local/sbin/samba-ad-health <<EOF
#!/usr/bin/env bash
set -u
export PATH="${SAMBA_PREFIX}/bin:${SAMBA_PREFIX}/sbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin"

DOMAIN="${AD_DNS_DOMAIN}"
DC_IP="${DC_IP}"
BACKUP_DIR="/var/backups/samba-ad"
SAMBA_TLS_CERT="${private_dir}/tls/cert.pem"
ADMIN_TLS_CERT="/etc/pki/tls/certs/samba-ad-admin.crt"
FQDN="${HOSTNAME_SHORT}.${AD_DNS_DOMAIN}"
GRAFANA_TLS_CERT="/etc/grafana/samba-ad-admin.crt"
FAIL=0

pass() { printf '[OK] %s\\n' "\$*"; }
fail() { printf '[FAIL] %s\\n' "\$*" >&2; FAIL=1; }

systemctl is-active --quiet samba-ad-dc.service && pass "samba-ad-dc ativo" || fail "samba-ad-dc inativo"

if samba-tool dbcheck --cross-ncs 2>&1 | tail -n1 | grep -q '(0 errors)'; then
    pass "dbcheck sem erros"
else
    fail "dbcheck encontrou erro ou não pôde ser executado"
fi

samba-tool ntacl sysvolcheck >/dev/null 2>&1 && pass "SYSVOL ACL correto" || fail "SYSVOL ACL com problema"

host -t SRV "_ldap._tcp.\${DOMAIN}" "\$DC_IP" >/dev/null 2>&1 && pass "DNS LDAP SRV" || fail "DNS LDAP SRV"
host -t SRV "_kerberos._udp.\${DOMAIN}" "\$DC_IP" >/dev/null 2>&1 && pass "DNS Kerberos SRV" || fail "DNS Kerberos SRV"
host -t SRV "_gc._tcp.\${DOMAIN}" "\$DC_IP" >/dev/null 2>&1 && pass "DNS Global Catalog SRV" || fail "DNS Global Catalog SRV"

chronyc tracking 2>/dev/null | grep -q '^Leap status.*Normal' && pass "Chrony sincronizado" || fail "Chrony não indica Leap status Normal"

if [[ -s "\$SAMBA_TLS_CERT" ]]; then
    openssl x509 -checkend 2592000 -noout -in "\$SAMBA_TLS_CERT" >/dev/null 2>&1 && pass "certificado Samba LDAPS >30 dias" || fail "certificado Samba LDAPS ausente/expira em <30 dias"
    openssl verify -CAfile /etc/pki/ca-trust/source/anchors/samba-ad-local-ca.pem "\$SAMBA_TLS_CERT" >/dev/null 2>&1 && pass "cadeia de confiança Samba LDAPS" || fail "cadeia de confiança Samba LDAPS"
else
    fail "certificado Samba LDAPS não encontrado"
fi

if [[ -s "\$ADMIN_TLS_CERT" ]]; then
    openssl x509 -checkend 2592000 -noout -in "\$ADMIN_TLS_CERT" >/dev/null 2>&1 && pass "certificado LAM HTTPS >30 dias" || fail "certificado LAM HTTPS ausente/expira em <30 dias"
else
    fail "certificado LAM HTTPS não encontrado"
fi

if curl -fsS --cacert "\$ADMIN_TLS_CERT" --resolve "\${FQDN}:443:127.0.0.1" "https://\${FQDN}/lam/" >/dev/null 2>&1; then
    pass "LAM HTTPS responde localmente"
else
    fail "LAM HTTPS não respondeu localmente"
fi

if [[ -s "\$GRAFANA_TLS_CERT" ]] && curl -fsS --cacert "\$GRAFANA_TLS_CERT" --resolve "\${FQDN}:3000:127.0.0.1" "https://\${FQDN}:3000/api/health" >/dev/null 2>&1; then
    pass "Grafana HTTPS responde localmente"
else
    fail "Grafana HTTPS não respondeu localmente"
fi

latest="\$(find "\$BACKUP_DIR" -maxdepth 1 -type f ! -name 'host-config-*' -printf '%T@ %p\\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-)"
if [[ -n "\$latest" ]]; then
    age="\$(( \$(date +%s) - \$(stat -c %Y "\$latest") ))"
    if (( age <= 172800 )); then
        pass "backup do AD com menos de 48h"
    else
        fail "backup do AD tem mais de 48h"
    fi
else
    fail "nenhum backup do AD encontrado"
fi

exit "\$FAIL"
EOF
    chmod 750 /usr/local/sbin/samba-ad-health

    cat >/etc/systemd/system/samba-ad-health.service <<'EOF'
[Unit]
Description=Samba AD health check
After=samba-ad-dc.service chronyd.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/samba-ad-health
EOF

    cat >/etc/systemd/system/samba-ad-health.timer <<'EOF'
[Unit]
Description=Periodic Samba AD health check

[Timer]
OnBootSec=10min
OnCalendar=*-*-* 06:15:00
Persistent=true
RandomizedDelaySec=5m

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now samba-ad-health.timer
}

run_tests() {
    export PATH="${SAMBA_PREFIX}/bin:${SAMBA_PREFIX}/sbin:${PATH}"

    info "Executando testes finais"

    systemctl is-active --quiet samba-ad-dc.service
    [[ "$(hostname -f)" == "${HOSTNAME_SHORT}.${AD_DNS_DOMAIN}" ]]

    samba-tool dbcheck --cross-ncs
    samba-tool ntacl sysvolcheck
    samba-tool fsmo show
    samba-tool domain level show
    samba-tool user list | sed -n '1,20p'

    host -t SRV "_ldap._tcp.${AD_DNS_DOMAIN}" "$DC_IP"
    host -t SRV "_kerberos._udp.${AD_DNS_DOMAIN}" "$DC_IP"
    host -t SRV "_gc._tcp.${AD_DNS_DOMAIN}" "$DC_IP"
    host -t A "${HOSTNAME_SHORT}.${AD_DNS_DOMAIN}" "$DC_IP"

    # Confirma handshake LDAPS e confiança na CA Samba instalada no sistema.
    if timeout 8 bash -c "printf '\n' | openssl s_client -connect '${HOSTNAME_SHORT}.${AD_DNS_DOMAIN}:636' -servername '${HOSTNAME_SHORT}.${AD_DNS_DOMAIN}' -CAfile /etc/pki/tls/certs/ca-bundle.crt -verify_return_error -verify_hostname '${HOSTNAME_SHORT}.${AD_DNS_DOMAIN}' >/dev/null 2>&1"; then
        ok "LDAPS/TLS do Samba validado com CA local."
    else
        warn "Handshake/validação LDAPS falhou; revise os certificados em private/tls."
    fi

    # Forwarding externo é útil, mas não deve invalidar um AD isolado/laboratório.
    if host -t A "$DNS_TEST_NAME" "$DC_IP" >/dev/null 2>&1; then
        ok "DNS forwarder respondeu para ${DNS_TEST_NAME}."
    else
        warn "Não foi possível resolver ${DNS_TEST_NAME} via Samba DNS. Verifique o forwarder se acesso externo for necessário."
    fi

    # Teste Kerberos sem expor a senha no log.
    if printf '%s\n' "$ADMIN_PASS" | kinit "Administrator@${AD_DNS_DOMAIN^^}" >/dev/null 2>&1; then
        klist
        kdestroy || true
        ok "Kerberos funcionando."
    else
        warn "O teste kinit falhou. Verifique /etc/krb5.conf, DNS e sincronismo de horário."
    fi

    # Confirma presença das portas essenciais. A expressão apenas verifica que
    # os listeners existem; o firewalld continua restringindo por CIDR.
    local p listeners
    listeners="$(ss -H -lntup)"
    for p in 53 88 389 445 3268; do
        grep -E ":${p}([[:space:]]|$)" <<<"$listeners" >/dev/null || die "Porta essencial ${p} não aparece em escuta."
    done

    curl -fsS http://127.0.0.1:9091/-/ready >/dev/null && ok "Prometheus pronto em 127.0.0.1:9091."
    curl -fsS http://127.0.0.1:9100/metrics >/dev/null && ok "node_exporter ativo somente no loopback."
    if ss -H -lnt | awk '$4 ~ /:9100$/ && $4 !~ /^127\.0\.0\.1:9100$/ {bad=1} END {exit bad ? 0 : 1}'; then
        die "node_exporter também está escutando fora de 127.0.0.1:9100."
    fi

    local fqdn admin_cert grafana_cert
    fqdn="${HOSTNAME_SHORT}.${AD_DNS_DOMAIN}"
    admin_cert="/etc/pki/tls/certs/samba-ad-admin.crt"
    grafana_cert="/etc/grafana/samba-ad-admin.crt"
    curl -fsS --cacert "$admin_cert" --resolve "${fqdn}:443:127.0.0.1" "https://${fqdn}/lam/" >/dev/null && ok "LAM HTTPS ativo."
    curl -fsS --cacert "$grafana_cert" --resolve "${fqdn}:3000:127.0.0.1" "https://${fqdn}:3000/api/health" >/dev/null && ok "Grafana HTTPS ativo."
    systemctl is-active --quiet cockpit.socket && ok "Cockpit ativo."
    systemctl is-active --quiet httpd && ok "Apache/LAM ativo."

    local ext
    for ext in ldap gmp zip openssl; do
        php -r "exit(extension_loaded('${ext}') ? 0 : 1);" || die "LAM: extensão PHP ausente no teste final: ${ext}"
    done

    /usr/local/sbin/samba-ad-health || warn "Health-check final reportou alerta; examine a saída acima."
}

print_summary() {
    local fqdn="${HOSTNAME_SHORT}.${AD_DNS_DOMAIN}"

    cat <<EOF

===============================================================================
 INSTALAÇÃO CONCLUÍDA
===============================================================================

Samba:
  Versão           : ${SAMBA_VERSION}
  Prefixo          : ${SAMBA_PREFIX}
  DC               : ${fqdn}
  IP               : ${DC_IP}
  Domínio DNS      : ${AD_DNS_DOMAIN}
  Realm Kerberos   : ${AD_DNS_DOMAIN^^}
  Domínio NetBIOS  : ${NETBIOS_DOMAIN}
  DNS backend      : SAMBA_INTERNAL
  DNS forwarder    : ${DNS_FORWARDER}

Interfaces:
  Cockpit          : https://${DC_IP}:9090/
  LDAP Account Mgr : https://${fqdn}/lam/
  Grafana          : https://${fqdn}:3000/
  Zona firewalld   : ${FIREWALL_ZONE}

Monitoramento:
  Prometheus       : 127.0.0.1:9091 (não exposto externamente)
  node_exporter    : 127.0.0.1:9100 (bind somente local)

Backup:
  Diretório        : /var/backups/samba-ad
  Agendamento      : diariamente às 02:30
  Retenção local   : ${BACKUP_RETENTION_DAYS} dias
  BorgBackup       : instalado, repositório ainda não configurado
  Restic           : instalado, repositório ainda não configurado

Logs:
  Samba/systemd    : journalctl -u samba-ad-dc
  Installer        : ${LOG_FILE}
  DB check         : /var/log/samba-dbcheck-last.log
  Manifesto        : /etc/samba-ad/installation.env
  Build info       : /etc/samba-ad/build-info.txt
  Health check     : /usr/local/sbin/samba-ad-health

COMANDOS ÚTEIS:
  samba-tool user list
  samba-tool group list
  samba-tool fsmo show
  samba-tool dbcheck --cross-ncs
  samba-tool domain level show
  samba-tool domain passwordsettings show
  systemctl status samba-ad-dc
  journalctl -u samba-ad-dc -f
  systemctl list-timers samba-ad-backup.timer
  /usr/local/sbin/samba-ad-health
  systemctl list-timers samba-ad-health.timer

LAM:
  O instalador substitui a senha mestre padrão "lam".
  HTTPS usa certificado self-signed com SAN para ${fqdn} e ${DC_IP};
  até importar/confiar nesse certificado, o navegador exibirá aviso de confiança.
  Certificado para importar nos clientes: /etc/pki/tls/certs/samba-ad-admin.crt
  Se a senha foi gerada automaticamente, consulte como root:
      cat /root/lam-master-password.txt

  Depois crie/edite o perfil:
      Server type / módulo: Windows (Samba 4 / Active Directory)
      LDAP server: ldaps://${fqdn}
      Domínio: ${AD_DNS_DOMAIN}
  A CA TLS gerada pelo Samba é instalada no trust store local para o LAM.

  Após guardar a senha em local seguro, remova /root/lam-master-password.txt.

GRAFANA:
  O instalador NÃO usa admin/admin e força HTTPS em :3000.
  Usa o mesmo certificado administrativo self-signed do LAM; o navegador
  exibirá aviso até que esse certificado seja confiado no cliente.
  Se a senha foi gerada automaticamente, consulte como root:
      cat /root/grafana-initial-admin.txt
  Troque a senha após o primeiro login e remova esse arquivo quando não precisar mais dele.

WINDOWS / RSAT:
  Configure o DNS da estação Windows para ${DC_IP},
  ingresse-a no domínio ${AD_DNS_DOMAIN} e use RSAT para ADUC/GPMC/DNS.

SELinux:
  O script NÃO desativa SELinux. Modo atual: $(getenforce 2>/dev/null || echo desconhecido)

LAM/PHP:
  Extensões LDAP, GMP, ZIP e OpenSSL são validadas automaticamente.

===============================================================================
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    require_root
    acquire_installer_lock
    check_rocky10
    detect_network
    load_resume_state

    prompt_value HOSTNAME_SHORT "Hostname curto do DC" "dc1"
    prompt_value AD_DNS_DOMAIN "Domínio DNS do AD (ex.: ad.empresa.com.br)"

    if [[ -z "$NETBIOS_DOMAIN" ]]; then
        NETBIOS_DOMAIN="${AD_DNS_DOMAIN%%.*}"
        NETBIOS_DOMAIN="${NETBIOS_DOMAIN^^}"
    fi
    prompt_value NETBIOS_DOMAIN "Domínio NetBIOS" "$NETBIOS_DOMAIN"
    prompt_value DC_IP "IPv4 do DC" "$DETECTED_IP"

    local current_dns
    current_dns="$(get_current_dns)"
    prompt_value DNS_FORWARDER "DNS forwarder/upstream" "${current_dns:-1.1.1.1}"

    prompt_value CLIENT_CIDRS "CIDRs que acessarão o AD (vírgula)" "$DETECTED_SUBNET"
    prompt_value MGMT_CIDRS "CIDRs de administração Web (vírgula)" "$DETECTED_SUBNET"

    # Canonicaliza nomes para evitar diferenças cosméticas/operacionais e redes
    # para que regras equivalentes não sejam duplicadas no firewalld/Chrony.
    HOSTNAME_SHORT="${HOSTNAME_SHORT,,}"
    AD_DNS_DOMAIN="${AD_DNS_DOMAIN,,}"
    NETBIOS_DOMAIN="${NETBIOS_DOMAIN^^}"

    validate_hostname_short "$HOSTNAME_SHORT"
    validate_domain "$AD_DNS_DOMAIN"
    validate_netbios "$NETBIOS_DOMAIN"
    validate_ipv4 "$DC_IP" || die "DC_IP inválido: $DC_IP"
    validate_ipv4 "$DNS_FORWARDER" || die "DNS_FORWARDER inválido: $DNS_FORWARDER"
    validate_cidr_list "$CLIENT_CIDRS" || die "CLIENT_CIDRS contém rede inválida."
    validate_cidr_list "$MGMT_CIDRS" || die "MGMT_CIDRS contém rede inválida."
    CLIENT_CIDRS="$(normalize_cidr_list "$CLIENT_CIDRS")"
    MGMT_CIDRS="$(normalize_cidr_list "$MGMT_CIDRS")"
    guard_wide_cidrs

    if ! ip -o -4 addr show dev "$DC_IFACE" | grep -qE "[[:space:]]${DC_IP//./\\.}/"; then
        die "O IP $DC_IP não está configurado na interface $DC_IFACE."
    fi

    check_static_ip_hint
    check_multiple_ipv4
    check_selinux_mode
    ensure_fresh_dc

    if (( RESUME_MODE == 1 )) && systemctl is-active --quiet samba-ad-dc.service 2>/dev/null; then
        ok "Samba já está ativo; teste de conflito de portas ignorado no modo RESUME."
    else
        port_conflict_check
    fi

    printf '\nSenha do Administrator do domínio (não será exibida): '
    read -r -s ADMIN_PASS
    printf '\nConfirme a senha: '
    read -r -s ADMIN_PASS_2
    printf '\n'
    [[ -n "$ADMIN_PASS" ]] || die "Senha vazia."
    [[ "$ADMIN_PASS" == "$ADMIN_PASS_2" ]] || die "As senhas não conferem."
    validate_admin_password "$ADMIN_PASS"
    unset ADMIN_PASS_2

    info "Resumo antes da instalação"
    printf '  Modo           : %s\n' "$([[ $RESUME_MODE -eq 1 ]] && echo RESUME || echo NOVA_INSTALACAO)"
    printf '  Hostname       : %s.%s\n' "$HOSTNAME_SHORT" "$AD_DNS_DOMAIN"
    printf '  IP/interface   : %s / %s\n' "$DC_IP" "$DC_IFACE"
    printf '  NetBIOS        : %s\n' "$NETBIOS_DOMAIN"
    printf '  DNS forwarder  : %s\n' "$DNS_FORWARDER"
    printf '  Clientes AD    : %s\n' "$CLIENT_CIDRS"
    printf '  Administração  : %s\n' "$MGMT_CIDRS"
    printf '  Samba          : %s\n' "$SAMBA_VERSION"
    printf '  SELinux        : %s\n' "$(getenforce 2>/dev/null || echo desconhecido)"

    if [[ -t 0 ]]; then
        read -r -p "Prosseguir? [s/N]: " answer
        [[ "${answer,,}" == "s" || "${answer,,}" == "sim" ]] || die "Cancelado."
    fi

    if [[ -f "$0" ]]; then
        INSTALLER_SELF_SHA256="$(sha256sum "$0" 2>/dev/null | awk '{print $1}' || true)"
    fi

    save_state_config

    run_step repositories enable_repositories
    run_step dependencies install_build_dependencies
    run_step resources check_system_resources
    run_step build_user prepare_build_user
    run_step preflight_dns preflight_dns_collision_check
    run_step hostname configure_hostname
    # O firewall entra antes de o DC começar a escutar, evitando uma janela
    # temporária de exposição durante a instalação.
    run_step firewall configure_firewall
    run_step samba_build build_samba
    run_step samba_provision provision_domain
    run_step samba_systemd install_samba_systemd
    run_step resolver configure_resolver_to_self
    run_step samba_tls_trust configure_samba_tls_trust
    run_step chrony configure_chrony
    run_step cockpit install_cockpit
    run_step lam install_lam
    run_step logging configure_logging
    run_step monitoring install_monitoring
    run_step manifest write_install_manifest
    run_step command_links install_command_links
    run_step healthcheck install_healthcheck
    run_step backup install_backup_tools

    run_tests
    mark_step complete
    print_summary

    unset ADMIN_PASS
}

main "$@"
