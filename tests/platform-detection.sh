#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

required_hooks=(
  distro_init
  distro_validate_platform
  install_pkg_required
  install_pkg_list_required
  install_pkg_optional
  distro_enable_repositories
  distro_install_build_dependencies
  distro_get_current_dns
  distro_check_static_ip_hint
  distro_check_security_mode
  distro_check_conflicting_samba_packages
  distro_prepare_dns_port
  distro_enable_network_wait
  distro_configure_resolver_to_self
  distro_prepare_ca_anchor
  distro_update_ca_trust
  distro_prepare_admin_tls_files
  distro_label_ntp_signd
  distro_configure_firewall
  distro_install_cockpit
  distro_install_lam_packages
  distro_configure_lam_webserver
  distro_install_monitoring_packages
  distro_install_grafana
  distro_prepare_grafana_tls_files
  distro_run_extra_tests
  distro_security_summary
)

run_case() {
    local id="$1" version="$2" expected_family="$3" expected_tier="$4"
    local os_file="$TMP/os-${id}-${version//./_}"

    cat >"$os_file" <<EOF
ID=${id}
VERSION_ID="${version}"
EOF

    LOG_DIR="$TMP/log-${id}-${version//./_}" \
    OS_RELEASE_FILE="$os_file" \
    ALLOW_UNTESTED_UBUNTU=1 \
    bash -Eeuo pipefail -c '
        root="$1"
        expected_family="$2"
        expected_tier="$3"

        source "$root/scripts/lib/common.sh"
        detect_platform

        [[ "$DISTRO_FAMILY" == "$expected_family" ]]
        [[ "$DISTRO_SUPPORT_TIER" == "$expected_tier" ]]

        source "$root/scripts/lib/distro-${DISTRO_FAMILY}.sh"
        distro_init
        distro_validate_platform

        shift 3
        for hook in "$@"; do
            declare -F "$hook" >/dev/null
        done

        [[ -n "$DISTRO_LABEL" ]]
        [[ -n "$FIREWALL_BACKEND" ]]
        [[ -n "$SECURITY_FRAMEWORK" ]]
        [[ -n "$WEB_SERVICE" ]]
        [[ -n "$CHRONY_SERVICE" ]]
        [[ -n "$ADMIN_CERT" ]]
        [[ -n "$SYSTEM_CA_BUNDLE" ]]
        [[ -n "$NODE_EXPORTER_SERVICE" ]]
    ' _ "$ROOT" "$expected_family" "$expected_tier" "${required_hooks[@]}"

    printf '[OK] %s %s -> %s/%s\n' "$id" "$version" "$expected_family" "$expected_tier"
}

run_case rocky 10.0 rocky supported
run_case ubuntu 22.04 ubuntu supported
run_case ubuntu 24.04 ubuntu supported
run_case ubuntu 26.04 ubuntu experimental

printf '[OK] platform adapters validated\n'
