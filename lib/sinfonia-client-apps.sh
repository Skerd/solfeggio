#!/bin/bash
# Shared helpers for Solfeggio Sinfonia client-app deployment (path-based gateway).
# Spec format: id@urlPath[,id@urlPath...]
# Example: core@/,public@/publicApp/
#
# First listed app is served at `/` on the gateway; every other app at `/${id}App/`.
# Each SPA container always listens on internal port 80.
# Non-root apps are built with VITE_BASE_PATH matching their URL path.
# Gateway strips the path prefix when proxying to those containers.

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

# Mounted (non-root) clients use /{id}App/ — e.g. public -> /publicApp/, foo -> /fooApp/.
sinfonia_mounted_url_path() {
    local id="$1"
    local slug
    slug="$(echo "$id" | tr '[:upper:]' '[:lower:]')"
    echo "/${slug}App/"
}

normalize_sinfonia_url_path() {
    local raw="${1:-/}"
    raw="$(echo "$raw" | tr -d '[:space:]')"
    if [ -z "$raw" ] || [ "$raw" = "/" ]; then
        echo "/"
        return 0
    fi
    raw="${raw#/}"
    raw="${raw%/}"
    echo "/${raw}/"
}

sinfonia_app_public_url() {
    local gateway_port="${1:-80}"
    local url_path="$2"
    if [ "$url_path" = "/" ]; then
        echo "http://localhost:${gateway_port}/"
    else
        echo "http://localhost:${gateway_port}${url_path}"
    fi
}

# Parses SINFONIA_CLIENT_APPS into:
#   SINFONIA_APP_IDS / SINFONIA_APP_PATHS / SINFONIA_APP_BASE_PATHS
#   SINFONIA_APP_CONTAINERS / SINFONIA_APP_IMAGES / SINFONIA_APP_UPSTREAMS
parse_sinfonia_client_apps() {
    local raw="${1:-}"
    local entry id path_raw path
    local -a entries=()
    local root_count=0

    SINFONIA_APP_IDS=()
    SINFONIA_APP_PATHS=()
    SINFONIA_APP_BASE_PATHS=()
    SINFONIA_APP_CONTAINERS=()
    SINFONIA_APP_IMAGES=()
    SINFONIA_APP_UPSTREAMS=()

    raw="$(echo "$raw" | tr -d '[:space:]')"
    if [ -z "$raw" ]; then
        raw="core@/"
    fi

    IFS=',' read -r -a entries <<< "$raw"
    for entry in "${entries[@]}"; do
        [ -n "$entry" ] || continue
        if [[ "$entry" == *"@"* ]]; then
            id="${entry%%@*}"
            path_raw="${entry#*@}"
        else
            id="$entry"
            path_raw=""
        fi
        if [ -z "$id" ]; then
            echo "Invalid Sinfonia client app entry: ${entry}" >&2
            return 1
        fi
        if [[ ! "$id" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            echo "Invalid Sinfonia client app id \"${id}\" (use letters, numbers, _ or -)" >&2
            return 1
        fi

        # Legacy multi-port manifests (id@80,id@8080) → migrate to path mode.
        if [[ "$path_raw" =~ ^[0-9]+$ ]]; then
            if [ "${#SINFONIA_APP_IDS[@]}" -eq 0 ]; then
                path_raw="/"
            else
                path_raw="$(sinfonia_mounted_url_path "$id")"
            fi
        fi

        if [ -z "$path_raw" ]; then
            if [ "${#SINFONIA_APP_IDS[@]}" -eq 0 ]; then
                path_raw="/"
            else
                path_raw="$(sinfonia_mounted_url_path "$id")"
            fi
        fi

        path="$(normalize_sinfonia_url_path "$path_raw")"

        SINFONIA_APP_IDS+=("$id")
        SINFONIA_APP_PATHS+=("$path")
        SINFONIA_APP_BASE_PATHS+=("$path")
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
        if [ "${SINFONIA_APP_PATHS[$i]}" = "/" ]; then
            root_count=$((root_count + 1))
        fi
        for j in "${!SINFONIA_APP_IDS[@]}"; do
            if [ "$i" -lt "$j" ]; then
                if [ "${SINFONIA_APP_IDS[$i]}" = "${SINFONIA_APP_IDS[$j]}" ]; then
                    echo "Duplicate Sinfonia client app id: ${SINFONIA_APP_IDS[$i]}" >&2
                    return 1
                fi
                if [ "${SINFONIA_APP_PATHS[$i]}" = "${SINFONIA_APP_PATHS[$j]}" ]; then
                    echo "Duplicate URL path ${SINFONIA_APP_PATHS[$i]} for Sinfonia clients" >&2
                    return 1
                fi
            fi
        done
    done

    if [ "$root_count" -ne 1 ]; then
        echo "Exactly one Sinfonia client must be mounted at / (found ${root_count})" >&2
        return 1
    fi

    return 0
}

build_sinfonia_client_apps_spec() {
    local i
    local parts=()
    for i in "${!SINFONIA_APP_IDS[@]}"; do
        parts+=("${SINFONIA_APP_IDS[$i]}@${SINFONIA_APP_PATHS[$i]}")
    done
    local IFS=,
    echo "${parts[*]}"
}

# Builds "id@path,..." — first id at `/`, remaining at `/${id}App/`.
build_sinfonia_client_apps_spec_from_ids() {
    local ids_csv=$1
    local -a ids=()
    local i
    local parts=()

    IFS=',' read -r -a ids <<< "$(echo "$ids_csv" | tr -d '[:space:]')"
    for i in "${!ids[@]}"; do
        [ -n "${ids[$i]}" ] || continue
        if [ "${#parts[@]}" -eq 0 ]; then
            parts+=("${ids[$i]}@/")
        else
            parts+=("${ids[$i]}@$(sinfonia_mounted_url_path "${ids[$i]}")")
        fi
    done

    local IFS=,
    echo "${parts[*]}"
}

write_sinfonia_apps_manifest() {
    local dest_dir=$1
    local replicas=${2:-1}
    local gateway_port=${3:-80}
    local env_file="${dest_dir}/sinfonia-apps.env"
    local json_file="${dest_dir}/sinfonia-apps.manifest.json"
    local i first=true
    local spec

    mkdir -p "$dest_dir"
    spec="$(build_sinfonia_client_apps_spec)"

    {
        echo "SINFONIA_CLIENT_APPS=${spec}"
        echo "SINFONIA_FRONTEND_REPLICAS=${replicas}"
        echo "NGINX_EXTERNAL_PORT=${gateway_port}"
    } > "$env_file"

    {
        echo "{"
        echo "  \"replicas\": ${replicas},"
        echo "  \"gatewayExternalPort\": ${gateway_port},"
        echo "  \"apps\": ["
        for i in "${!SINFONIA_APP_IDS[@]}"; do
            if [ "$first" = true ]; then
                first=false
            else
                echo ","
            fi
            printf '    {
      "id": "%s",
      "path": "%s",
      "basePath": "%s",
      "container": "%s",
      "image": "%s",
      "upstream": "%s"
    }' \
                "${SINFONIA_APP_IDS[$i]}" \
                "${SINFONIA_APP_PATHS[$i]}" \
                "${SINFONIA_APP_BASE_PATHS[$i]}" \
                "${SINFONIA_APP_CONTAINERS[$i]}" \
                "${SINFONIA_APP_IMAGES[$i]}" \
                "${SINFONIA_APP_UPSTREAMS[$i]}"
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
    NGINX_EXTERNAL_PORT="${NGINX_EXTERNAL_PORT:-80}"
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
