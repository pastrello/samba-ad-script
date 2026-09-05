# Rocky Linux 10 adapter for Samba AD Script.
# shellcheck shell=bash

distro_init() {
    DISTRO_LABEL="Rocky Linux ${DISTRO_VERSION}"
    SECURITY_FRAMEWORK="SELinux"
    FIREWALL_BACKEND="firewalld"

    WEB_SERVICE="httpd.service"
    WEB_USER="apache"
    WEB_GROUP="apache"

    CHRONY_SERVICE="chronyd.service"
    CHRONY_CONF="/etc/chrony.conf"
    CHRONY_GROUP="chrony"

    ADMIN_CERT="/etc/pki/tls/certs/samba-ad-admin.crt"
    ADMIN_KEY="/etc/pki/tls/private/samba-ad-admin.key"
    SAMBA_CA_ANCHOR="/etc/pki/ca-trust/source/anchors/samba-ad-local-ca.pem"
    ADMIN_CA_ANCHOR="/etc/pki/ca-trust/source/anchors/samba-ad-admin-local.crt"
    SYSTEM_CA_BUNDLE="/etc/pki/tls/certs/ca-bundle.crt"

    PROMETHEUS_USER="prometheus"
    PROMETHEUS_GROUP="prometheus"
    PROMETHEUS_BIN="/usr/bin/prometheus"
    PROMETHEUS_STOCK_SERVICE="prometheus.service"
    NODE_EXPORTER_SERVICE="node_exporter.service"
    NODE_EXPORTER_BIN="/usr/bin/node_exporter"
    NOLOGIN_SHELL="/sbin/nologin"
}

