#!/usr/bin/env bash
#
# Samba AD Script - installer 0.6.5
#
# Supported:
#   - Rocky Linux 10.x
#   - Ubuntu 22.04 LTS
#   - Ubuntu 24.04 LTS
#
# Ubuntu releases newer than the validated matrix are accepted as experimental.
#
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

INSTALLER_REVISION="0.6.5"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

if [[ "${1:-}" == "--version" || "${1:-}" == "-V" ]]; then
    printf 'samba-ad-script installer %s\n' "$INSTALLER_REVISION"
    exit 0
fi

[[ -r "${LIB_DIR}/common.sh" ]] || {
    printf '[ERRO] Biblioteca não encontrada: %s\n' "${LIB_DIR}/common.sh" >&2
    exit 1
}

# shellcheck source=scripts/lib/common.sh
source "${LIB_DIR}/common.sh"

detect_platform

ADAPTER="${LIB_DIR}/distro-${DISTRO_FAMILY}.sh"
[[ -r "$ADAPTER" ]] || die "Adapter da distribuição não encontrado: $ADAPTER"

# shellcheck source=/dev/null
source "$ADAPTER"
distro_init

if [[ "${1:-}" == "--check-platform" ]]; then
    require_root
    distro_validate_platform
    printf 'Installer     : %s\n' "$INSTALLER_REVISION"
    printf 'Distribution  : %s\n' "$DISTRO_LABEL"
    printf 'Support tier  : %s\n' "$DISTRO_SUPPORT_TIER"
    printf 'Adapter       : %s\n' "$ADAPTER"
    printf 'Firewall      : %s\n' "$FIREWALL_BACKEND"
    printf 'Security MAC  : %s\n' "$SECURITY_FRAMEWORK"
    exit 0
fi

main "$@"
