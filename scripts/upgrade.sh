#!/usr/bin/env bash
#
# upgrade.sh
#
# Atualizador seguro para Samba AD DC compilado do fonte.
# Compatível com:
#   - installer 0.6 multi-distribuição (Rocky Linux / Ubuntu)
#   - installer 0.5 em Rocky Linux
#   - instalações anteriores do mesmo projeto sem manifesto (modo legado)
#
# Objetivos:
#   * preservar os parâmetros de compilação usados pelo instalador;
#   * validar a chave/assinatura GPG do Samba com fingerprint esperado;
#   * compilar sem privilégios enquanto o DC permanece online;
#   * criar backup consistente do AD;
#   * criar snapshot completo e consistente de /opt/samba com o DC parado;
#   * rollback automático se a instalação/start falhar durante a manutenção;
#   * validar AD/DNS após o upgrade;
#   * atualizar manifesto, build-info e histórico de upgrades.
#
# Uso:
#   ./upgrade.sh 4.24.6
#   ./upgrade.sh 4.24.6 --yes
#   ./upgrade.sh 4.25.1 --allow-feature-upgrade
#
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

UPGRADER_REVISION="1.2"
DEFAULT_GPG_FINGERPRINT="81F5E2832BD2545A1897B713AA99442FB680B620"

# ---------------------------------------------------------------------------
# Defaults / overrides
# ---------------------------------------------------------------------------
SAMBA_PREFIX_OVERRIDE="${SAMBA_PREFIX:-}"
BUILD_USER_OVERRIDE="${BUILD_USER:-}"
SAMBA_CONFIGURE_ARGS_OVERRIDE="${SAMBA_CONFIGURE_ARGS:-}"
GPG_FINGERPRINT_OVERRIDE="${SAMBA_GPG_FINGERPRINT:-}"

SAMBA_PREFIX=""
SAMBA_SERVICE="${SAMBA_SERVICE:-samba-ad-dc.service}"
BUILD_ROOT="${BUILD_ROOT:-/usr/local/src/samba-upgrades}"
DOMAIN_BACKUP_DIR="${DOMAIN_BACKUP_DIR:-/var/backups/samba-ad}"
UPGRADE_BACKUP_DIR="${UPGRADE_BACKUP_DIR:-/var/backups/samba-upgrade}"
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"
BUILD_HOME="${BUILD_HOME:-/var/lib/samba-build}"

MANIFEST_FILE="${MANIFEST_FILE:-/etc/samba-ad/installation.env}"
BUILD_INFO_FILE="/etc/samba-ad/build-info.txt"
UPGRADE_HISTORY_FILE="/etc/samba-ad/upgrade-history.log"

ALLOW_FEATURE_UPGRADE=0
ALLOW_DOWNGRADE=0
ALLOW_MANIFEST_MISMATCH=0
IGNORE_MANIFEST=0
ASSUME_YES=0
AUDIT_ONLY=0
TARGET_VERSION=""
CLI_GPG_FINGERPRINT=""

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
ISO_TIMESTAMP="$(date -Is)"
LOG_DIR="/var/log/samba-upgrade"
LOG_FILE="${LOG_DIR}/upgrade-${TIMESTAMP}.log"

CURRENT_VERSION=""
CURRENT_BRANCH=""
TARGET_BRANCH=""
SMB_CONF=""
DNS_DOMAIN=""
NETBIOS_DOMAIN=""
DC_FQDN=""
DC_IP=""
SOURCE_DIR=""
SOURCE_SHA256=""
EXPECTED_GPG_FINGERPRINT=""
SIGNER_GPG_FINGERPRINT=""
BUILD_USER=""
CONFIGURE_ARGS_STRING=""
declare -a CONFIGURE_ARGS=()

MANIFEST_PRESENT=0
MANIFEST_INSTALLER_REVISION=""
MANIFEST_DISTRO_ID=""
MANIFEST_DISTRO_VERSION=""
MANIFEST_SAMBA_VERSION=""
MANIFEST_SAMBA_PREFIX=""
MANIFEST_AD_DNS_DOMAIN=""
MANIFEST_NETBIOS_DOMAIN=""
MANIFEST_BUILD_USER=""
MANIFEST_CONFIGURE_ARGS=""
MANIFEST_GPG_FINGERPRINT=""

MAINTENANCE_ACTIVE=0
INSTALL_STARTED=0
PREFIX_BACKUP=""
FAILED_PREFIX=""
MANIFEST_BACKUP=""
UPGRADER_SELF_SHA256=""

mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
info() { printf '\n\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[AVISO]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERRO]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
Uso:
  upgrade.sh VERSAO [opções]

Exemplos:
  upgrade.sh --audit
  upgrade.sh 4.24.6
  upgrade.sh 4.24.6 --yes
  upgrade.sh 4.25.1 --allow-feature-upgrade

Opções:
  --allow-feature-upgrade
      Permite mudar a série major.minor, por exemplo 4.24 -> 4.25.
      Leia as release notes do Samba antes de usar.

  --allow-downgrade
      Permite informar uma versão inferior à instalada.
      Downgrade de Samba AD é uma operação excepcional.

  --allow-manifest-mismatch
      Permite continuar quando /etc/samba-ad/installation.env diverge
      do Samba realmente instalado.

  --ignore-manifest
      Ignora /etc/samba-ad/installation.env e usa autodetecção/fallbacks.

  --gpg-fingerprint FINGERPRINT
      Substitui explicitamente o fingerprint esperado da chave de assinatura.
      Útil somente em caso de rotação oficial da chave do projeto Samba.

  --jobs N
      Quantidade de jobs usados pelo make.

  --audit
      Executa somente uma auditoria/pré-check da instalação atual.
      Não baixa, compila, para ou altera o Samba. Pode ser usado agora,
      mesmo sem existir uma nova versão.

  --yes, -y
      Não pede confirmação interativa.

  --help, -h
      Mostra esta ajuda.

Variáveis de ambiente:
  SAMBA_PREFIX
  SAMBA_SERVICE
  BUILD_ROOT
  DOMAIN_BACKUP_DIR
  UPGRADE_BACKUP_DIR
  BUILD_JOBS
  BUILD_USER
  BUILD_HOME
  SAMBA_CONFIGURE_ARGS
  SAMBA_GPG_FINGERPRINT
  MANIFEST_FILE

Política padrão:
  4.24.5 -> 4.24.6 : permitido
  4.24.x -> 4.25.x : bloqueado sem --allow-feature-upgrade
  downgrade         : bloqueado sem --allow-downgrade
USAGE
}

