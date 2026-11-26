#!/bin/bash
# Removes the published host ports from already generated cluster compose files
# and recreates only the containers whose file changed. Volumes are kept.
#
# Usage: lib/remove-cluster-ports.sh [cluster ...]   (default: kafka redis clamv ollama)

set -euo pipefail

CLUSTERS_DIR="$(cd "$(dirname "$0")/../clusters" && pwd)"
CLUSTERS=("$@")
[ ${#CLUSTERS[@]} -eq 0 ] && CLUSTERS=(kafka redis clamv ollama)

compose() {
    if docker compose version >/dev/null 2>&1; then docker compose "$@"; else docker-compose "$@"; fi
}

for cluster in "${CLUSTERS[@]}"; do
    file="${CLUSTERS_DIR}/${cluster}/docker-compose.yml"
    if [ ! -f "$file" ]; then
        echo "[skip] ${cluster}: no docker-compose.yml"
        continue
    fi
    if ! grep -qE '^    ports:' "$file"; then
        echo "[ok]   ${cluster}: no published ports"
        continue
    fi

    cp "$file" "${file}.bak-ports"
    # Drop each service's "ports:" line and everything indented under it.
    awk '
        /^    ports:[[:space:]]*$/ { skip = 1; next }
        skip && /^      / { next }
        { skip = 0; print }
    ' "${file}.bak-ports" > "$file"

    echo "[edit] ${cluster}: ports removed (backup: ${file}.bak-ports)"
    (cd "${CLUSTERS_DIR}/${cluster}" && compose up -d)
done

echo ""
echo "Published ports now:"
docker ps --format '{{.Names}}\t{{.Ports}}' | grep -E '^(kafka|redis|clamav|ollama)' || true
