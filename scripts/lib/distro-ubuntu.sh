# Ubuntu adapter for Samba AD Script.
# Supports Ubuntu 22.04/24.04 LTS; newer releases run as experimental until validated.
# shellcheck shell=bash

distro_init() {
    DISTRO_LABEL="Ubuntu ${DISTRO_VERSION}"
    SECURITY_FRAMEWORK="AppArmor"
    FIREWALL_BACKEND="ufw"
    FIREWALL_ZONE="ufw"

    WEB_SERVICE="apache2.service"
    WEB_USER="www-data"
    WEB_GROUP="www-data"

    CHRONY_SERVICE="chrony.service"
    CHRONY_CONF="/etc/chrony/chrony.conf"
    CHRONY_GROUP="_chrony"

    ADMIN_CERT="/etc/samba-ad/tls/samba-ad-admin.crt"
    ADMIN_KEY="/etc/samba-ad/tls/samba-ad-admin.key"
    SAMBA_CA_ANCHOR="/usr/local/share/ca-certificates/samba-ad-local-ca.crt"
    ADMIN_CA_ANCHOR="/usr/local/share/ca-certificates/samba-ad-admin-local.crt"
    SYSTEM_CA_BUNDLE="/etc/ssl/certs/ca-certificates.crt"

    PROMETHEUS_USER="prometheus"
    PROMETHEUS_GROUP="prometheus"
    PROMETHEUS_BIN="/usr/bin/prometheus"
    PROMETHEUS_STOCK_SERVICE="prometheus.service"
    NODE_EXPORTER_SERVICE="prometheus-node-exporter.service"
    NODE_EXPORTER_BIN="/usr/bin/prometheus-node-exporter"
    NOLOGIN_SHELL="/usr/sbin/nologin"
}

distro_validate_platform() {
    [[ "$DISTRO_ID" == "ubuntu" ]] || \
        die "Adapter Ubuntu carregado para plataforma inesperada: ${DISTRO_ID} ${DISTRO_VERSION}"

    dpkg --compare-versions "$DISTRO_VERSION" ge "22.04" || \
        die "Ubuntu 22.04 LTS ou mais recente é necessário."

    if [[ "$DISTRO_SUPPORT_TIER" == "experimental" ]]; then
        warn "Ubuntu ${DISTRO_VERSION}: suporte experimental nesta revisão."
    fi
}

apt_install() {
    DEBIAN_FRONTEND=noninteractive apt-get -y \
        -o Dpkg::Options::="--force-confold" \
        install "$@"
}

install_pkg_required() {
    local pkg="$1"
    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'ok installed'; then
        return 0
    fi
    info "Instalando pacote obrigatório: $pkg"
    apt_install "$pkg"
}