# ---------------------------------------------------------------------------
# Basic helpers
# ---------------------------------------------------------------------------
require_root() {
    [[ $EUID -eq 0 ]] || die "Execute como root."
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Comando obrigatório não encontrado: $1"
}

validate_version_string() {
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+([A-Za-z0-9._-]*)?$ ]] || \
        die "Versão inválida: '$1'. Exemplo esperado: 4.24.6"
}

normalize_fingerprint() {
    printf '%s' "$1" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]'
}

validate_fingerprint() {
    local fp
    fp="$(normalize_fingerprint "$1")"
    [[ "$fp" =~ ^[0-9A-F]{40}$ ]] || \
        die "Fingerprint GPG inválido: '$1'. Esperados 40 caracteres hexadecimais."
}

version_lt() {
    [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" == "$1" ]]
}

get_branch() {
    printf '%s\n' "$1" | awk -F. '{print $1"."$2}'
}

acquire_lock() {
    mkdir -p /run/lock
    exec 9>/run/lock/samba-upgrade.lock
    flock -n 9 || die "Já existe outro samba-upgrade em execução."
}

get_smb_conf() {
    local p
    p="$("${SAMBA_PREFIX}/sbin/smbd" -b 2>/dev/null | awk -F': ' '/CONFIGFILE:/ {print $2; exit}')"
    [[ -n "$p" ]] || die "Não foi possível descobrir CONFIGFILE com smbd -b."
    printf '%s\n' "$p"
}

get_smb_value() {
    local conf="$1"
    local key="$2"
    awk -F= -v wanted="$key" '
        BEGIN { IGNORECASE=1 }
        {
            k=$1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
            if (tolower(k) == tolower(wanted)) {
                v=$2
                for (i=3; i<=NF; i++) v=v"="$i
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
                print v
                exit
            }
        }
    ' "$conf"
}

get_dns_domain() {
    local conf="$1"
    local realm
    realm="$(get_smb_value "$conf" "realm")"
    printf '%s\n' "${realm,,}"
}

get_netbios_domain() {
    get_smb_value "$1" "workgroup" | tr '[:lower:]' '[:upper:]'
}

detect_dc_ip() {
    local fqdn="$1"
    local ip=""
    if [[ -n "$fqdn" ]]; then
        ip="$(getent ahostsv4 "$fqdn" 2>/dev/null | awk 'NR==1 {print $1}' || true)"
    fi
    if [[ -z "$ip" ]]; then
        ip="$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
    fi
    printf '%s\n' "$ip"
}

# ---------------------------------------------------------------------------
# Manifest handling
# ---------------------------------------------------------------------------
check_manifest_security() {
    local file="$1"
    [[ -f "$file" ]] || return 1

    local uid mode
    uid="$(stat -c '%u' "$file")"
    mode="$(stat -c '%a' "$file")"

    [[ "$uid" == "0" ]] || die "Manifesto $file não pertence ao root."
    if (( (8#$mode & 022) != 0 )); then
        die "Manifesto $file é gravável por grupo/outros (modo $mode). Corrija as permissões antes do upgrade."
    fi
}

manifest_get() {
    local key="$1"
    /bin/bash -c '
        set -u
        source "$1"
        key="$2"
        printf "%s" "${!key-}"
    ' _ "$MANIFEST_FILE" "$key"
}

load_manifest() {
    if (( IGNORE_MANIFEST == 1 )); then
        warn "Manifesto ignorado por solicitação do operador."
        return 0
    fi

    if [[ ! -f "$MANIFEST_FILE" ]]; then
        warn "Manifesto $MANIFEST_FILE não existe; usando modo legado/autodetecção."
        return 0
    fi

    check_manifest_security "$MANIFEST_FILE"
    MANIFEST_PRESENT=1

    MANIFEST_INSTALLER_REVISION="$(manifest_get INSTALLER_REVISION)"
    MANIFEST_DISTRO_ID="$(manifest_get DISTRO_ID)"
    MANIFEST_DISTRO_VERSION="$(manifest_get DISTRO_VERSION)"
    MANIFEST_SAMBA_VERSION="$(manifest_get SAMBA_VERSION)"
    MANIFEST_SAMBA_PREFIX="$(manifest_get SAMBA_PREFIX)"
    MANIFEST_AD_DNS_DOMAIN="$(manifest_get AD_DNS_DOMAIN)"
    MANIFEST_NETBIOS_DOMAIN="$(manifest_get NETBIOS_DOMAIN)"
    MANIFEST_BUILD_USER="$(manifest_get BUILD_USER)"
    MANIFEST_CONFIGURE_ARGS="$(manifest_get SAMBA_CONFIGURE_ARGS)"
    MANIFEST_GPG_FINGERPRINT="$(manifest_get SAMBA_GPG_FINGERPRINT)"

    ok "Manifesto carregado: $MANIFEST_FILE"
}

resolve_runtime_configuration() {
    # Prefix
    if [[ -n "$SAMBA_PREFIX_OVERRIDE" ]]; then
        SAMBA_PREFIX="$SAMBA_PREFIX_OVERRIDE"
    elif [[ -n "$MANIFEST_SAMBA_PREFIX" ]]; then
        SAMBA_PREFIX="$MANIFEST_SAMBA_PREFIX"
    else
        SAMBA_PREFIX="/opt/samba"
    fi

    # Build user
    if [[ -n "$BUILD_USER_OVERRIDE" ]]; then
        BUILD_USER="$BUILD_USER_OVERRIDE"
    elif [[ -n "$MANIFEST_BUILD_USER" ]]; then
        BUILD_USER="$MANIFEST_BUILD_USER"
    else
        BUILD_USER="samba-build"
    fi

    # Configure args
    if [[ -n "$SAMBA_CONFIGURE_ARGS_OVERRIDE" ]]; then
        CONFIGURE_ARGS_STRING="$SAMBA_CONFIGURE_ARGS_OVERRIDE"
    elif [[ -n "$MANIFEST_CONFIGURE_ARGS" ]]; then
        CONFIGURE_ARGS_STRING="$MANIFEST_CONFIGURE_ARGS"
    else
        CONFIGURE_ARGS_STRING="--prefix=${SAMBA_PREFIX} --disable-cups"
    fi

    # GPG fingerprint
    if [[ -n "$CLI_GPG_FINGERPRINT" ]]; then
        EXPECTED_GPG_FINGERPRINT="$(normalize_fingerprint "$CLI_GPG_FINGERPRINT")"
    elif [[ -n "$GPG_FINGERPRINT_OVERRIDE" ]]; then
        EXPECTED_GPG_FINGERPRINT="$(normalize_fingerprint "$GPG_FINGERPRINT_OVERRIDE")"
    elif [[ -n "$MANIFEST_GPG_FINGERPRINT" ]]; then
        EXPECTED_GPG_FINGERPRINT="$(normalize_fingerprint "$MANIFEST_GPG_FINGERPRINT")"
    else
        EXPECTED_GPG_FINGERPRINT="$DEFAULT_GPG_FINGERPRINT"
    fi
    validate_fingerprint "$EXPECTED_GPG_FINGERPRINT"

    # Transform the shell-like args string into an array using Python shlex.
    mapfile -d '' CONFIGURE_ARGS < <(
        python3 - "$CONFIGURE_ARGS_STRING" <<'PY'
import shlex, sys
for arg in shlex.split(sys.argv[1]):
    sys.stdout.write(arg + "\0")
PY
    )

    ((${#CONFIGURE_ARGS[@]} > 0)) || die "SAMBA_CONFIGURE_ARGS resultou em lista vazia."

    local prefix_arg=""
    local arg
    for arg in "${CONFIGURE_ARGS[@]}"; do
        case "$arg" in
            --prefix=*)
                prefix_arg="${arg#--prefix=}"
                ;;
        esac
    done

    [[ -n "$prefix_arg" ]] || \
        die "Parâmetros de compilação não contêm --prefix=. Valor: $CONFIGURE_ARGS_STRING"

    if [[ "$prefix_arg" != "$SAMBA_PREFIX" ]]; then
        die "SAMBA_CONFIGURE_ARGS usa prefixo '$prefix_arg', mas o Samba selecionado está em '$SAMBA_PREFIX'."
    fi
}

check_manifest_consistency() {
    (( MANIFEST_PRESENT == 1 )) || return 0

    local mismatch=0

    if [[ -n "$MANIFEST_SAMBA_PREFIX" && "$MANIFEST_SAMBA_PREFIX" != "$SAMBA_PREFIX" ]]; then
        warn "Manifesto SAMBA_PREFIX=$MANIFEST_SAMBA_PREFIX; selecionado=$SAMBA_PREFIX"
        mismatch=1
    fi

    if [[ -n "$MANIFEST_SAMBA_VERSION" && "$MANIFEST_SAMBA_VERSION" != "$CURRENT_VERSION" ]]; then
        warn "Manifesto SAMBA_VERSION=$MANIFEST_SAMBA_VERSION; Samba real=$CURRENT_VERSION"
        mismatch=1
    fi

    if [[ -n "$MANIFEST_AD_DNS_DOMAIN" && -n "$DNS_DOMAIN" &&
          "${MANIFEST_AD_DNS_DOMAIN,,}" != "${DNS_DOMAIN,,}" ]]; then
        warn "Manifesto AD_DNS_DOMAIN=$MANIFEST_AD_DNS_DOMAIN; smb.conf realm=$DNS_DOMAIN"
        mismatch=1
    fi

    if [[ -n "$MANIFEST_NETBIOS_DOMAIN" && -n "$NETBIOS_DOMAIN" &&
          "${MANIFEST_NETBIOS_DOMAIN^^}" != "${NETBIOS_DOMAIN^^}" ]]; then
        warn "Manifesto NETBIOS_DOMAIN=$MANIFEST_NETBIOS_DOMAIN; smb.conf workgroup=$NETBIOS_DOMAIN"
        mismatch=1
    fi

    if (( mismatch == 1 && ALLOW_MANIFEST_MISMATCH == 0 )); then
        die "Manifesto e instalação real divergem. Investigue antes de atualizar ou use --allow-manifest-mismatch conscientemente."
    fi

    if (( mismatch == 1 )); then
        warn "Prosseguindo apesar das divergências do manifesto."
    else
        ok "Manifesto coerente com a instalação atual."
    fi
}

# ---------------------------------------------------------------------------
# Build user
# ---------------------------------------------------------------------------
ensure_build_user() {
    if id "$BUILD_USER" >/dev/null 2>&1; then
        local detected_home
        detected_home="$(getent passwd "$BUILD_USER" | cut -d: -f6)"
        if [[ -n "$detected_home" && -d "$detected_home" ]]; then
            BUILD_HOME="$detected_home"
        fi
    else
        info "Criando usuário sem privilégios para compilação: $BUILD_USER"
        local nologin_shell
        nologin_shell="$(command -v nologin 2>/dev/null || true)"
        [[ -n "$nologin_shell" ]] || nologin_shell="/usr/sbin/nologin"
        useradd --system --home-dir "$BUILD_HOME" --create-home --shell "$nologin_shell" "$BUILD_USER"
    fi

    mkdir -p "$BUILD_HOME"
    chown "$BUILD_USER:$BUILD_USER" "$BUILD_HOME"
}

# ---------------------------------------------------------------------------
# Disk / environment checks
# ---------------------------------------------------------------------------
check_disk_space() {
    local prefix_mb backup_free_mb build_free_mb required_backup_mb
    prefix_mb="$(du -sm "$SAMBA_PREFIX" | awk '{print $1}')"
    backup_free_mb="$(df -Pm "$UPGRADE_BACKUP_DIR" | awk 'NR==2 {print $4}')"
    build_free_mb="$(df -Pm "$BUILD_ROOT" | awk 'NR==2 {print $4}')"

    # Full consistent prefix snapshot + some safety margin.
    required_backup_mb=$((prefix_mb + 512))

    info "Espaço em disco"
    printf '  Prefixo Samba         : %s MB\n' "$prefix_mb"
    printf '  Livre para rollback   : %s MB\n' "$backup_free_mb"
    printf '  Livre para build      : %s MB\n' "$build_free_mb"

    (( backup_free_mb >= required_backup_mb )) || \
        die "Espaço insuficiente em $UPGRADE_BACKUP_DIR. Necessário pelo menos ~${required_backup_mb} MB."

    if (( build_free_mb < 3072 )); then
        warn "Há menos de 3 GB livres em $BUILD_ROOT; a compilação pode falhar por falta de espaço."
    fi
}

check_environment() {
    require_root
    acquire_lock

    local cmds=(
        bash curl gpg gzip tar make gcc sort awk sed grep flock
        systemctl journalctl host ldconfig sha256sum stat python3
        runuser useradd getent ip zstd sync
    )
    local c
    for c in "${cmds[@]}"; do need_cmd "$c"; done

    load_manifest
    resolve_runtime_configuration

    [[ -x "${SAMBA_PREFIX}/bin/samba-tool" ]] || \
        die "samba-tool não encontrado em ${SAMBA_PREFIX}/bin."
    [[ -x "${SAMBA_PREFIX}/sbin/smbd" ]] || \
        die "smbd não encontrado em ${SAMBA_PREFIX}/sbin."

    systemctl is-active --quiet "$SAMBA_SERVICE" || \
        die "O serviço $SAMBA_SERVICE não está ativo. Corrija isso antes do upgrade."

    CURRENT_VERSION="$("${SAMBA_PREFIX}/bin/samba-tool" --version | tr -d '[:space:]')"
    validate_version_string "$CURRENT_VERSION"

    CURRENT_BRANCH="$(get_branch "$CURRENT_VERSION")"

    if (( AUDIT_ONLY == 0 )); then
        TARGET_BRANCH="$(get_branch "$TARGET_VERSION")"

        [[ "$CURRENT_VERSION" != "$TARGET_VERSION" ]] || \
            die "A versão $TARGET_VERSION já está instalada."

        if version_lt "$TARGET_VERSION" "$CURRENT_VERSION" && (( ALLOW_DOWNGRADE == 0 )); then
            die "Downgrade $CURRENT_VERSION -> $TARGET_VERSION bloqueado. Use --allow-downgrade somente se for intencional."
        fi

        if [[ "$CURRENT_BRANCH" != "$TARGET_BRANCH" && $ALLOW_FEATURE_UPGRADE -eq 0 ]]; then
            die "Mudança de série $CURRENT_BRANCH -> $TARGET_BRANCH bloqueada. Leia as release notes e use --allow-feature-upgrade."
        fi
    fi

    SMB_CONF="$(get_smb_conf)"
    [[ -f "$SMB_CONF" ]] || die "smb.conf não encontrado: $SMB_CONF"

    DNS_DOMAIN="$(get_dns_domain "$SMB_CONF")"
    NETBIOS_DOMAIN="$(get_netbios_domain "$SMB_CONF")"
    DC_FQDN="$(hostname -f 2>/dev/null || true)"
    DC_IP="$(detect_dc_ip "$DC_FQDN")"

    check_manifest_consistency

    if (( AUDIT_ONLY == 0 )); then
        ensure_build_user
        mkdir -p "$BUILD_ROOT" "$DOMAIN_BACKUP_DIR" "$UPGRADE_BACKUP_DIR"
        chmod 700 "$DOMAIN_BACKUP_DIR" "$UPGRADE_BACKUP_DIR"
        check_disk_space
    else
        if id "$BUILD_USER" >/dev/null 2>&1; then
            ok "Build user já existe: $BUILD_USER"
        else
            warn "Build user ainda não existe: $BUILD_USER (será criado automaticamente quando houver upgrade)."
        fi
    fi

    local self_path
    self_path="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
    if [[ -f "$self_path" ]]; then
        UPGRADER_SELF_SHA256="$(sha256sum "$self_path" | awk '{print $1}')"
    else
        UPGRADER_SELF_SHA256="unknown"
    fi

    info "Ambiente detectado"
    printf '  Upgrader             : %s\n' "$UPGRADER_REVISION"
    if [[ -n "$MANIFEST_DISTRO_ID" ]]; then
        printf '  Distribuição         : %s %s\n' "$MANIFEST_DISTRO_ID" "$MANIFEST_DISTRO_VERSION"
    fi
    printf '  Samba atual          : %s\n' "$CURRENT_VERSION"
    printf '  Samba destino        : %s\n' "$([[ $AUDIT_ONLY -eq 1 ]] && printf 'AUDITORIA APENAS' || printf '%s' "$TARGET_VERSION")"
    printf '  Prefixo              : %s\n' "$SAMBA_PREFIX"
    printf '  Serviço              : %s\n' "$SAMBA_SERVICE"
    printf '  smb.conf             : %s\n' "$SMB_CONF"
    printf '  Domínio DNS          : %s\n' "${DNS_DOMAIN:-não detectado}"
    printf '  NetBIOS              : %s\n' "${NETBIOS_DOMAIN:-não detectado}"
    printf '  DC                    : %s\n' "${DC_FQDN:-não detectado}"
    printf '  IP                    : %s\n' "${DC_IP:-não detectado}"
    printf '  Build user            : %s\n' "$BUILD_USER"
    printf '  Configure args        : %s\n' "$CONFIGURE_ARGS_STRING"
    printf '  GPG fingerprint      : %s\n' "$EXPECTED_GPG_FINGERPRINT"
    printf '  Manifesto             : %s\n' "$([[ $MANIFEST_PRESENT -eq 1 ]] && printf 'sim (%s)' "$MANIFEST_FILE" || printf 'não / modo legado')"
    printf '  Jobs de compilação   : %s\n' "$BUILD_JOBS"
}

# ---------------------------------------------------------------------------
# Core preflight
# ---------------------------------------------------------------------------
preflight_core_checks() {
    export PATH="${SAMBA_PREFIX}/bin:${SAMBA_PREFIX}/sbin:${PATH}"

    info "Pré-checks do Samba AD"

    samba-tool testparm --suppress-prompt
    samba-tool dbcheck --cross-ncs
    samba-tool fsmo show >/dev/null

    if [[ -n "$DNS_DOMAIN" ]]; then
        host -t SRV "_ldap._tcp.${DNS_DOMAIN}" 127.0.0.1 >/dev/null
        host -t SRV "_kerberos._udp.${DNS_DOMAIN}" 127.0.0.1 >/dev/null
    else
        warn "Realm não detectado; testes DNS SRV serão ignorados."
    fi

    if [[ -x /usr/local/sbin/samba-ad-health ]]; then
        info "Executando health-check instalado (informativo)"
        if /usr/local/sbin/samba-ad-health; then
            ok "Health-check geral aprovado."
        else
            warn "O health-check geral reportou problema. Os pré-checks centrais do AD passaram; revise o relatório antes de prosseguir."
            if (( ASSUME_YES == 0 )); then
                read -r -p "Continuar mesmo assim? [s/N]: " answer
                [[ "${answer,,}" == "s" || "${answer,,}" == "sim" ]] || die "Cancelado após health-check."
            fi
        fi
    fi

    ok "Pré-checks centrais aprovados."
}

# ---------------------------------------------------------------------------
# Download / GPG verification
# ---------------------------------------------------------------------------
download_and_verify() {
    local work="${BUILD_ROOT}/samba-${TARGET_VERSION}"
    local gz_file="samba-${TARGET_VERSION}.tar.gz"
    local tar_file="samba-${TARGET_VERSION}.tar"
    local sig_file="${tar_file}.asc"
    local base_url="https://download.samba.org/pub/samba/stable"
    local gnupg_dir="${BUILD_ROOT}/gnupg-${TARGET_VERSION}"

    mkdir -p "$work"
    rm -rf "$gnupg_dir"
    mkdir -p "$gnupg_dir"
    chmod 700 "$gnupg_dir"

    cd "$work"

    info "Baixando Samba ${TARGET_VERSION}"
    if [[ ! -f "$gz_file" ]]; then
        curl -fL --retry 3 --retry-delay 2 \
            -o "${gz_file}.part" "${base_url}/${gz_file}"
        mv -f "${gz_file}.part" "$gz_file"
    else
        ok "$gz_file já existe; será validado novamente."
    fi

    info "Baixando assinatura oficial"
    if [[ ! -f "$sig_file" ]]; then
        curl -fL --retry 3 --retry-delay 2 \
            -o "${sig_file}.part" "${base_url}/${sig_file}"
        mv -f "${sig_file}.part" "$sig_file"
    else
        ok "$sig_file já existe; será validado novamente."
    fi

    info "Baixando chave pública de distribuição do Samba"
    curl -fL --retry 3 --retry-delay 2 \
        -o "${work}/samba-pubkey.asc.part" \
        "https://www.samba.org/samba/ftp/samba-pubkey.asc"
    mv -f "${work}/samba-pubkey.asc.part" "${work}/samba-pubkey.asc"

    GNUPGHOME="$gnupg_dir" \
        gpg --batch --import "${work}/samba-pubkey.asc" >/dev/null 2>&1

    local key_present=0
    while IFS= read -r fp; do
        fp="$(normalize_fingerprint "$fp")"
        if [[ "$fp" == "$EXPECTED_GPG_FINGERPRINT" ]]; then
            key_present=1
            break
        fi
    done < <(
        GNUPGHOME="$gnupg_dir" \
            gpg --batch --with-colons --fingerprint 2>/dev/null |
            awk -F: '$1=="fpr" {print $10}'
    )

    (( key_present == 1 )) || \
        die "A chave pública baixada não contém o fingerprint esperado $EXPECTED_GPG_FINGERPRINT."

    ok "Fingerprint esperado existe na chave oficial baixada."

    info "Preparando tarball descompactado para validação GPG"
    gzip -dc "$gz_file" > "${tar_file}.part"
    mv -f "${tar_file}.part" "$tar_file"

    info "Validando assinatura GPG e fingerprint do SIGNATÁRIO"
    local status_file="${work}/gpg-status-${TIMESTAMP}.txt"
    if ! GNUPGHOME="$gnupg_dir" \
        gpg --batch --status-fd 1 --verify "$sig_file" "$tar_file" \
        >"$status_file" 2>&1; then
        cat "$status_file" >&2 || true
        die "A assinatura GPG do Samba ${TARGET_VERSION} não pôde ser validada."
    fi

    SIGNER_GPG_FINGERPRINT="$(
        awk '/^\[GNUPG:\] VALIDSIG / {print $3; exit}' "$status_file" |
        tr '[:lower:]' '[:upper:]'
    )"

    [[ -n "$SIGNER_GPG_FINGERPRINT" ]] || \
        die "GPG confirmou a assinatura, mas não foi possível obter o fingerprint do signatário."

    if [[ "$SIGNER_GPG_FINGERPRINT" != "$EXPECTED_GPG_FINGERPRINT" ]]; then
        die "Assinatura válida, porém feita por fingerprint inesperado: $SIGNER_GPG_FINGERPRINT (esperado $EXPECTED_GPG_FINGERPRINT)."
    fi

    ok "Assinatura GPG validada pelo fingerprint esperado: $SIGNER_GPG_FINGERPRINT"

    SOURCE_SHA256="$(sha256sum "$gz_file" | awk '{print $1}')"
    printf '  SHA256 do fonte     : %s\n' "$SOURCE_SHA256"

    rm -rf "${work}/src"
    mkdir -p "${work}/src"
    tar xf "$tar_file" -C "${work}/src"

    SOURCE_DIR="${work}/src/samba-${TARGET_VERSION}"
    [[ -d "$SOURCE_DIR" ]] || \
        die "Diretório fonte não encontrado após extração: $SOURCE_DIR"

    chown -R "$BUILD_USER:$BUILD_USER" "${work}/src"
}

# ---------------------------------------------------------------------------
# Build online, unprivileged
# ---------------------------------------------------------------------------
build_new_version() {
    info "Configurando Samba ${TARGET_VERSION} como usuário $BUILD_USER"
    printf '  ./configure'
    printf ' %q' "${CONFIGURE_ARGS[@]}"
    printf '\n'

    runuser -u "$BUILD_USER" -- env HOME="$BUILD_HOME" \
        bash -c 'cd "$1" && shift && exec ./configure "$@"' \
        _ "$SOURCE_DIR" "${CONFIGURE_ARGS[@]}"

    info "Compilando Samba ${TARGET_VERSION} com ${BUILD_JOBS} jobs como usuário $BUILD_USER"
    runuser -u "$BUILD_USER" -- env HOME="$BUILD_HOME" \
        bash -c 'cd "$1" && exec make -j"$2"' \
        _ "$SOURCE_DIR" "$BUILD_JOBS"

    ok "Compilação concluída com o DC ainda ONLINE."
}

# ---------------------------------------------------------------------------
# Domain backup while online
# ---------------------------------------------------------------------------
create_domain_backup() {
    export PATH="${SAMBA_PREFIX}/bin:${SAMBA_PREFIX}/sbin:${PATH}"

    info "Executando dbcheck imediatamente antes do backup"
    samba-tool dbcheck --cross-ncs

    info "Gerando backup consistente do domínio"
    local before_list after_list
    before_list="$(mktemp)"
    after_list="$(mktemp)"

    find "$DOMAIN_BACKUP_DIR" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | sort >"$before_list" || true

    samba-tool domain backup offline --targetdir="$DOMAIN_BACKUP_DIR"

    find "$DOMAIN_BACKUP_DIR" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | sort >"$after_list" || true

    local new_files
    new_files="$(comm -13 "$before_list" "$after_list" || true)"
    rm -f "$before_list" "$after_list"

    if [[ -n "$new_files" ]]; then
        ok "Novo backup do domínio criado:"
        printf '%s\n' "$new_files" | sed 's/^/  /'
    else
        warn "Não foi possível identificar pelo nome um novo arquivo no diretório de backup."
        warn "O comando samba-tool terminou com sucesso; confira $DOMAIN_BACKUP_DIR manualmente."
    fi
}

# ---------------------------------------------------------------------------
# Maintenance snapshot / rollback
# ---------------------------------------------------------------------------
create_consistent_prefix_snapshot() {
    info "Criando snapshot consistente do prefixo com o Samba PARADO"
    PREFIX_BACKUP="${UPGRADE_BACKUP_DIR}/samba-prefix-${CURRENT_VERSION}-${TIMESTAMP}.tar.zst"

    sync

    tar \
        --xattrs \
        --acls \
        --selinux \
        -I 'zstd -T0 -1' \
        -cpf "$PREFIX_BACKUP" \
        -C "$(dirname "$SAMBA_PREFIX")" \
        "$(basename "$SAMBA_PREFIX")"

    chmod 600 "$PREFIX_BACKUP"

    tar -I zstd -tf "$PREFIX_BACKUP" | sed -n '1,5p' >/dev/null

    ok "Snapshot consistente criado: $PREFIX_BACKUP"
}

restart_old_service_without_restore() {
    warn "A instalação nova ainda não havia começado; tentando apenas religar o Samba atual."
    systemctl start "$SAMBA_SERVICE" || true
    sleep 2
    systemctl is-active --quiet "$SAMBA_SERVICE"
}

rollback_prefix() {
    [[ -n "$PREFIX_BACKUP" && -f "$PREFIX_BACKUP" ]] || {
        warn "Rollback automático indisponível: snapshot do prefixo não encontrado."
        return 1
    }

    warn "Executando rollback completo de ${SAMBA_PREFIX}..."

    systemctl stop "$SAMBA_SERVICE" 2>/dev/null || true

    FAILED_PREFIX="${SAMBA_PREFIX}.failed-${TIMESTAMP}"
    if [[ -d "$SAMBA_PREFIX" ]]; then
        mv "$SAMBA_PREFIX" "$FAILED_PREFIX"
        warn "Instalação que falhou preservada em: $FAILED_PREFIX"
    fi

    mkdir -p "$(dirname "$SAMBA_PREFIX")"

    tar \
        --xattrs \
        --acls \
        --selinux \
        -I zstd \
        -xpf "$PREFIX_BACKUP" \
        -C "$(dirname "$SAMBA_PREFIX")"

    ldconfig
    systemctl daemon-reload

    if systemctl start "$SAMBA_SERVICE"; then
        sleep 3
        if systemctl is-active --quiet "$SAMBA_SERVICE"; then
            ok "Rollback concluído; Samba ${CURRENT_VERSION} voltou a funcionar."
            return 0
        fi
    fi

    warn "O conteúdo anterior foi restaurado, mas o serviço não iniciou."
    systemctl --no-pager -l status "$SAMBA_SERVICE" || true
    journalctl -u "$SAMBA_SERVICE" -n 100 --no-pager || true
    return 1
}

on_error() {
    local rc=$?
    local line="${BASH_LINENO[0]:-?}"

    printf '\n\033[1;31m[ERRO]\033[0m Falha na linha %s. Código=%s\n' "$line" "$rc" >&2

    if (( MAINTENANCE_ACTIVE == 1 )); then
        warn "A falha ocorreu durante a janela de manutenção."

        if (( INSTALL_STARTED == 1 )); then
            rollback_prefix || true
        else
            restart_old_service_without_restore || true
        fi
    fi

    printf 'Log: %s\n' "$LOG_FILE" >&2
    exit "$rc"
}
trap on_error ERR

# ---------------------------------------------------------------------------
# Install in maintenance window
# ---------------------------------------------------------------------------
perform_upgrade() {
    info "Iniciando janela de manutenção"
    MAINTENANCE_ACTIVE=1
    INSTALL_STARTED=0

    systemctl stop "$SAMBA_SERVICE"
    if systemctl is-active --quiet "$SAMBA_SERVICE"; then
        die "O serviço continuou ativo após systemctl stop."
    fi

    # Full prefix backup is made only after Samba is stopped, avoiding a
    # filesystem-level archive of live sam.ldb/private data.
    create_consistent_prefix_snapshot

    if (( MANIFEST_PRESENT == 1 )); then
        MANIFEST_BACKUP="${UPGRADE_BACKUP_DIR}/installation.env-before-${CURRENT_VERSION}-${TIMESTAMP}"
        cp -a "$MANIFEST_FILE" "$MANIFEST_BACKUP"
        chmod 600 "$MANIFEST_BACKUP"
    fi

    INSTALL_STARTED=1

    info "Instalando Samba ${TARGET_VERSION} sobre ${SAMBA_PREFIX}"
    make -C "$SOURCE_DIR" install

    ldconfig
    systemctl daemon-reload

    local installed
    installed="$("${SAMBA_PREFIX}/bin/samba-tool" --version | tr -d '[:space:]')"
    [[ "$installed" == "$TARGET_VERSION" ]] || \
        die "Após make install, samba-tool reportou '$installed', esperado '$TARGET_VERSION'."

    info "Validando configuração com a nova versão antes do start"
    "${SAMBA_PREFIX}/bin/samba-tool" testparm --suppress-prompt

    info "Iniciando $SAMBA_SERVICE"
    systemctl start "$SAMBA_SERVICE"
    sleep 4

    if ! systemctl is-active --quiet "$SAMBA_SERVICE"; then
        systemctl --no-pager -l status "$SAMBA_SERVICE" || true
        journalctl -u "$SAMBA_SERVICE" -n 100 --no-pager || true
        die "O Samba novo não iniciou."
    fi

    # Once the new Samba has actually run, automatic binary/data rollback is
    # deliberately disabled. Post-upgrade DB changes must be assessed before
    # restoring an older complete prefix.
    MAINTENANCE_ACTIVE=0

    ok "Samba ${TARGET_VERSION} iniciou corretamente."
}

# ---------------------------------------------------------------------------
# Post-upgrade checks
# ---------------------------------------------------------------------------
post_upgrade_checks() {
    export PATH="${SAMBA_PREFIX}/bin:${SAMBA_PREFIX}/sbin:${PATH}"

    info "Testes pós-upgrade"

    local installed
    installed="$(samba-tool --version | tr -d '[:space:]')"
    [[ "$installed" == "$TARGET_VERSION" ]] || die "Versão ativa inesperada: $installed"

    samba-tool testparm --suppress-prompt
    samba-tool dbcheck --cross-ncs
    samba-tool fsmo show
    samba-tool domain level show

    if [[ -n "$DNS_DOMAIN" ]]; then
        info "Validando registros SRV no DNS local"
        host -t SRV "_ldap._tcp.${DNS_DOMAIN}" 127.0.0.1
        host -t SRV "_kerberos._udp.${DNS_DOMAIN}" 127.0.0.1
        host -t SRV "_gc._tcp.${DNS_DOMAIN}" 127.0.0.1 || \
            warn "Registro Global Catalog não respondeu ao teste; revise se necessário."
    fi

    if [[ -x /usr/local/sbin/samba-ad-health ]]; then
        info "Executando health-check geral pós-upgrade"
        if /usr/local/sbin/samba-ad-health; then
            ok "Health-check geral aprovado."
        else
            warn "O health-check geral encontrou problema em algum componente do stack."
            warn "Os testes centrais do Samba AD acima passaram; revise o relatório e o log."
        fi
    fi

    ok "Pós-checks centrais concluídos."
}

# ---------------------------------------------------------------------------
# Manifest / audit metadata
# ---------------------------------------------------------------------------
write_or_update_manifest() {
    info "Atualizando metadados de instalação"

    mkdir -p /etc/samba-ad
    chmod 755 /etc/samba-ad

    if [[ ! -f "$MANIFEST_FILE" ]]; then
        warn "Instalação legada sem manifesto: criando manifesto mínimo após upgrade bem-sucedido."
        cat >"$MANIFEST_FILE" <<EOF
INSTALLER_REVISION=legacy-pre-0.5
MANIFEST_ORIGIN=samba-upgrade
SAMBA_VERSION=$(printf '%q' "$TARGET_VERSION")
SAMBA_PREFIX=$(printf '%q' "$SAMBA_PREFIX")
SAMBA_SOURCE_SHA256=$(printf '%q' "$SOURCE_SHA256")
SAMBA_GPG_FINGERPRINT=$(printf '%q' "$SIGNER_GPG_FINGERPRINT")
FQDN=$(printf '%q' "$DC_FQDN")
AD_DNS_DOMAIN=$(printf '%q' "$DNS_DOMAIN")
NETBIOS_DOMAIN=$(printf '%q' "$NETBIOS_DOMAIN")
DC_IP=$(printf '%q' "$DC_IP")
BUILD_USER=$(printf '%q' "$BUILD_USER")
SAMBA_CONFIGURE_ARGS=$(printf '%q' "$CONFIGURE_ARGS_STRING")
EOF
        chmod 644 "$MANIFEST_FILE"
        chown root:root "$MANIFEST_FILE"
        MANIFEST_PRESENT=1
    fi

    python3 - "$MANIFEST_FILE" \
        "$CURRENT_VERSION" "$TARGET_VERSION" "$SOURCE_SHA256" \
        "$SIGNER_GPG_FINGERPRINT" "$CONFIGURE_ARGS_STRING" "$BUILD_USER" \
        "$UPGRADER_REVISION" "$UPGRADER_SELF_SHA256" "$ISO_TIMESTAMP" <<'PY'
from pathlib import Path
import os, shlex, sys, tempfile

(
    manifest_path,
    old_version,
    new_version,
    source_sha,
    gpg_fp,
    configure_args,
    build_user,
    upgrader_revision,
    upgrader_sha,
    upgraded_at,
) = sys.argv[1:]

updates = {
    "PREVIOUS_SAMBA_VERSION": old_version,
    "SAMBA_VERSION": new_version,
    "SAMBA_SOURCE_SHA256": source_sha,
    "SAMBA_GPG_FINGERPRINT": gpg_fp,
    "SAMBA_CONFIGURE_ARGS": configure_args,
    "BUILD_USER": build_user,
    "LAST_UPGRADE_AT": upgraded_at,
    "LAST_UPGRADE_FROM": old_version,
    "LAST_UPGRADE_TO": new_version,
    "UPGRADER_REVISION": upgrader_revision,
    "UPGRADER_SELF_SHA256": upgrader_sha,
}

p = Path(manifest_path)
lines = p.read_text(encoding="utf-8").splitlines()
seen = set()
out = []

for line in lines:
    if "=" in line and not line.lstrip().startswith("#"):
        key = line.split("=", 1)[0].strip()
        if key in updates:
            out.append(f"{key}={shlex.quote(updates[key])}")
            seen.add(key)
            continue
    out.append(line)

for key, value in updates.items():
    if key not in seen:
        out.append(f"{key}={shlex.quote(value)}")

tmp = p.with_name(p.name + ".tmp")
tmp.write_text("\n".join(out) + "\n", encoding="utf-8")
os.chmod(tmp, 0o644)
os.chown(tmp, 0, 0)
os.replace(tmp, p)
PY

    {
        echo "Samba build information"
        echo "Generated: $(date -Is)"
        echo "Installer: ${MANIFEST_INSTALLER_REVISION:-legacy/unknown}"
        if [[ -n "$MANIFEST_DISTRO_ID" ]]; then
            echo "Distribution: ${MANIFEST_DISTRO_ID} ${MANIFEST_DISTRO_VERSION}"
        fi
        echo "Last upgrader: ${UPGRADER_REVISION}"
        echo "Upgrade: ${CURRENT_VERSION} -> ${TARGET_VERSION}"
        echo "Source SHA256: ${SOURCE_SHA256}"
        echo "GPG fingerprint: ${SIGNER_GPG_FINGERPRINT}"
        echo "Configure args: ${CONFIGURE_ARGS_STRING}"
        echo "Build user: ${BUILD_USER}"
        echo "Upgrader SHA256: ${UPGRADER_SELF_SHA256}"
        echo
        "${SAMBA_PREFIX}/bin/samba-tool" --version
        echo
        "${SAMBA_PREFIX}/sbin/smbd" -b
    } >"$BUILD_INFO_FILE"
    chmod 644 "$BUILD_INFO_FILE"
    chown root:root "$BUILD_INFO_FILE"

    touch "$UPGRADE_HISTORY_FILE"
    chmod 644 "$UPGRADE_HISTORY_FILE"
    chown root:root "$UPGRADE_HISTORY_FILE"

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(date -Is)" \
        "$CURRENT_VERSION" \
        "$TARGET_VERSION" \
        "$SOURCE_SHA256" \
        "$SIGNER_GPG_FINGERPRINT" \
        "$UPGRADER_REVISION" \
        >>"$UPGRADE_HISTORY_FILE"

    ok "Manifesto e histórico atualizados."
}

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
parse_args() {
    [[ $# -ge 1 ]] || { usage; exit 2; }

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --allow-feature-upgrade)
                ALLOW_FEATURE_UPGRADE=1
                shift
                ;;
            --allow-downgrade)
                ALLOW_DOWNGRADE=1
                shift
                ;;
            --allow-manifest-mismatch)
                ALLOW_MANIFEST_MISMATCH=1
                shift
                ;;
            --ignore-manifest)
                IGNORE_MANIFEST=1
                shift
                ;;
            --gpg-fingerprint)
                [[ $# -ge 2 ]] || die "--gpg-fingerprint exige um valor."
                CLI_GPG_FINGERPRINT="$2"
                validate_fingerprint "$CLI_GPG_FINGERPRINT"
                shift 2
                ;;
            --jobs)
                [[ $# -ge 2 ]] || die "--jobs exige um valor."
                BUILD_JOBS="$2"
                [[ "$BUILD_JOBS" =~ ^[1-9][0-9]*$ ]] || die "Valor inválido para --jobs."
                shift 2
                ;;
            --audit)
                AUDIT_ONLY=1
                shift
                ;;
            --yes|-y)
                ASSUME_YES=1
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            -*)
                die "Opção desconhecida: $1"
                ;;
            *)
                [[ -z "$TARGET_VERSION" ]] || die "Mais de uma versão foi informada."
                TARGET_VERSION="$1"
                shift
                ;;
        esac
    done

    if (( AUDIT_ONLY == 1 )); then
        [[ -z "$TARGET_VERSION" ]] || die "--audit não deve ser combinado com uma versão destino."
    else
        [[ -n "$TARGET_VERSION" ]] || die "Informe a versão destino."
        validate_version_string "$TARGET_VERSION"
    fi
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary() {
    cat <<EOF

===============================================================================
 UPGRADE DO SAMBA CONCLUÍDO
===============================================================================

Upgrader         : ${UPGRADER_REVISION}
Versão anterior  : ${CURRENT_VERSION}
Versão atual     : ${TARGET_VERSION}
Prefixo          : ${SAMBA_PREFIX}
Serviço          : ${SAMBA_SERVICE}

Fonte SHA256      : ${SOURCE_SHA256}
GPG signatário    : ${SIGNER_GPG_FINGERPRINT}
Build user        : ${BUILD_USER}
Configure args    : ${CONFIGURE_ARGS_STRING}

Backup AD         : ${DOMAIN_BACKUP_DIR}
Rollback prefix   : ${PREFIX_BACKUP}
Manifesto         : ${MANIFEST_FILE}
Build info        : ${BUILD_INFO_FILE}
Histórico         : ${UPGRADE_HISTORY_FILE}
Fonte/build       : ${BUILD_ROOT}/samba-${TARGET_VERSION}
Log               : ${LOG_FILE}

O snapshot completo do prefixo NÃO é apagado automaticamente.
Mantenha-o até confirmar estabilidade da nova versão.

Comandos úteis:
  samba-tool --version
  samba-tool dbcheck --cross-ncs
  samba-tool fsmo show
  samba-tool domain level show
  systemctl status ${SAMBA_SERVICE}
  journalctl -u ${SAMBA_SERVICE} -f
  cat ${MANIFEST_FILE}
  tail ${UPGRADE_HISTORY_FILE}

===============================================================================
EOF
}

print_audit_summary() {
    cat <<EOF

===============================================================================
 AUDITORIA DO SAMBA AD CONCLUÍDA
===============================================================================

Upgrader         : ${UPGRADER_REVISION}
Samba atual      : ${CURRENT_VERSION}
Prefixo          : ${SAMBA_PREFIX}
Serviço          : ${SAMBA_SERVICE}
Domínio DNS      : ${DNS_DOMAIN:-não detectado}
NetBIOS          : ${NETBIOS_DOMAIN:-não detectado}
DC               : ${DC_FQDN:-não detectado}
IP               : ${DC_IP:-não detectado}

Manifesto        : $([[ $MANIFEST_PRESENT -eq 1 ]] && printf '%s' "$MANIFEST_FILE" || printf 'ausente / instalação legada')
Build user       : ${BUILD_USER}
Configure args   : ${CONFIGURE_ARGS_STRING}
GPG esperado     : ${EXPECTED_GPG_FINGERPRINT}
Log              : ${LOG_FILE}

Nenhum binário, banco AD, serviço ou configuração do Samba foi alterado.
A auditoria valida a compatibilidade básica do ambiente com este atualizador.

===============================================================================
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"
    check_environment
    preflight_core_checks

    if (( AUDIT_ONLY == 1 )); then
        print_audit_summary
        exit 0
    fi

    if (( ASSUME_YES == 0 )); then
        printf '\nSerá executado upgrade: %s -> %s\n' "$CURRENT_VERSION" "$TARGET_VERSION"
        printf 'Download/configure/make serão feitos com o DC ONLINE.\n'
        printf 'O build será executado como usuário sem privilégios: %s\n' "$BUILD_USER"
        printf 'Na manutenção o Samba será parado e será criado snapshot consistente de %s.\n' "$SAMBA_PREFIX"
        printf 'Só depois o make install será executado.\n\n'

        read -r -p "Prosseguir? [s/N]: " answer
        [[ "${answer,,}" == "s" || "${answer,,}" == "sim" ]] || die "Cancelado."
    fi

    download_and_verify
    build_new_version
    create_domain_backup
    perform_upgrade
    post_upgrade_checks
    write_or_update_manifest
    print_summary
}

main "$@"
