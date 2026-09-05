#!/usr/bin/env bash
set -Eeuo pipefail
f="scripts/lib/distro-ubuntu.sh"
grep -q '99-samba-ad.conf' "$f"
grep -q 'DNSStubListener=no' "$f"
grep -q 'DNSStubListenerExtra=' "$f"
grep -q 'systemctl mask --now systemd-resolved.service' "$f"
grep -q 'ubuntu_port53_listeners' "$f"
grep -q 'systemd-resolved.disabled-by-samba-ad-script' "$f"
echo '[OK] Ubuntu resolver fallback contract validated'
