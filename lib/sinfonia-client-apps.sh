#!/bin/bash
# Shared helpers for Solfeggio Sinfonia client-app deployment.
# Spec format: id@externalPort[,id@externalPort...]
# Example: core@80,public@8080
#
# Each SPA container always serves on internal port 80.
# Nginx listens on externalPort (same value as host publish) and proxies to frontend-<id>:80.

sinfonia_frontend_container() {
    echo "frontend-$1"
}

sinfonia_frontend_image() {
    local prefix="${ARPEGGIO_FRONTEND_IMAGE_PREFIX:-arpeggio-frontend}"
    echo "${prefix}-$1:latest"
}

sinfonia_frontend_upstream() {
    # Nginx upstream names: [a-zA-Z0-9_]
    echo "frontend_$(echo "$1" | tr '-' '_')"
}

# Parses SINFONIA_CLIENT_APPS into parallel arrays:
#   SINFONIA_APP_IDS / SINFONIA_APP_EXTERNAL_PORTS / SINFONIA_APP_LISTEN_PORTS
#   SINFONIA_APP_CONTAINERS / SINFONIA_APP_IMAGES / SINFONIA_APP_UPSTREAMS
parse_sinfonia_client_apps() {
    local raw="${1:-}"
    local entry id port
    local -a entries=()

    SINFONIA_APP_IDS=()
    SINFONIA_APP_EXTERNAL_PORTS=()
    SINFONIA_APP_LISTEN_PORTS=()
    SINFONIA_APP_CONTAINERS=()
    SINFONIA_APP_IMAGES=()
    SINFONIA_APP_UPSTREAMS=()

    raw="$(echo "$raw" | tr -d '[:space:]')"
    if [ -z "$raw" ]; then
        raw="core@80"
    fi

    IFS=',' read -r -a entries <<< "$raw"
    for entry in "${entries[@]}"; do
        [ -n "$entry" ] || continue
        if [[ "$entry" == *"@"* ]]; then
            id="${entry%%@*}"
            port="${entry#*@}"
        else
            id="$entry"
            port=""
        fi
        if [ -z "$id" ]; then
            echo "Invalid Sinfonia client app entry: ${entry}" >&2
            return 1
        fi
        if [[ ! "$id" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            echo "Invalid Sinfonia client app id \"${id}\" (use letters, numbers, _ or -)" >&2
            return 1
        fi
        if [ -z "$port" ]; then
            echo "Missing external port for Sinfonia client app \"${id}\" (expected id@port)" >&2
            return 1
        fi
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -gt 65535 ]; then
            echo "Invalid port \"${port}\" for Sinfonia client app \"${id}\"" >&2
            return 1
        fi

        SINFONIA_APP_IDS+=("$id")
        SINFONIA_APP_EXTERNAL_PORTS+=("$port")
        SINFONIA_APP_LISTEN_PORTS+=("$port")
        SINFONIA_APP_CONTAINERS+=("$(sinfonia_frontend_container "$id")")
        SINFONIA_APP_IMAGES+=("$(sinfonia_frontend_image "$id")")
        SINFONIA_APP_UPSTREAMS+=("$(sinfonia_frontend_upstream "$id")")
    done

    if [ "${#SINFONIA_APP_IDS[@]}" -eq 0 ]; then
        echo "At least one Sinfonia client app is required" >&2
        return 1
    fi

    local i j
    for i in "${!SINFONIA_APP_IDS[@]}"; do
        for j in "${!SINFONIA_APP_IDS[@]}"; do
            if [ "$i" -lt "$j" ]; then
                if [ "${SINFONIA_APP_IDS[$i]}" = "${SINFONIA_APP_IDS[$j]}" ]; then
                    echo "Duplicate Sinfonia client app id: ${SINFONIA_APP_IDS[$i]}" >&2
                    return 1
                fi
                if [ "${SINFONIA_APP_EXTERNAL_PORTS[$i]}" = "${SINFONIA_APP_EXTERNAL_PORTS[$j]}" ]; then
                    echo "Duplicate external port ${SINFONIA_APP_EXTERNAL_PORTS[$i]} for Sinfonia clients" >&2
                    return 1
                fi
            fi
        done
    done

    return 0
}

build_sinfonia_client_apps_spec() {
    local i
    local parts=()
    for i in "${!SINFONIA_APP_IDS[@]}"; do
        parts+=("${SINFONIA_APP_IDS[$i]}@${SINFONIA_APP_EXTERNAL_PORTS[$i]}")
    done
    local IFS=,
    echo "${parts[*]}"
}

# Builds "id@port,..." from comma-separated ids + first/extra base ports.
# First id -> first_port; additional ids -> extra_base, extra_base+1, ...
build_sinfonia_client_apps_spec_from_ids() {
    local ids_csv=$1
    local first_port=$2
    local extra_base=$3
    local -a ids=()
    local i port
    local parts=()
    local extra_index=0

    IFS=',' read -r -a ids <<< "$(echo "$ids_csv" | tr -d '[:space:]')"
    for i in "${!ids[@]}"; do
        [ -n "${ids[$i]}" ] || continue
        if [ "${#parts[@]}" -eq 0 ]; then
            port="$first_port"
        else
            port=$((extra_base + extra_index))
            extra_index=$((extra_index + 1))
        fi
        parts+=("${ids[$i]}@${port}")
    done

    local IFS=,
    echo "${parts[*]}"
}

write_sinfonia_apps_manifest() {
    local dest_dir=$1
    local replicas=${2:-1}
    local env_file="${dest_dir}/sinfonia-apps.env"
    local json_file="${dest_dir}/sinfonia-apps.manifest.json"
    local i first=true
    local spec

    mkdir -p "$dest_dir"
    spec="$(build_sinfonia_client_apps_spec)"

    {
        echo "SINFONIA_CLIENT_APPS=${spec}"
        echo "SINFONIA_FRONTEND_REPLICAS=${replicas}"
    } > "$env_file"

    {
        echo "{"
        echo "  \"replicas\": ${replicas},"
        echo "  \"apps\": ["
        for i in "${!SINFONIA_APP_IDS[@]}"; do
            if [ "$first" = true ]; then
                first=false
            else
                echo ","
            fi
            printf '    {
      "id": "%s",
      "container": "%s",
      "image": "%s",
      "upstream": "%s",
      "externalBasePort": %s,
      "listenPort": %s
    }' \
                "${SINFONIA_APP_IDS[$i]}" \
                "${SINFONIA_APP_CONTAINERS[$i]}" \
                "${SINFONIA_APP_IMAGES[$i]}" \
                "${SINFONIA_APP_UPSTREAMS[$i]}" \
                "${SINFONIA_APP_EXTERNAL_PORTS[$i]}" \
                "${SINFONIA_APP_LISTEN_PORTS[$i]}"
        done
        echo ""
        echo "  ]"
        echo "}"
    } > "$json_file"

    echo "$env_file"
}

load_sinfonia_apps_manifest() {
    local env_file=$1
    local replicas

    if [ ! -f "$env_file" ]; then
        return 1
    fi

    # shellcheck disable=SC1090
    set -a
    # shellcheck disable=SC1091
    source "$env_file"
    set +a

    parse_sinfonia_client_apps "${SINFONIA_CLIENT_APPS:-}" || return 1
    replicas="${SINFONIA_FRONTEND_REPLICAS:-1}"
    SINFONIA_FRONTEND_REPLICAS="$replicas"
    return 0
}

discover_sinfonia_app_ids() {
    local apps_dir=$1
    local dir name
    local -a found=()

    if [ ! -d "$apps_dir" ]; then
        echo ""
        return 0
    fi

    for dir in "$apps_dir"/*/; do
        [ -d "$dir" ] || continue
        name="$(basename "$dir")"
        if [ -f "${dir}index.html" ]; then
            found+=("$name")
        fi
    done

    local IFS=,
    echo "${found[*]}"
}
