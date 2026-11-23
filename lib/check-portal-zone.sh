#!/usr/bin/env bash
# Checks the portal zone on a real server (P23.0): the apex and a made-up company subdomain resolve, their TLS
# certificate is valid, and the gateway hands both to the portal (its robots.txt comes from Maestro, D181). With a
# company's site slug, also checks that its site answers as that company: what `core.siteHostProbe` checks before it
# marks a new company's site online.
#
# Usage: lib/check-portal-zone.sh <root-domain> [company-site-slug]
#   e.g. lib/check-portal-zone.sh arpeggio.al adriatic-drive
set -u

root=${1:?usage: lib/check-portal-zone.sh <root-domain> [company-site-slug]}
slug=${2:-}
probe="zone-check-${RANDOM}${RANDOM}"
failed=0

resolve() {
    if command -v dig >/dev/null 2>&1; then
        dig +short "$1" A "$1" AAAA | grep -E '^[0-9a-fA-F.:]+$' | head -1
    else
        host "$1" 2>/dev/null | awk '/has (IPv6 )?address/ {print $NF; exit}'
    fi
}

check_host() {
    local host=$1 label=$2 address answer
    address=$(resolve "$host")
    if [ -z "$address" ]; then
        echo "✖ ${label}: ${host} does not resolve: add the DNS record (A/AAAA or CNAME to the gateway)"
        failed=1
        return
    fi
    # curl refuses an invalid or wrong-name certificate, so an answer means TLS is right for this host.
    if ! answer=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 20 "https://${host}/robots.txt" 2>&1); then
        echo "✖ ${label}: ${host} → ${address}, but HTTPS failed: ${answer}"
        failed=1
        return
    fi
    if [ "$answer" != "200" ]; then
        echo "✖ ${label}: ${host} → ${address}, TLS valid, but robots.txt answered ${answer} (is this host on the portal client's server_name?)"
        failed=1
        return
    fi
    echo "✔ ${label}: ${host} → ${address}, TLS valid, the portal answered"
}

check_host "$root" "apex"
check_host "${probe}.${root}" "any company site (wildcard)"

if [ -n "$slug" ]; then
    site="https://${slug}.${root}"
    served=$(curl -sS --max-time 20 -X POST "${site}/api/portal/site" \
        -H "Origin: ${site}" -H "Content-Type: application/json" -H "x-device-id: zone-check" -H "language: en-US" \
        -d '{}' 2>&1 | grep -o '"slug":"[^"]*"' | head -1)
    if [ "$served" = "\"slug\":\"${slug}\"" ]; then
        echo "✔ ${slug}.${root} answers as that company: its site goes online at the next site probe"
    else
        echo "✖ ${slug}.${root} did not answer as that company (got: ${served:-nothing})"
        failed=1
    fi
fi

exit "$failed"