install_pkg_list_required() {
    (( $# > 0 )) || return 0
    info "Instalando lote de pacotes obrigatórios (${#} itens)"
    apt_install "$@"
}

install_pkg_optional() {
    local pkg="$1"
    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'ok installed'; then
        return 0
    fi
    if apt-cache show "$pkg" >/dev/null 2>&1; then
        apt_install "$pkg"
    else
        warn "Pacote opcional não disponível: $pkg"
    fi
}

distro_enable_repositories() {
    info "Atualizando APT e habilitando Universe"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt_install software-properties-common ca-certificates curl gnupg
    add-apt-repository -y universe >/dev/null 2>&1 || warn "Não foi possível habilitar Universe via add-apt-repository."
    apt-get update
}

distro_install_build_dependencies() {
    info "Instalando dependências para compilar o Samba AD DC no Ubuntu"

    local required=(
        acl attr
        bison build-essential flex
        python3 python3-dev python3-dnspython python3-gpg python3-markdown
        perl libparse-yapp-perl
        libacl1-dev libattr1-dev libarchive-dev libblkid-dev
        libgnutls28-dev libjansson-dev libldap2-dev liblmdb-dev
        libbsd-dev libpcap-dev libjson-perl libtasn1-bin
        libpam0g-dev libpopt-dev libreadline-dev libsystemd-dev
        libtasn1-6-dev libkeyutils-dev libgpgme-dev libcap-dev
        libtirpc-dev liburing-dev libdbus-1-dev libaio-dev
        pkg-config rpcsvc-proto xsltproc zlib1g-dev
        curl wget tar gzip bzip2 xz-utils zstd util-linux
        gnupg openssl logrotate ca-certificates
        krb5-user dnsutils chrony ufw rsyslog iproute2
    )
    install_pkg_list_required "${required[@]}"

    local p
    local optional=(
        python3-cryptography libicu-dev libunwind-dev uuid-dev
        libutf8proc-dev libtasn1-bin lmdb-utils docbook-xsl
        apparmor-utils
    )
    for p in "${optional[@]}"; do
        install_pkg_optional "$p"
    done
}

distro_get_current_dns() {
    local dns=""

    if command -v resolvectl >/dev/null 2>&1 && [[ -n "${DC_IFACE:-}" ]]; then
        dns="$(resolvectl dns "$DC_IFACE" 2>/dev/null \
            | sed -E 's/^Link [0-9]+ \([^)]*\):[[:space:]]*//' \
            | tr ' ' '\n' \
            | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
            | grep -Ev '^127\.' \
            | head -n1 || true)"
    fi

    if [[ -z "$dns" && -r /run/systemd/resolve/resolv.conf ]]; then
        dns="$(awk '/^nameserver[[:space:]]+/ {print $2}' /run/systemd/resolve/resolv.conf \
            | grep -Ev '^(127\.|::1$)' | head -n1 || true)"
    fi

    if [[ -z "$dns" ]]; then
        dns="$(awk '/^nameserver[[:space:]]+/ {print $2}' /etc/resolv.conf 2>/dev/null \
            | grep -Ev '^(127\.|::1$)' | head -n1 || true)"
    fi

    printf '%s\n' "$dns"
}

distro_check_static_ip_hint() {
    if [[ -d /etc/netplan ]]; then
        ok "Netplan detectado. O instalador não reescreve a configuração de endereço IP."
    fi
}

distro_check_security_mode() {
    if systemctl is-active --quiet apparmor.service 2>/dev/null; then
        ok "AppArmor está ativo."
    elif command -v aa-status >/dev/null 2>&1 && aa-status --enabled >/dev/null 2>&1; then
        ok "AppArmor está habilitado."
    else
        warn "AppArmor não parece estar ativo. O instalador não o desativa."
    fi
}

distro_check_conflicting_samba_packages() {
    local pkg
    for pkg in samba samba-ad-dc samba-common samba-common-bin winbind; do
        if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'ok installed'; then
            warn "Foi detectado o pacote Samba do sistema: $pkg"
            die "Use uma instalação Ubuntu limpa ou remova os pacotes Samba do sistema antes de continuar."
        fi
    done
}

ubuntu_port53_listeners() {
    ss -H -lntup 2>/dev/null | awk '$5 ~ /:53$/ {print}' || true
}

ubuntu_resolved_port53_listeners() {
    ubuntu_port53_listeners | grep -E 'systemd-resolv' || true
}

ubuntu_write_resolv_conf() {
    local dns_server="$1"
    local search_domain="${2:-}"

    rm -f /etc/resolv.conf
    {
        if [[ -n "$search_domain" ]]; then
            printf 'search %s
' "$search_domain"
        fi
        printf 'nameserver %s
' "$dns_server"
    } >/etc/resolv.conf
    chmod 644 /etc/resolv.conf
}

ubuntu_resolved_is_masked() {
    [[ "$(systemctl is-enabled systemd-resolved.service 2>/dev/null || true)" == "masked" ]]
}

ubuntu_disable_systemd_resolved_for_dc() {
    local dns_server="$1"
    local search_domain="${2:-}"
    local listeners

    warn "systemd-resolved continuou ocupando a porta 53; aplicando fallback controlado para DC dedicado."
    warn "O serviço será parado e mascarado; /etc/resolv.conf ficará sob controle do samba-ad-script."

    mkdir -p /etc/samba-ad

    if ! systemctl mask --now systemd-resolved.service >/dev/null 2>&1; then
        systemctl stop systemd-resolved.service 2>/dev/null || true
        systemctl disable systemd-resolved.service >/dev/null 2>&1 || true
        systemctl mask systemd-resolved.service >/dev/null 2>&1 || \
            die "Não foi possível mascarar systemd-resolved."
    fi

    sleep 1
    listeners="$(ubuntu_port53_listeners)"
    if [[ -n "$listeners" ]]; then
        printf '%s
' "$listeners" >&2
        die "A porta 53 continua ocupada após parar systemd-resolved."
    fi

    ubuntu_write_resolv_conf "$dns_server" "$search_domain"
    printf '%s
' "$(date -Is)" >/etc/samba-ad/systemd-resolved.disabled-by-samba-ad-script
    chmod 600 /etc/samba-ad/systemd-resolved.disabled-by-samba-ad-script
    ok "systemd-resolved desativado de forma controlada; porta 53 liberada para o Samba."
}

ubuntu_port53_listeners() {
    ss -H -lntup 2>/dev/null | awk '$5 ~ /:53$/ {print}' || true
}

ubuntu_resolved_port53_listeners() {
    ubuntu_port53_listeners | grep -E 'systemd-resolv' || true
}

ubuntu_write_resolv_conf() {
    local dns_server="$1"
    local search_domain="${2:-}"

    rm -f /etc/resolv.conf
    {
        if [[ -n "$search_domain" ]]; then
            printf 'search %s
' "$search_domain"
        fi
        printf 'nameserver %s
' "$dns_server"
    } >/etc/resolv.conf
    chmod 644 /etc/resolv.conf
}

ubuntu_resolved_is_masked() {
    [[ "$(systemctl is-enabled systemd-resolved.service 2>/dev/null || true)" == "masked" ]]
}

ubuntu_disable_systemd_resolved_for_dc() {
    local dns_server="$1"
    local search_domain="${2:-}"
    local listeners

    warn "systemd-resolved continuou ocupando a porta 53; aplicando fallback controlado para DC dedicado."
    warn "O serviço será parado e mascarado; /etc/resolv.conf ficará sob controle do samba-ad-script."

    mkdir -p /etc/samba-ad

    if ! systemctl mask --now systemd-resolved.service >/dev/null 2>&1; then
        systemctl stop systemd-resolved.service 2>/dev/null || true
        systemctl disable systemd-resolved.service >/dev/null 2>&1 || true
        systemctl mask systemd-resolved.service >/dev/null 2>&1 || \
            die "Não foi possível mascarar systemd-resolved."
    fi

    sleep 1
    listeners="$(ubuntu_port53_listeners)"
    if [[ -n "$listeners" ]]; then
        printf '%s
' "$listeners" >&2
        die "A porta 53 continua ocupada após parar systemd-resolved."
    fi

    ubuntu_write_resolv_conf "$dns_server" "$search_domain"
    printf '%s
' "$(date -Is)" >/etc/samba-ad/systemd-resolved.disabled-by-samba-ad-script
    chmod 600 /etc/samba-ad/systemd-resolved.disabled-by-samba-ad-script
    ok "systemd-resolved desativado de forma controlada; porta 53 liberada para o Samba."
}

distro_prepare_dns_port() {
    info "Preparando porta 53 no Ubuntu"

    if [[ ! -e /etc/resolv.conf.pre-samba-ad ]]; then
        cp -a /etc/resolv.conf /etc/resolv.conf.pre-samba-ad 2>/dev/null || true
    fi

    if ubuntu_resolved_is_masked; then
        warn "systemd-resolved já está mascarado; usando resolver estático durante o provisionamento."
        ubuntu_write_resolv_conf "$DNS_FORWARDER"
        local preexisting
        preexisting="$(ubuntu_port53_listeners)"
        if [[ -n "$preexisting" ]]; then
            printf '%s
' "$preexisting" >&2
            die "Porta 53 ocupada por outro serviço antes do provisionamento."
        fi
        return 0
    fi

    if systemctl cat systemd-resolved.service >/dev/null 2>&1; then
        mkdir -p /etc/systemd/resolved.conf.d
        rm -f /etc/systemd/resolved.conf.d/60-samba-ad.conf
        cat >/etc/systemd/resolved.conf.d/99-samba-ad.conf <<EOF
[Resolve]
DNS=${DNS_FORWARDER}
DNSStubListener=no
DNSStubListenerExtra=
EOF

        systemctl enable --now systemd-resolved.service 2>/dev/null || true
        systemctl restart systemd-resolved.service

        # Durante build/provisionamento, consultas devem ir diretamente ao forwarder.
        ubuntu_write_resolv_conf "$DNS_FORWARDER"
        sleep 1

        local listeners other
        listeners="$(ubuntu_port53_listeners)"
        if [[ -z "$listeners" ]]; then
            ok "Stub DNS do systemd-resolved desativado; porta 53 liberada para o Samba."
            return 0
        fi

        other="$(printf '%s
' "$listeners" | grep -Ev 'systemd-resolv' || true)"
        if [[ -n "$other" ]]; then
            printf '%s
' "$listeners" >&2
            die "Porta 53 está ocupada por serviço diferente de systemd-resolved."
        fi

        warn "A configuração efetiva ainda deixou systemd-resolved na porta 53."
        systemd-analyze cat-config systemd/resolved.conf 2>/dev/null | tail -n 120 || true
        ubuntu_disable_systemd_resolved_for_dc "$DNS_FORWARDER"
    else
        warn "systemd-resolved não foi detectado; usando /etc/resolv.conf estático."
        ubuntu_write_resolv_conf "$DNS_FORWARDER"
        local listeners
        listeners="$(ubuntu_port53_listeners)"
        if [[ -n "$listeners" ]]; then
            printf '%s
' "$listeners" >&2
            die "Porta 53 já está ocupada antes do provisionamento."
        fi
    fi
}

distro_enable_network_wait() {
    systemctl enable systemd-networkd-wait-online.service 2>/dev/null || true
    systemctl enable NetworkManager-wait-online.service 2>/dev/null || true
}

distro_configure_resolver_to_self() {
    if systemctl is-active --quiet systemd-resolved.service 2>/dev/null; then
        mkdir -p /etc/systemd/resolved.conf.d
        rm -f /etc/systemd/resolved.conf.d/60-samba-ad.conf
        cat >/etc/systemd/resolved.conf.d/99-samba-ad.conf <<EOF
[Resolve]
DNS=${DC_IP}
Domains=${AD_DNS_DOMAIN}
DNSStubListener=no
DNSStubListenerExtra=
EOF
        systemctl restart systemd-resolved.service
        resolvectl flush-caches 2>/dev/null || true
        sleep 1

        if [[ -n "$(ubuntu_resolved_port53_listeners)" ]]; then
            warn "systemd-resolved voltou a ocupar a porta 53 após configurar o DC como DNS."
            ubuntu_disable_systemd_resolved_for_dc "$DC_IP" "$AD_DNS_DOMAIN"
        fi
    fi

    ubuntu_write_resolv_conf "$DC_IP" "$AD_DNS_DOMAIN"

    if ! grep -Eq "^nameserver[[:space:]]+${DC_IP//./\.}([[:space:]]|$)" /etc/resolv.conf; then
        die "/etc/resolv.conf não aponta para o próprio DC após a configuração."
    fi
}

distro_prepare_ca_anchor() {
    chmod 644 "$1"
}

distro_update_ca_trust() {
    update-ca-certificates >/dev/null
}

distro_prepare_admin_tls_files() {
    chmod 644 "$1"
    chmod 600 "$2"
}

distro_label_ntp_signd() {
    local ntp_dir="$1"
    local profile="/etc/apparmor.d/usr.sbin.chronyd"
    local local_profile="/etc/apparmor.d/local/usr.sbin.chronyd"

    if [[ -f "$profile" ]]; then
        mkdir -p "$(dirname "$local_profile")"
        touch "$local_profile"
        sed -i '/^# BEGIN SAMBA-AD$/,/^# END SAMBA-AD$/d' "$local_profile"
        cat >>"$local_profile" <<EOF

# BEGIN SAMBA-AD
${ntp_dir}/ rw,
${ntp_dir}/** rw,
# END SAMBA-AD
EOF
        if command -v apparmor_parser >/dev/null 2>&1; then
            apparmor_parser -r "$profile" >/dev/null 2>&1 || \
                warn "Não foi possível recarregar o perfil AppArmor do chronyd."
        fi
    fi
}

ufw_preserve_ssh() {
    if command -v sshd >/dev/null 2>&1; then
        local port
        while IFS= read -r port; do
            [[ "$port" =~ ^[0-9]+$ ]] || continue
            ufw allow "${port}/tcp" comment 'SSH preserved by samba-ad-script' >/dev/null
        done < <(sshd -T 2>/dev/null | awk '$1=="port" {print $2}' | sort -nu)
    fi
}

distro_configure_firewall() {
    info "Configurando UFW"

    if grep -Eq '^[[:space:]]*DEFAULT_INPUT_POLICY="?ACCEPT"?' /etc/default/ufw 2>/dev/null; then
        if [[ "$ALLOW_PERMISSIVE_FIREWALL_ZONE" != "1" ]]; then
            die "UFW está com DEFAULT_INPUT_POLICY=ACCEPT. Use política de entrada restritiva ou ALLOW_PERMISSIVE_FIREWALL_ZONE=1 conscientemente."
        fi
        warn "UFW permissivo aceito por autorização explícita."
    fi

    # Se já houver uma regra ampla para portas sensíveis, a regra por CIDR não a
    # tornará mais restritiva. Bloqueamos esse cenário por padrão.
    local broad
    broad="$(ufw status 2>/dev/null | grep -E '(^|[[:space:]])(53|88|123|135|137|138|139|389|445|464|636|3268|3269|80|443|3000|9090)(/tcp|/udp)?[[:space:]]+ALLOW[[:space:]]+Anywhere' || true)"
    if [[ -n "$broad" && "$ALLOW_PERMISSIVE_FIREWALL_ZONE" != "1" ]]; then
        printf '%s\n' "$broad" >&2
        die "UFW possui regras amplas pré-existentes para portas do AD/admin. Remova-as ou use ALLOW_PERMISSIVE_FIREWALL_ZONE=1 após revisão."
    fi

    ufw_preserve_ssh

    local cidr p
    local ad_tcp=(53 88 135 139 389 445 464 636 3268 3269)
    local ad_udp=(53 88 123 137 138 389 464)
    local admin_tcp=(80 443 3000 9090)

    while IFS= read -r cidr; do
        for p in "${ad_tcp[@]}"; do
            ufw allow proto tcp from "$cidr" to any port "$p" comment 'Samba AD' >/dev/null
        done
        for p in "${ad_udp[@]}"; do
            ufw allow proto udp from "$cidr" to any port "$p" comment 'Samba AD' >/dev/null
        done
        ufw allow proto tcp from "$cidr" to any port 49152:65535 comment 'Samba AD RPC' >/dev/null
    done < <(split_csv "$CLIENT_CIDRS")

    while IFS= read -r cidr; do
        for p in "${admin_tcp[@]}"; do
            ufw allow proto tcp from "$cidr" to any port "$p" comment 'Samba AD Admin' >/dev/null
        done
    done < <(split_csv "$MGMT_CIDRS")

    ufw --force enable >/dev/null
    ufw reload >/dev/null
    ufw status verbose
    ok "UFW configurado com regras por CIDR."
}

distro_install_cockpit() {
    info "Instalando Cockpit"
    install_pkg_required cockpit
    systemctl enable --now cockpit.socket
}

distro_install_lam_packages() {
    local packages=(
        apache2 libapache2-mod-php
        php php-cli php-common php-ldap php-xml php-mbstring php-gd php-opcache
        php-gmp php-zip php-intl php-curl
    )
    install_pkg_list_required "${packages[@]}"
}

distro_configure_lam_webserver() {
    local fqdn="$1" cert="$2" key="$3"

    a2enmod ssl >/dev/null
    a2dissite 000-default >/dev/null 2>&1 || true
    a2dissite default-ssl >/dev/null 2>&1 || true

    cat >/etc/apache2/sites-available/samba-ad-lam.conf <<EOF
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
    SSLCertificateFile ${cert}
    SSLCertificateKeyFile ${key}

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

    a2ensite samba-ad-lam >/dev/null

    local php_ver php_ini_dir
    php_ver="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
    php_ini_dir="/etc/php/${php_ver}/apache2/conf.d"
    mkdir -p "$php_ini_dir"
    cat >"${php_ini_dir}/99-lam-security.ini" <<'EOF'
memory_limit = 256M
session.cookie_httponly = 1
session.cookie_secure = 1
session.use_strict_mode = 1
session.cookie_samesite = Lax
expose_php = Off
EOF

    apache2ctl configtest
    systemctl enable --now apache2
    systemctl restart apache2
}

distro_install_monitoring_packages() {
    install_pkg_required prometheus
    install_pkg_required prometheus-node-exporter
}

distro_install_grafana() {
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://apt.grafana.com/gpg.key -o "$WORKDIR/grafana-gpg.key"
    gpg --dearmor --yes -o /etc/apt/keyrings/grafana.gpg "$WORKDIR/grafana-gpg.key"
    chmod 644 /etc/apt/keyrings/grafana.gpg

    cat >/etc/apt/sources.list.d/grafana.list <<'EOF'
deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main
EOF

    apt-get update
    apt_install grafana
}

distro_prepare_grafana_tls_files() {
    :
}

distro_run_extra_tests() {
    local resolved_listeners
    resolved_listeners="$(ubuntu_resolved_port53_listeners)"
    if [[ -n "$resolved_listeners" ]]; then
        printf '%s
' "$resolved_listeners" >&2
        die "systemd-resolved está ocupando a porta 53 após o provisionamento."
    fi

    if ubuntu_resolved_is_masked; then
        systemctl is-active --quiet systemd-resolved.service 2>/dev/null && \
            die "systemd-resolved está ativo apesar de estar mascarado."
        ok "Fallback Ubuntu ativo: systemd-resolved mascarado e fora da porta 53."
    else
        ok "systemd-resolved permanece sem stub na porta 53."
    fi
}

distro_security_summary() {
    local aa="desconhecido"
    local resolver_status
    if systemctl is-active --quiet apparmor.service 2>/dev/null; then
        aa="ativo"
    fi

    if ubuntu_resolved_is_masked; then
        resolver_status="systemd-resolved mascarado pelo fallback controlado; resolver estático"
    else
        resolver_status="systemd-resolved ativo com DNS stub desativado"
    fi

    cat <<EOF
AppArmor:
  O instalador NÃO desativa AppArmor. Estado atual: ${aa}

Resolver Ubuntu:
  ${resolver_status}.
  /etc/resolv.conf aponta para ${DC_IP}.
EOF
}