distro_validate_platform() {
    [[ "$DISTRO_ID" == "rocky" && "${DISTRO_VERSION%%.*}" == "10" ]] || \
        die "Adapter Rocky carregado para plataforma inesperada: ${DISTRO_ID} ${DISTRO_VERSION}"
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

distro_enable_repositories() {
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

distro_install_build_dependencies() {
    info "Instalando dependências para compilar o Samba AD DC no Rocky Linux"

    local required=(
        gcc gcc-c++ make
        python3 python3-devel
        perl perl-ExtUtils-MakeMaker perl-Parse-Yapp
        acl attr
        gnutls-devel zlib-devel flex jansson-devel
        libacl-devel libattr-devel libarchive-devel libblkid-devel
        libtasn1-devel libxml2-devel libxslt-devel lmdb-devel
        pam-devel popt-devel readline-devel systemd-devel
        keyutils-libs-devel libaio-devel openldap-devel rpcgen
        pkgconf-pkg-config
        curl wget tar gzip bzip2 xz zstd util-linux
        gnupg2 openssl logrotate ca-certificates
        krb5-workstation bind-utils chrony firewalld NetworkManager
        rsyslog policycoreutils-python-utils
    )
    install_pkg_list_required "${required[@]}"

    local p
    local optional=(
        gpgme-devel libtasn1-tools docbook-style-xsl
        python3-cryptography python3-dns python3-gpg python3-markdown
        libcap-devel libtirpc-devel rpcsvc-proto-devel dbus-devel
        libicu-devel liburing-devel libunwind-devel
    )
    for p in "${optional[@]}"; do
        install_pkg_optional "$p"
    done
    install_pkg_optional glibc-langpack-pt
}

distro_get_current_dns() {
    local dns=""
    if command -v nmcli >/dev/null 2>&1 && [[ -n "${DC_IFACE:-}" ]]; then
        dns="$(nmcli -g IP4.DNS device show "$DC_IFACE" 2>/dev/null | grep -Ev '^(127\.|::1$)' | head -n1 || true)"
    fi
    if [[ -z "$dns" ]]; then
        dns="$(awk '/^nameserver[[:space:]]+/ {print $2}' /etc/resolv.conf 2>/dev/null \
            | grep -Ev '^(127\.|::1$)' | head -n1 || true)"
    fi
    printf '%s\n' "$dns"
}

distro_check_static_ip_hint() {
    local con
    con="$(nmcli -g GENERAL.CONNECTION device show "$DC_IFACE" 2>/dev/null | head -n1 || true)"
    if [[ -n "$con" && "$con" != "--" ]]; then
        local method
        method="$(nmcli -g ipv4.method connection show "$con" 2>/dev/null || true)"
        if [[ "$method" != "manual" ]]; then
            warn "A conexão NetworkManager '$con' usa ipv4.method=$method."
            warn "Para um AD estável, o endereço $DC_IP deve permanecer fixo."
            [[ "$STRICT_STATIC_IP" != "1" ]] || die "STRICT_STATIC_IP=1 e a conexão não usa ipv4.method=manual."
        else
            ok "IPv4 da conexão NetworkManager está configurado manualmente."
        fi
    fi
}

distro_check_security_mode() {
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

distro_check_conflicting_samba_packages() {
    local rpm_pkg
    for rpm_pkg in samba samba-dc samba-common; do
        if rpm -q "$rpm_pkg" >/dev/null 2>&1; then
            warn "Foi detectado o pacote Samba do sistema: $rpm_pkg"
            die "Use uma instalação limpa ou remova os pacotes Samba do sistema antes de continuar."
        fi
    done
}

distro_prepare_dns_port() {
    : # Rocky normalmente não possui stub local ocupando TCP/UDP 53.
}

distro_enable_network_wait() {
    systemctl enable NetworkManager-wait-online.service 2>/dev/null || true
}

distro_configure_resolver_to_self() {
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
}

distro_prepare_ca_anchor() {
    local f="$1"
    restorecon "$f" 2>/dev/null || true
}

distro_update_ca_trust() {
    update-ca-trust extract
}

distro_prepare_admin_tls_files() {
    restorecon "$1" "$2" 2>/dev/null || true
}

distro_label_ntp_signd() {
    local ntp_dir="$1"
    if command -v semanage >/dev/null 2>&1; then
        semanage fcontext -a -t ntpd_t "${ntp_dir}(/.*)?" 2>/dev/null || \
        semanage fcontext -m -t ntpd_t "${ntp_dir}(/.*)?" 2>/dev/null || true
        restorecon -RF "$ntp_dir" 2>/dev/null || true
    fi
}

distro_configure_firewall() {
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
            die "A interface $DC_IFACE está na zona firewalld '$FIREWALL_ZONE' (target=$zone_target)."
        fi
        warn "Zona firewalld permissiva '$FIREWALL_ZONE' aceita por autorização explícita."
    fi

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

distro_install_cockpit() {
    info "Instalando Cockpit"
    install_pkg_required cockpit
    install_pkg_optional cockpit-storaged
    install_pkg_optional cockpit-selinux
    systemctl enable --now cockpit.socket
}

distro_install_lam_packages() {
    local packages=(
        httpd mod_ssl
        php php-cli php-common php-ldap php-xml php-mbstring php-gd php-opcache
        php-gmp php-pecl-zip php-intl
    )
    install_pkg_list_required "${packages[@]}"
    install_pkg_optional php-curl
    install_pkg_optional php-process
}

distro_configure_lam_webserver() {
    local fqdn="$1" cert="$2" key="$3"

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

    setsebool -P httpd_can_network_connect 1

    if command -v semanage >/dev/null 2>&1; then
        semanage fcontext -a -t httpd_sys_content_t '/var/www/html/lam(/.*)?' 2>/dev/null || \
        semanage fcontext -m -t httpd_sys_content_t '/var/www/html/lam(/.*)?' 2>/dev/null || true
        local d
        for d in config sess tmp; do
            semanage fcontext -a -t httpd_sys_rw_content_t "/var/www/html/lam/${d}(/.*)?" 2>/dev/null || \
            semanage fcontext -m -t httpd_sys_rw_content_t "/var/www/html/lam/${d}(/.*)?" 2>/dev/null || true
        done
        restorecon -RF /var/www/html/lam
    fi

    cat >/etc/php.d/99-lam-security.ini <<'EOF'
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
}

distro_install_monitoring_packages() {
    install_pkg_required prometheus
    install_pkg_required node-exporter
}

distro_install_grafana() {
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
}

distro_prepare_grafana_tls_files() {
    restorecon "$1" "$2" 2>/dev/null || true
}

distro_run_extra_tests() {
    :
}

distro_security_summary() {
    cat <<EOF
SELinux:
  O instalador NÃO desativa SELinux. Modo atual: $(getenforce 2>/dev/null || echo desconhecido)
EOF
}
