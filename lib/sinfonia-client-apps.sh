#!/bin/bash
# Shared helpers for Solfeggio Sinfonia client-app deployment.
#
# Spec format: id@mount[,id@mount...]
#
# Path mode (single Host, URL prefixes):
#   core@/,public@/publicApp/
#   Bare ids also work: core,public  →  core@/,public@/publicApp/
#
# Host mode (one domain per SPA, each at /):
#   dyeus@dyeus.al,core@panel.pronix.al,public@pronix.al
#   Aliases: public@pronix.al|www.pronix.al
#
# Path-mode non-root apps are built with VITE_BASE_PATH matching their URL path.
# Host-mode apps are always built with VITE_BASE_PATH=/.
# Each SPA container always listens on internal port 80.

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

# True when the mount target is a hostname list (not a URL path / legacy port).
is_sinfonia_host_mount() {
    local raw="${1:-}"
    local host
    raw="$(echo "$raw" | tr -d '[:space:]')"
    if [ -z "$raw" ] || [[ "$raw" == /* ]] || [[ "$raw" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    raw="$(echo "$raw" | tr '|' ' ')"
    for host in $raw; do
        [ -n "$host" ] || continue
        if [[ ! "$host" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
            return 1
        fi
        # Require a dot (or localhost) so "publicApp" is not treated as a host.
        if [ "$host" != "localhost" ] && [[ "$host" != *.* ]]; then
            return 1
        fi
    done
    return 0
}

# "pronix.al|www.pronix.al" → "pronix.al www.pronix.al" (nginx server_name)
normalize_sinfonia_hosts() {
    local raw="${1:-}"
    local host
    local -a hosts=()
    raw="$(echo "$raw" | tr -d '[:space:]' | tr '|' ' ')"
    for host in $raw; do
        [ -n "$host" ] || continue
        hosts+=("$host")
    done
    if [ "${#hosts[@]}" -eq 0 ]; then
        return 1
    fi
    echo "${hosts[*]}"
}

sinfonia_app_primary_host() {
    local idx="${1:-0}"
    local hosts="${SINFONIA_APP_HOSTS[$idx]:-}"
    if [ -z "$hosts" ]; then
        echo ""
        return 0
    fi
    echo "${hosts%% *}"
}

# Public URL for app at index $2. Uses domain in host mode, path on localhost in path mode.
sinfonia_app_public_url() {
    local gateway_port="${1:-80}"
    local idx="${2:-0}"
    local path host port_suffix

    if [ "${SINFONIA_GATEWAY_MODE:-path}" = "host" ]; then
        host="$(sinfonia_app_primary_host "$idx")"
        if [ -z "$host" ]; then
            echo "http://localhost:${gateway_port}/"
            return 0
        fi
        if [ "$gateway_port" = "80" ] || [ "$gateway_port" = "443" ]; then
            port_suffix=""
        else
            port_suffix=":${gateway_port}"
        fi
        if [ "$gateway_port" = "443" ]; then
            echo "https://${host}${port_suffix}/"
        else
            echo "http://${host}${port_suffix}/"
        fi
        return 0
    fi

    path="${SINFONIA_APP_PATHS[$idx]:-/}"
    if [ "$path" = "/" ]; then
        echo "http://localhost:${gateway_port}/"
    else
        echo "http://localhost:${gateway_port}${path}"
    fi
}

# Parses SINFONIA_CLIENT_APPS into:
#   SINFONIA_GATEWAY_MODE (path|host)
#   SINFONIA_APP_IDS / SINFONIA_APP_PATHS / SINFONIA_APP_BASE_PATHS / SINFONIA_APP_HOSTS
#   SINFONIA_APP_CONTAINERS / SINFONIA_APP_IMAGES / SINFONIA_APP_UPSTREAMS
parse_sinfonia_client_apps() {
    local raw="${1:-}"
    local entry id mount_raw path hosts mode entry_mode
    local -a entries=()
    local root_count=0
    local i j h primary
    local -a all_hosts=()

    SINFONIA_GATEWAY_MODE="path"
    SINFONIA_APP_IDS=()
    SINFONIA_APP_PATHS=()
    SINFONIA_APP_BASE_PATHS=()
    SINFONIA_APP_HOSTS=()
    SINFONIA_APP_CONTAINERS=()
    SINFONIA_APP_IMAGES=()
    SINFONIA_APP_UPSTREAMS=()

    raw="$(echo "$raw" | tr -d '[:space:]')"
    if [ -z "$raw" ]; then
        raw="core@/"
    fi

    IFS=',' read -r -a entries <<< "$raw"

    # Classify mode from the first explicit mount; bare ids inherit path mode.
    mode=""
    for entry in "${entries[@]}"; do
        [ -n "$entry" ] || continue
        if [[ "$entry" != *"@"* ]]; then
            continue
        fi
        mount_raw="${entry#*@}"
        if is_sinfonia_host_mount "$mount_raw"; then
            mode="host"
        else
            mode="path"
        fi
        break
    done
    mode="${mode:-path}"

    for entry in "${entries[@]}"; do
        [ -n "$entry" ] || continue
        if [[ "$entry" == *"@"* ]]; then
            id="${entry%%@*}"
            mount_raw="${entry#*@}"
        else
            id="$entry"
            mount_raw=""
        fi
        if [ -z "$id" ]; then
            echo "Invalid Sinfonia client app entry: ${entry}" >&2
            return 1
        fi
        if [[ ! "$id" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            echo "Invalid Sinfonia client app id \"${id}\" (use letters, numbers, _ or -)" >&2
            return 1
        fi

        if [ -z "$mount_raw" ]; then
            if [ "$mode" = "host" ]; then
                echo "Host-mode entry \"${id}\" requires a domain (e.g. ${id}@example.com)" >&2
                return 1
            fi
            # Legacy / bare-id path assignment.
            if [ "${#SINFONIA_APP_IDS[@]}" -eq 0 ]; then
                mount_raw="/"
            else
                mount_raw="$(sinfonia_mounted_url_path "$id")"
            fi
        fi

        # Legacy multi-port manifests (id@80,id@8080) → path mode.
        if [[ "$mount_raw" =~ ^[0-9]+$ ]]; then
            if [ "$mode" = "host" ]; then
                echo "Cannot mix legacy port mounts with host mode (entry: ${entry})" >&2
                return 1
            fi
            if [ "${#SINFONIA_APP_IDS[@]}" -eq 0 ]; then
                mount_raw="/"
            else
                mount_raw="$(sinfonia_mounted_url_path "$id")"
            fi
        fi

        if is_sinfonia_host_mount "$mount_raw"; then
            entry_mode="host"
        else
            entry_mode="path"
        fi
        if [ "$entry_mode" != "$mode" ]; then
            echo "Cannot mix path mounts and domain mounts in SINFONIA_CLIENT_APPS (entry: ${entry})" >&2
            return 1
        fi

        if [ "$mode" = "host" ]; then
            if ! hosts="$(normalize_sinfonia_hosts "$mount_raw")"; then
                echo "Invalid domain list for \"${id}\": ${mount_raw}" >&2
                return 1
            fi
            path="/"
            SINFONIA_APP_IDS+=("$id")
            SINFONIA_APP_PATHS+=("$path")
            SINFONIA_APP_BASE_PATHS+=("/")
            SINFONIA_APP_HOSTS+=("$hosts")
        else
            path="$(normalize_sinfonia_url_path "$mount_raw")"
            SINFONIA_APP_IDS+=("$id")
            SINFONIA_APP_PATHS+=("$path")
            SINFONIA_APP_BASE_PATHS+=("$path")
            SINFONIA_APP_HOSTS+=("")
        fi

        SINFONIA_APP_CONTAINERS+=("$(sinfonia_frontend_container "$id")")
        SINFONIA_APP_IMAGES+=("$(sinfonia_frontend_image "$id")")
        SINFONIA_APP_UPSTREAMS+=("$(sinfonia_frontend_upstream "$id")")
    done

    if [ "${#SINFONIA_APP_IDS[@]}" -eq 0 ]; then
        echo "At least one Sinfonia client app is required" >&2
        return 1
    fi

    SINFONIA_GATEWAY_MODE="$mode"

    for i in "${!SINFONIA_APP_IDS[@]}"; do
        if [ "${SINFONIA_APP_PATHS[$i]}" = "/" ]; then
            root_count=$((root_count + 1))
        fi
        for j in "${!SINFONIA_APP_IDS[@]}"; do
            if [ "$i" -lt "$j" ] && [ "${SINFONIA_APP_IDS[$i]}" = "${SINFONIA_APP_IDS[$j]}" ]; then
                echo "Duplicate Sinfonia client app id: ${SINFONIA_APP_IDS[$i]}" >&2
                return 1
            fi
        done
    done

    if [ "$mode" = "path" ]; then
        for i in "${!SINFONIA_APP_IDS[@]}"; do
            for j in "${!SINFONIA_APP_IDS[@]}"; do
                if [ "$i" -lt "$j" ] && [ "${SINFONIA_APP_PATHS[$i]}" = "${SINFONIA_APP_PATHS[$j]}" ]; then
                    echo "Duplicate URL path ${SINFONIA_APP_PATHS[$i]} for Sinfonia clients" >&2
                    return 1
                fi
            done
        done
        if [ "$root_count" -ne 1 ]; then
            echo "Exactly one Sinfonia client must be mounted at / (found ${root_count})" >&2
            return 1
        fi
    else
        for i in "${!SINFONIA_APP_IDS[@]}"; do
            for h in ${SINFONIA_APP_HOSTS[$i]}; do
                for primary in "${all_hosts[@]+"${all_hosts[@]}"}"; do
                    if [ "$primary" = "$h" ]; then
                        echo "Duplicate domain \"${h}\" for Sinfonia clients" >&2
                        return 1
                    fi
                done
                all_hosts+=("$h")
            done
        done
    fi

    return 0
}

build_sinfonia_client_apps_spec() {
    local i
    local parts=()
    local mount
    for i in "${!SINFONIA_APP_IDS[@]}"; do
        if [ "${SINFONIA_GATEWAY_MODE:-path}" = "host" ]; then
            mount="$(echo "${SINFONIA_APP_HOSTS[$i]}" | tr ' ' '|')"
            parts+=("${SINFONIA_APP_IDS[$i]}@${mount}")
        else
            parts+=("${SINFONIA_APP_IDS[$i]}@${SINFONIA_APP_PATHS[$i]}")
        fi
    done
    local IFS=,
    echo "${parts[*]}"
}

# Builds path-mode "id@path,..." — first id at `/`, remaining at `/${id}App/`.
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

# Normalize user input into a full SINFONIA_CLIENT_APPS spec.
# Accepts bare ids (path mode), full path mounts, or domain mounts.
normalize_sinfonia_client_apps_input() {
    local raw="${1:-}"
    local entry id mount_raw
    local -a entries=()
    local has_at=false
    local mode=""

    raw="$(echo "$raw" | tr -d '[:space:]')"
    if [ -z "$raw" ]; then
        echo "core@/"
        return 0
    fi

    IFS=',' read -r -a entries <<< "$raw"
    for entry in "${entries[@]}"; do
        [ -n "$entry" ] || continue
        if [[ "$entry" == *"@"* ]]; then
            has_at=true
            mount_raw="${entry#*@}"
            if is_sinfonia_host_mount "$mount_raw"; then
                mode="host"
            elif [ -z "$mode" ]; then
                mode="path"
            fi
        fi
    done

    if [ "$has_at" = false ]; then
        build_sinfonia_client_apps_spec_from_ids "$raw"
        return 0
    fi

    # Already a full spec (path or host) — return as-is for parse_sinfonia_client_apps.
    echo "$raw"
}

write_sinfonia_apps_manifest() {
    local dest_dir=$1
    local replicas=${2:-1}
    local gateway_port=${3:-80}
    local env_file="${dest_dir}/sinfonia-apps.env"
    local json_file="${dest_dir}/sinfonia-apps.manifest.json"
    local i first=true
    local spec host_json

    mkdir -p "$dest_dir"
    spec="$(build_sinfonia_client_apps_spec)"

    {
        echo "SINFONIA_CLIENT_APPS=${spec}"
        echo "SINFONIA_GATEWAY_MODE=${SINFONIA_GATEWAY_MODE:-path}"
        echo "SINFONIA_FRONTEND_REPLICAS=${replicas}"
        echo "NGINX_EXTERNAL_PORT=${gateway_port}"
    } > "$env_file"

    {
        echo "{"
        echo "  \"mode\": \"${SINFONIA_GATEWAY_MODE:-path}\","
        echo "  \"replicas\": ${replicas},"
        echo "  \"gatewayExternalPort\": ${gateway_port},"
        echo "  \"apps\": ["
        for i in "${!SINFONIA_APP_IDS[@]}"; do
            if [ "$first" = true ]; then
                first=false
            else
                echo ","
            fi
            host_json="${SINFONIA_APP_HOSTS[$i]}"
            host_json="${host_json//\"/\\\"}"
            printf '    {
      "id": "%s",
      "path": "%s",
      "basePath": "%s",
      "hosts": "%s",
      "container": "%s",
      "image": "%s",
      "upstream": "%s"
    }' \
                "${SINFONIA_APP_IDS[$i]}" \
                "${SINFONIA_APP_PATHS[$i]}" \
                "${SINFONIA_APP_BASE_PATHS[$i]}" \
                "$host_json" \
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

# Resolve `src/modules/<module>/apps/<appId>/index.html` for a client id.
# Args: sinfonia_root app_id
# Prints the absolute index.html path on stdout; returns 1 if not found / duplicate.
resolve_sinfonia_app_index_html() {
    local sinfonia_root=$1
    local app_id=$2
    local modules_dir="${sinfonia_root}/src/modules"
    local module_dir apps_dir app_root index_html
    local -a matches=()

    if [ -z "$app_id" ] || [ ! -d "$modules_dir" ]; then
        return 1
    fi

    for module_dir in "$modules_dir"/*/; do
        [ -d "$module_dir" ] || continue
        apps_dir="${module_dir}apps"
        app_root="${apps_dir}/${app_id}"
        index_html="${app_root}/index.html"
        if [ -d "$app_root" ] && [ -f "$index_html" ]; then
            matches+=("$index_html")
        fi
    done

    if [ "${#matches[@]}" -eq 0 ]; then
        return 1
    fi
    if [ "${#matches[@]}" -gt 1 ]; then
        echo "Duplicate Sinfonia client \"${app_id}\" under src/modules/*/apps/:" >&2
        local m
        for m in "${matches[@]}"; do
            echo "  - ${m}" >&2
        done
        return 1
    fi

    echo "${matches[0]}"
    return 0
}

# Discover Vite clients at `src/modules/<module>/apps/<appId>/index.html`.
# Args: sinfonia_root (directory containing src/modules)
# Prints comma-separated app ids (sorted).
discover_sinfonia_app_ids() {
    local sinfonia_root=$1
    local modules_dir="${sinfonia_root}/src/modules"
    local module_dir apps_dir app_dir name index_html existing
    local -a found=()

    if [ ! -d "$modules_dir" ]; then
        echo ""
        return 0
    fi

    for module_dir in "$modules_dir"/*/; do
        [ -d "$module_dir" ] || continue
        apps_dir="${module_dir}apps"
        [ -d "$apps_dir" ] || continue
        for app_dir in "$apps_dir"/*/; do
            [ -d "$app_dir" ] || continue
            name="$(basename "$app_dir")"
            index_html="${app_dir}index.html"
            [ -f "$index_html" ] || continue
            for existing in "${found[@]+"${found[@]}"}"; do
                if [ "$existing" = "$name" ]; then
                    echo "Duplicate Sinfonia client \"${name}\" under src/modules/*/apps/" >&2
                    return 1
                fi
            done
            found+=("$name")
        done
    done

    if [ "${#found[@]}" -eq 0 ]; then
        echo ""
        return 0
    fi

    # Stable, sorted output for prompts/defaults.
    printf '%s\n' "${found[@]}" | LC_ALL=C sort | paste -sd, -
}
