#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/sinfonia-client-apps.sh
source "${SCRIPT_DIR}/../../lib/sinfonia-client-apps.sh"
# shellcheck source=../../lib/instances.sh
source "${SCRIPT_DIR}/../../lib/instances.sh"
MAESTRO_ENV_FILE="${MAESTRO_ENV_FILE:-${SCRIPT_DIR}/../../apps/maestro/.env}"

# Values exported by deploy.sh must win over stale keys in clusters/nginx/.env.
_PRESERVED_SINFONIA_CLIENT_APPS="${SINFONIA_CLIENT_APPS-}"
_PRESERVED_SINFONIA_FRONTEND_REPLICAS="${SINFONIA_FRONTEND_REPLICAS-}"
_PRESERVED_NGINX_NUM_NODES="${NGINX_NUM_NODES-}"
_PRESERVED_NGINX_NUM_FRONTEND_BACKENDS="${NGINX_NUM_FRONTEND_BACKENDS-}"
_PRESERVED_NGINX_NUM_API_BACKENDS="${NGINX_NUM_API_BACKENDS-}"
_PRESERVED_NGINX_NUM_WEBSOCKET_BACKENDS="${NGINX_NUM_WEBSOCKET_BACKENDS-}"
_PRESERVED_NGINX_EXTERNAL_PORT="${NGINX_EXTERNAL_PORT-}"

read_env_value_from_file() {
    local file="$1"
    local key="$2"

    strip_env_quotes "$(grep -E "^${key}=" "$file" 2>/dev/null | head -1 | cut -d= -f2-)"
}

load_maestro_upstream_ports() {
    local maestro_api_port maestro_ws_port

    if [ ! -f "$MAESTRO_ENV_FILE" ]; then
        print_warning "Maestro env file not found at ${MAESTRO_ENV_FILE}. Using default API/WebSocket ports."
        return 0
    fi

    maestro_api_port="$(read_env_value_from_file "$MAESTRO_ENV_FILE" "SERVER_PORT")"
    maestro_ws_port="$(read_env_value_from_file "$MAESTRO_ENV_FILE" "WEBSOCKET_PORT")"

    if [ -n "$maestro_api_port" ]; then
        API_UPSTREAM_PORT="$maestro_api_port"
    fi

    if [ -n "$maestro_ws_port" ]; then
        WEBSOCKET_UPSTREAM_PORT="$maestro_ws_port"
    fi

    print_status "API/WebSocket upstream ports loaded from ${MAESTRO_ENV_FILE}"
    print_status "API upstream port: ${API_UPSTREAM_PORT}"
    print_status "WebSocket upstream port: ${WEBSOCKET_UPSTREAM_PORT}"
}

if [ -f .env ]; then
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
    print_status "Loaded environment variables from .env file"
else
    print_warning ".env file not found. Using built-in defaults for Nginx configuration."
fi

if [ -n "${_PRESERVED_SINFONIA_CLIENT_APPS}" ]; then
    SINFONIA_CLIENT_APPS="${_PRESERVED_SINFONIA_CLIENT_APPS}"
fi
if [ -n "${_PRESERVED_SINFONIA_FRONTEND_REPLICAS}" ]; then
    SINFONIA_FRONTEND_REPLICAS="${_PRESERVED_SINFONIA_FRONTEND_REPLICAS}"
fi
if [ -n "${_PRESERVED_NGINX_NUM_NODES}" ]; then
    NGINX_NUM_NODES="${_PRESERVED_NGINX_NUM_NODES}"
fi
if [ -n "${_PRESERVED_NGINX_NUM_FRONTEND_BACKENDS}" ]; then
    NGINX_NUM_FRONTEND_BACKENDS="${_PRESERVED_NGINX_NUM_FRONTEND_BACKENDS}"
fi
if [ -n "${_PRESERVED_NGINX_NUM_API_BACKENDS}" ]; then
    NGINX_NUM_API_BACKENDS="${_PRESERVED_NGINX_NUM_API_BACKENDS}"
fi
if [ -n "${_PRESERVED_NGINX_NUM_WEBSOCKET_BACKENDS}" ]; then
    NGINX_NUM_WEBSOCKET_BACKENDS="${_PRESERVED_NGINX_NUM_WEBSOCKET_BACKENDS}"
fi
if [ -n "${_PRESERVED_NGINX_EXTERNAL_PORT}" ]; then
    NGINX_EXTERNAL_PORT="${_PRESERVED_NGINX_EXTERNAL_PORT}"
fi

NGINX_IMAGE="${NGINX_IMAGE:-nginx:1.27-alpine}"
NGINX_EXTERNAL_PORT="${NGINX_EXTERNAL_PORT:-80}"
API_UPSTREAM_HOST="${API_UPSTREAM_HOST:-maestroApi}"
API_UPSTREAM_PORT="${API_UPSTREAM_PORT:-81}"
WEBSOCKET_UPSTREAM_HOST="${WEBSOCKET_UPSTREAM_HOST:-maestroWebsocket}"
WEBSOCKET_UPSTREAM_PORT="${WEBSOCKET_UPSTREAM_PORT:-82}"
PROXY_CONNECT_TIMEOUT="${PROXY_CONNECT_TIMEOUT:-1000s}"
PROXY_SEND_TIMEOUT="${PROXY_SEND_TIMEOUT:-1000s}"
PROXY_READ_TIMEOUT="${PROXY_READ_TIMEOUT:-1000s}"
WEBSOCKET_READ_TIMEOUT="${WEBSOCKET_READ_TIMEOUT:-3600s}"
WEBSOCKET_SEND_TIMEOUT="${WEBSOCKET_SEND_TIMEOUT:-3600s}"
CLIENT_MAX_BODY_SIZE="${CLIENT_MAX_BODY_SIZE:-2G}"
STATIC_ASSETS_EXPIRES="${STATIC_ASSETS_EXPIRES:-30d}"
API_LOAD_BALANCE_METHOD="${API_LOAD_BALANCE_METHOD:-round_robin}"
WEBSOCKET_LOAD_BALANCE_METHOD="${WEBSOCKET_LOAD_BALANCE_METHOD:-ip_hash}"
FRONTEND_LOAD_BALANCE_METHOD="${FRONTEND_LOAD_BALANCE_METHOD:-round_robin}"
FRONTEND_UPSTREAM_PORT="${FRONTEND_UPSTREAM_PORT:-80}"
DOCKER_INTERNAL_NETWORK="${DOCKER_INTERNAL_NETWORK:-arpeggio_internal_network}"
SINFONIA_CLIENT_APPS="${SINFONIA_CLIENT_APPS:-core@/}"
SINFONIA_FRONTEND_REPLICAS="${SINFONIA_FRONTEND_REPLICAS:-1}"

load_maestro_upstream_ports

validate_number() {
    local num=$1
    local min=$2
    local max=$3

    if ! [[ "$num" =~ ^[0-9]+$ ]]; then
        print_error "Please enter a valid number"
        return 1
    fi

    if [ "$num" -lt "$min" ] || [ "$num" -gt "$max" ]; then
        print_error "Number must be between $min and $max"
        return 1
    fi

    return 0
}

normalize_load_balance_method() {
    local method
    method="$(echo "$1" | tr '[:upper:]' '[:lower:]' | tr '-' '_')"

    case "$method" in
        round_robin|"")
            echo ""
            ;;
        least_conn|ip_hash)
            echo "    ${method};"
            ;;
        *)
            print_error "Unsupported load balance method: $1"
            exit 1
            ;;
    esac
}

generate_upstream_block() {
    local upstream_name=$1
    local host=$2
    local port=$3
    local count=$4
    local method_line=$5
    local i

    echo "upstream ${upstream_name} {"
    if [ -n "$method_line" ]; then
        echo "$method_line"
    fi

    if [ "$count" -eq 1 ]; then
        echo "    server ${host}:${port};"
    else
        for i in $(seq 1 "$count"); do
            echo "    server ${host}-${i}:${port};"
        done
    fi

    echo "}"
    echo ""
}

# Gateway entries: one per instance when deploy.sh / systemUp.sh drive the
# generator, a single un-instanced one when it is run on its own.
GW_INSTANCES=()
GW_CLIENT_APPS=()
GW_PORTS=()
GW_MODES=()
GW_API_HOSTS=()
GW_API_PORTS=()
GW_WEBSOCKET_HOSTS=()
GW_WEBSOCKET_PORTS=()

# Args: instance client_apps port api_host api_port websocket_host websocket_port
add_gateway_entry() {
    ARPEGGIO_INSTANCE="$1"
    if ! parse_sinfonia_client_apps "$2"; then
        print_error "Invalid Sinfonia client apps \"$2\"${1:+ for instance $1}"
        exit 1
    fi
    validate_number "$3" 0 65535 || exit 1

    GW_INSTANCES+=("$1")
    GW_CLIENT_APPS+=("$2")
    GW_PORTS+=("$3")
    GW_MODES+=("$SINFONIA_GATEWAY_MODE")
    GW_API_HOSTS+=("$4")
    GW_API_PORTS+=("$5")
    GW_WEBSOCKET_HOSTS+=("$6")
    GW_WEBSOCKET_PORTS+=("$7")
}

# One entry per instance that has selected its Sinfonia clients.
# NGINX_GATEWAY_INSTANCES (comma-separated) limits the gateway to those instances.
load_instance_gateway_entries() {
    local name manifest maestro_env client_apps port api_port websocket_port

    for name in $(list_instances); do
        if [ -n "${NGINX_GATEWAY_INSTANCES:-}" ] && [[ ",${NGINX_GATEWAY_INSTANCES}," != *",${name},"* ]]; then
            continue
        fi

        manifest="${ARPEGGIO_DEPLOY_ROOT}/${name}/scripts/sinfonia-apps.env"
        maestro_env="$(instance_maestro_env_file "$name")"
        client_apps="$(read_env_value_from_file "$manifest" "SINFONIA_CLIENT_APPS")"
        if [ -z "$client_apps" ]; then
            print_warning "Instance ${name} has no Sinfonia clients selected (run ./deploy.sh); left out of the gateway"
            continue
        fi

        port="$(read_env_value_from_file "$manifest" "NGINX_EXTERNAL_PORT")"
        api_port="$(read_env_value_from_file "$maestro_env" "SERVER_PORT")"
        websocket_port="$(read_env_value_from_file "$maestro_env" "WEBSOCKET_PORT")"

        ARPEGGIO_INSTANCE="$name"
        add_gateway_entry "$name" "$client_apps" "${port:-80}" \
            "$(maestro_container Api)" "${api_port:-$API_UPSTREAM_PORT}" \
            "$(maestro_container Websocket)" "${websocket_port:-$WEBSOCKET_UPSTREAM_PORT}"
    done

    if [ "${#GW_INSTANCES[@]}" -eq 0 ]; then
        print_error "No instance with selected Sinfonia clients found. Run ./deploy.sh first."
        exit 1
    fi
}

# Points the SINFONIA_APP_* arrays and the upstream names at gateway entry $1.
use_gateway_entry() {
    local g=$1
    local suffix

    ARPEGGIO_INSTANCE="${GW_INSTANCES[$g]}"
    parse_sinfonia_client_apps "${GW_CLIENT_APPS[$g]}" || exit 1
    suffix="${ARPEGGIO_INSTANCE:+_$(echo "$ARPEGGIO_INSTANCE" | tr '-' '_')}"
    GW_PORT="${GW_PORTS[$g]}"
    GW_API_UPSTREAM="api${suffix}"
    GW_WEBSOCKET_UPSTREAM="maestroWebsocket${suffix}"
    GW_LABEL="${ARPEGGIO_INSTANCE:+Instance ${ARPEGGIO_INSTANCE}}"
    GW_LABEL="${GW_LABEL:-Deployment}"
}

# Distinct gateway ports, optionally only those serving mode $1 (path|host).
gateway_ports() {
    local mode="${1:-}"
    local g

    for g in "${!GW_INSTANCES[@]}"; do
        if [ -z "$mode" ] || [ "${GW_MODES[$g]}" = "$mode" ]; then
            echo "${GW_PORTS[$g]}"
        fi
    done | sort -un
}

# A path-mode instance answers every Host on its port, so it cannot share the
# port. Host-mode instances share a port as long as their domains differ.
validate_gateway_entries() {
    local g h host
    local seen_hosts=" "

    for g in "${!GW_INSTANCES[@]}"; do
        for h in "${!GW_INSTANCES[@]}"; do
            if [ "$g" -lt "$h" ] && [ "${GW_PORTS[$g]}" = "${GW_PORTS[$h]}" ] &&
               { [ "${GW_MODES[$g]}" = "path" ] || [ "${GW_MODES[$h]}" = "path" ]; }; then
                print_error "Instances \"${GW_INSTANCES[$g]}\" and \"${GW_INSTANCES[$h]}\" both use gateway port ${GW_PORTS[$g]}."
                print_error "Give a path-mode instance its own gateway port, or use domains (host mode) for both."
                exit 1
            fi
        done

        [ "${GW_MODES[$g]}" = "host" ] || continue
        use_gateway_entry "$g"
        for host in ${SINFONIA_APP_HOSTS[*]}; do
            if [[ "$seen_hosts" == *" ${GW_PORT}/${host} "* ]]; then
                print_error "Domain \"${host}\" is used by more than one instance on gateway port ${GW_PORT}"
                exit 1
            fi
            seen_hosts+="${GW_PORT}/${host} "
        done
    done
}

print_configuration_summary() {
    local g i
    local mount_label

    echo -e ""
    print_status "Configuration Summary:"
    print_status "- Nginx gateway nodes: ${GREEN}${num_nginx_nodes}${NC}"
    for g in "${!GW_INSTANCES[@]}"; do
        use_gateway_entry "$g"
        print_status "- ${GW_LABEL}: gateway port ${GREEN}${GW_PORT}${NC}, ${SINFONIA_GATEWAY_MODE} mode"
        for i in "${!SINFONIA_APP_IDS[@]}"; do
            if [ "$SINFONIA_GATEWAY_MODE" = "host" ]; then
                mount_label="host ${SINFONIA_APP_HOSTS[$i]}"
            else
                mount_label="path ${SINFONIA_APP_PATHS[$i]}"
            fi
            print_status "    Client ${SINFONIA_APP_IDS[$i]}: ${mount_label} -> ${SINFONIA_APP_CONTAINERS[$i]}:${FRONTEND_UPSTREAM_PORT}"
        done
        print_status "    API -> ${GW_API_HOSTS[$g]}:${GW_API_PORTS[$g]}, WebSocket -> ${GW_WEBSOCKET_HOSTS[$g]}:${GW_WEBSOCKET_PORTS[$g]}"
    done
    print_status "- Frontend replicas per client: ${GREEN}${num_frontend_backends}${NC}"
    print_status "- API upstream servers: ${GREEN}${num_api_backends}${NC}"
    print_status "- WebSocket upstream servers: ${GREEN}${num_websocket_backends}${NC}"
    print_status "- Nginx image: ${GREEN}${NGINX_IMAGE}${NC}"
    print_status "- Gateway network: ${GREEN}${DOCKER_INTERNAL_NETWORK}${NC}"
    echo -e "${BLUE}================================================================${NC}"
    echo ""
}

get_user_input() {
    local apps_input nginx_external_port

    if [ "${NGINX_DEPLOY_MODE:-false}" = "true" ]; then
        num_nginx_nodes="${NGINX_NUM_NODES:-1}"
        num_frontend_backends="${NGINX_NUM_FRONTEND_BACKENDS:-${SINFONIA_FRONTEND_REPLICAS:-1}}"
        num_api_backends="${NGINX_NUM_API_BACKENDS:-1}"
        num_websocket_backends="${NGINX_NUM_WEBSOCKET_BACKENDS:-1}"

        validate_number "$num_nginx_nodes" 1 5 || exit 1
        validate_number "$num_frontend_backends" 1 10 || exit 1
        validate_number "$num_api_backends" 1 10 || exit 1
        validate_number "$num_websocket_backends" 1 10 || exit 1
        load_instance_gateway_entries
        validate_gateway_entries

        print_status "Using deployment-provided Nginx configuration"
        print_configuration_summary
        return 0
    fi

    echo -e ""
    echo -e "${BLUE}================================================================${NC}"
    echo -e "Ready to configure the Nginx gateway cluster, please provide the needed information:"
    echo -e ""
    echo -e "Path mode: ${GREEN}core,public${NC}  (first at /, others at /<appId>App/)"
    echo -e "Host mode: ${GREEN}dyeus@dyeus.al,core@panel.pronix.al,public@pronix.al${NC} (shop catch-all: ${GREEN}public@*.arpeggio.al${NC})"
    echo -e "www aliases are added automatically (dyeus.al ↔ www.dyeus.al)."
    echo -e "Extra aliases: ${GREEN}public@pronix.al|shop.pronix.al${NC}"
    echo -e ""

    while true; do
        read -p "Enter number of Nginx gateway nodes (1-5) [default: 1]: " num_nginx_nodes
        num_nginx_nodes=${num_nginx_nodes:-1}
        if validate_number "$num_nginx_nodes" 1 5; then
            break
        fi
    done

    while true; do
        read -p "Enter Nginx external base port (0-65535) [default: 80]: " nginx_external_port
        nginx_external_port=${nginx_external_port:-80}
        if validate_number "$nginx_external_port" 0 65535; then
            break
        fi
    done

    while true; do
        read -p "Sinfonia clients [default: core]: " apps_input
        apps_input="$(echo "${apps_input:-core}" | tr -d '[:space:]')"
        if [ -z "$apps_input" ]; then
            print_error "At least one client app is required"
            continue
        fi
        SINFONIA_CLIENT_APPS="$(normalize_sinfonia_client_apps_input "$apps_input")"
        if parse_sinfonia_client_apps "$SINFONIA_CLIENT_APPS"; then
            break
        fi
    done

    while true; do
        read -p "Enter number of frontend replicas per client app (1-10) [default: 1]: " num_frontend_backends
        num_frontend_backends=${num_frontend_backends:-1}
        if validate_number "$num_frontend_backends" 1 10; then
            break
        fi
    done

    while true; do
        read -p "Enter number of API upstream servers (1-10) [default: 1]: " num_api_backends
        num_api_backends=${num_api_backends:-1}
        if validate_number "$num_api_backends" 1 10; then
            break
        fi
    done

    while true; do
        read -p "Enter number of WebSocket upstream servers (1-10) [default: 1]: " num_websocket_backends
        num_websocket_backends=${num_websocket_backends:-1}
        if validate_number "$num_websocket_backends" 1 10; then
            break
        fi
    done

    add_gateway_entry "" "$SINFONIA_CLIENT_APPS" "$nginx_external_port" \
        "$API_UPSTREAM_HOST" "$API_UPSTREAM_PORT" \
        "$WEBSOCKET_UPSTREAM_HOST" "$WEBSOCKET_UPSTREAM_PORT"

    print_configuration_summary

    read -p "Proceed with this configuration? (Y/n): " confirm
    confirm=${confirm:-y}
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_warning "Operation cancelled by user. NO docker-compose was generated!"
        exit 0
    fi
}

find_root_app_index() {
    local i
    for i in "${!SINFONIA_APP_PATHS[@]}"; do
        if [ "${SINFONIA_APP_PATHS[$i]}" = "/" ]; then
            echo "$i"
            return 0
        fi
    done
    echo "0"
}

emit_health_location() {
    cat <<EOF
    location = /nginx-health {
        access_log off;
        default_type text/plain;
        return 200 "ok\\n";
    }

EOF
}

# Maestro + SPA locations for a server block of the current gateway entry.
# Args: frontend_upstream
emit_gateway_server_locations() {
    local frontend_upstream=$1

    cat <<EOF
    location /api/ {
        proxy_pass http://${GW_API_UPSTREAM};

        proxy_buffering off;
    }

    location /api/auxiliary/media/ {
        proxy_pass http://${GW_API_UPSTREAM};

        proxy_buffering off;

        proxy_set_header Connection "";
    }

    location /ws/ {
        proxy_pass http://${GW_WEBSOCKET_UPSTREAM}/;

        proxy_http_version 1.1;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_read_timeout ${WEBSOCKET_READ_TIMEOUT};
        proxy_send_timeout ${WEBSOCKET_SEND_TIMEOUT};
    }

    gzip on;
    gzip_vary on;
    gzip_min_length 256;
    gzip_proxied any;
    gzip_types text/plain text/css application/javascript application/json application/wasm image/svg+xml;

    location / {
        proxy_pass http://${frontend_upstream};
    }
EOF
}

emit_server_proxy_settings() {
    cat <<EOF
    client_max_body_size ${CLIENT_MAX_BODY_SIZE};

    proxy_http_version 1.1;

    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;

    proxy_connect_timeout ${PROXY_CONNECT_TIMEOUT};
    proxy_send_timeout ${PROXY_SEND_TIMEOUT};
    proxy_read_timeout ${PROXY_READ_TIMEOUT};

EOF
}

generate_gateway_conf() {
    local frontend_method_line api_method_line websocket_method_line
    local g i port path strip_path

    mkdir -p conf

    frontend_method_line="$(normalize_load_balance_method "$FRONTEND_LOAD_BALANCE_METHOD")"
    api_method_line="$(normalize_load_balance_method "$API_LOAD_BALANCE_METHOD")"
    websocket_method_line="$(normalize_load_balance_method "$WEBSOCKET_LOAD_BALANCE_METHOD")"

    print_status "Generating conf/gateway.conf..."

    {
        for g in "${!GW_INSTANCES[@]}"; do
            use_gateway_entry "$g"
            for i in "${!SINFONIA_APP_IDS[@]}"; do
                generate_upstream_block \
                    "${SINFONIA_APP_UPSTREAMS[$i]}" \
                    "${SINFONIA_APP_CONTAINERS[$i]}" \
                    "$FRONTEND_UPSTREAM_PORT" \
                    "$num_frontend_backends" \
                    "$frontend_method_line"
            done
            generate_upstream_block "$GW_API_UPSTREAM" "${GW_API_HOSTS[$g]}" "${GW_API_PORTS[$g]}" "$num_api_backends" "$api_method_line"
            generate_upstream_block "$GW_WEBSOCKET_UPSTREAM" "${GW_WEBSOCKET_HOSTS[$g]}" "${GW_WEBSOCKET_PORTS[$g]}" "$num_websocket_backends" "$websocket_method_line"
        done

        # Never make a client the default_server. Unmatched Host headers
        # (forgotten www, typos, raw IP) used to steal the first SPA —
        # e.g. www.dyeus.al serving pronix.al when public was listed first.
        for port in $(gateway_ports host); do
            cat <<EOF
server {
    listen ${port} default_server;
    server_name _;

EOF
            emit_health_location
            cat <<EOF
    location / {
        return 404;
    }
}

EOF
        done

        for g in "${!GW_INSTANCES[@]}"; do
            use_gateway_entry "$g"

            if [ "$SINFONIA_GATEWAY_MODE" = "host" ]; then
                for i in "${!SINFONIA_APP_IDS[@]}"; do
                    cat <<EOF
server {
    listen ${GW_PORT};
    server_name ${SINFONIA_APP_HOSTS[$i]};

EOF
                    emit_server_proxy_settings
                    emit_gateway_server_locations "${SINFONIA_APP_UPSTREAMS[$i]}"
                    cat <<EOF
}

EOF
                done
                continue
            fi

            cat <<EOF
server {
    listen ${GW_PORT};
    server_name _;

EOF
            emit_server_proxy_settings
            emit_health_location

            # Non-root client paths first (longest-prefix wins over `/`).
            for i in "${!SINFONIA_APP_IDS[@]}"; do
                path="${SINFONIA_APP_PATHS[$i]}"
                [ "$path" != "/" ] || continue
                strip_path="${path%/}"
                cat <<EOF
    location = ${strip_path} {
        return 301 ${path};
    }

    location ${path} {
        # Trailing slash on proxy_pass strips the URL prefix so the SPA
        # container (always served at /) still receives root-relative paths.
        proxy_pass http://${SINFONIA_APP_UPSTREAMS[$i]}/;
    }

EOF
            done

            emit_gateway_server_locations "${SINFONIA_APP_UPSTREAMS[$(find_root_app_index)]}"
            cat <<EOF
}

EOF
        done
    } > conf/gateway.conf

    print_status "Finished generating conf/gateway.conf"
}

generate_docker_compose() {
    local i port health_port

    print_status "Generating docker-compose.yml..."

    health_port="$(gateway_ports | head -1)"

    cat > docker-compose.yml << EOF
version: '3.8'

services:
EOF

    for i in $(seq 1 "$num_nginx_nodes"); do
        cat >> docker-compose.yml << EOF
  nginx-${i}:
    image: ${NGINX_IMAGE}
    container_name: nginx-gateway-${i}
    hostname: nginx-gateway-${i}
    restart: unless-stopped
    ports:
EOF
        # Each gateway port listens on itself inside the container.
        for port in $(gateway_ports); do
            echo "      - \"$((port + i - 1)):${port}\"" >> docker-compose.yml
        done
        cat >> docker-compose.yml << EOF
    volumes:
      - ./conf/gateway.conf:/etc/nginx/conf.d/default.conf:ro
    networks:
      - arpeggio-internal
    healthcheck:
      test: ["CMD-SHELL", "wget -q --spider http://127.0.0.1:${health_port}/nginx-health || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s

EOF
    done

    cat >> docker-compose.yml << EOF
networks:
  arpeggio-internal:
    external: true
    name: ${DOCKER_INTERNAL_NETWORK}
EOF

    print_status "Finished generating docker-compose.yml"
}

generate_setup_scripts() {
    local g i host port health_port

    mkdir -p scripts

    health_port="$(gateway_ports | head -1)"

    print_status "Generating scripts/wait-for-nginx.sh..."
    cat > scripts/wait-for-nginx.sh << EOF
#!/bin/bash

set -euo pipefail

NUM_NODES=${num_nginx_nodes}
BASE_PORT=${health_port}
MAX_ATTEMPTS=30

for i in \$(seq 1 "\$NUM_NODES"); do
    port=\$((BASE_PORT + i - 1))
    attempt=0
    until curl -fsS "http://localhost:\${port}/nginx-health" >/dev/null 2>&1 || [ "\$attempt" -ge "\$MAX_ATTEMPTS" ]; do
        attempt=\$((attempt + 1))
        echo "Waiting for nginx-gateway-\${i} on port \${port}... (\${attempt}/\${MAX_ATTEMPTS})"
        sleep 2
    done

    if [ "\$attempt" -ge "\$MAX_ATTEMPTS" ]; then
        echo "Nginx gateway node \${i} did not become ready on port \${port}"
        exit 1
    fi

    echo "Nginx gateway node \${i} is ready on port \${port}"
done
EOF

    print_status "Generating scripts/health-check.sh..."
    cat > scripts/health-check.sh << EOF
#!/bin/bash

set -euo pipefail

NUM_NODES=${num_nginx_nodes}
BASE_PORT=${health_port}
all_healthy=true

for i in \$(seq 1 "\$NUM_NODES"); do
    port=\$((BASE_PORT + i - 1))
    if curl -fsS "http://localhost:\${port}/nginx-health" >/dev/null 2>&1; then
        echo "[OK] nginx-gateway-\${i} responding on port \${port}"
    else
        echo "[FAIL] nginx-gateway-\${i} not responding on port \${port}"
        all_healthy=false
    fi
done

if [ "\$all_healthy" = true ]; then
    echo "All Nginx gateway nodes are healthy"
    exit 0
fi

echo "One or more Nginx gateway nodes are unhealthy"
exit 1
EOF

    print_status "Generating scripts/route-check.sh..."
    {
        cat << 'EOF'
#!/bin/bash

set -euo pipefail

check_route() {
    local label="$1"
    local url="$2"
    local expected_codes="$3"
    local host_header="${4:-}"
    local curl_args=(-s -o /dev/null -w "%{http_code}")

    if [ -n "$host_header" ]; then
        curl_args+=(-H "Host: ${host_header}")
    fi

    status_code=$(curl "${curl_args[@]}" "$url")
    if echo "${expected_codes}" | grep -qw "${status_code}"; then
        echo "[OK] ${label} -> ${url} (HTTP ${status_code})"
    else
        echo "[WARN] ${label} -> ${url} (HTTP ${status_code}, expected one of: ${expected_codes})"
    fi
}

EOF
        for g in "${!GW_INSTANCES[@]}"; do
            use_gateway_entry "$g"
            echo "echo \"Checking ${GW_LABEL} on port ${GW_PORT} (mode=${SINFONIA_GATEWAY_MODE})...\""
            for i in "${!SINFONIA_APP_IDS[@]}"; do
                if [ "$SINFONIA_GATEWAY_MODE" = "host" ]; then
                    for host in ${SINFONIA_APP_HOSTS[$i]}; do
                        echo "check_route \"Client ${SINFONIA_APP_IDS[$i]}\" \"http://localhost:${GW_PORT}/\" \"200 301 302 404 502 503 504\" \"${host}\""
                    done
                    echo "check_route \"API (${SINFONIA_APP_IDS[$i]} host)\" \"http://localhost:${GW_PORT}/api/\" \"200 301 302 404 405 502 503 504\" \"$(sinfonia_app_primary_host "$i")\""
                else
                    echo "check_route \"Client ${SINFONIA_APP_IDS[$i]}\" \"http://localhost:${GW_PORT}${SINFONIA_APP_PATHS[$i]}\" \"200 301 302 404 502 503 504\""
                fi
            done
            if [ "$SINFONIA_GATEWAY_MODE" != "host" ]; then
                echo "check_route \"API\" \"http://localhost:${GW_PORT}/api/\" \"200 301 302 404 405 502 503 504\""
                echo "check_route \"Media API\" \"http://localhost:${GW_PORT}/api/auxiliary/media/\" \"200 301 302 404 405 502 503 504\""
                echo "check_route \"WebSocket path\" \"http://localhost:${GW_PORT}/ws/\" \"400 426 502 503 504\""
            fi
        done
        for port in $(gateway_ports host); do
            echo "check_route \"Unknown host must not steal a client\" \"http://localhost:${port}/\" \"404\" \"this-host-should-not-match.invalid\""
        done
        echo "check_route \"Gateway health\" \"http://localhost:${health_port}/nginx-health\" \"200\""
    } > scripts/route-check.sh

    chmod +x scripts/*.sh
    print_status "Finished generating setup scripts"
}

generate_readme() {
    local g i
    local rows=""
    local instance_cell

    for g in "${!GW_INSTANCES[@]}"; do
        use_gateway_entry "$g"
        instance_cell="${ARPEGGIO_INSTANCE:--}"
        for i in "${!SINFONIA_APP_IDS[@]}"; do
            if [ "$SINFONIA_GATEWAY_MODE" = "host" ]; then
                rows+="| ${instance_cell} | ${GW_PORT} | \`${SINFONIA_APP_HOSTS[$i]}\` \`/\` | ${SINFONIA_APP_UPSTREAMS[$i]} | Sinfonia client \`${SINFONIA_APP_IDS[$i]}\` |
"
            else
                rows+="| ${instance_cell} | ${GW_PORT} | \`${SINFONIA_APP_PATHS[$i]}\` | ${SINFONIA_APP_UPSTREAMS[$i]} | Sinfonia client \`${SINFONIA_APP_IDS[$i]}\` |
"
            fi
        done
        rows+="| ${instance_cell} | ${GW_PORT} | \`/api/\` | ${GW_API_UPSTREAM} | Maestro REST API (\`${GW_API_HOSTS[$g]}\`) |
| ${instance_cell} | ${GW_PORT} | \`/ws/\` | ${GW_WEBSOCKET_UPSTREAM} | Maestro WebSocket server (\`${GW_WEBSOCKET_HOSTS[$g]}\`) |
"
    done

    cat > README.md << EOF
# Nginx Gateway Cluster

Generated Nginx reverse proxy / load balancer for the Arpeggio stack.

Every instance has its own Sinfonia clients and its own Maestro API and WebSocket upstreams.

- **Host mode:** each client is served at \`/\` on its own domain(s), including the automatic \`www.\` pair. \`/api/\` and \`/ws/\` on a domain reach the Maestro of the instance that owns it. Instances may share a gateway port; unmatched Host headers return 404.
- **Path mode:** the instance owns its gateway port. The first client is at \`/\`, the others at \`/<appId>App/\`.

## Entry points

| Instance | Port | Domain(s) / path | Upstream | Purpose |
|----------|------|------------------|----------|---------|
${rows}
DNS for each domain must point at this gateway. TLS is not generated here — terminate TLS at Cloudflare, a front proxy, or extend \`gateway.conf\` with certificates.

## Start

\`\`\`bash
docker-compose up -d
./scripts/wait-for-nginx.sh
./scripts/health-check.sh
./scripts/route-check.sh
\`\`\`

Shared network: \`${DOCKER_INTERNAL_NETWORK}\`
EOF
}

main() {
    local g i

    echo -e ""
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${BLUE}              xCloud Nginx Gateway Cluster Generator${NC}"
    echo -e "${BLUE}================================================================${NC}"
    echo -e "Path mode: first client -> ${GREEN}/${NC}, others -> ${GREEN}/<appId>App/${NC}"
    echo -e "Host mode: each client -> its domain at ${GREEN}/${NC}"
    echo -e "Per instance: ${GREEN}/api/${NC} and ${GREEN}/ws/${NC} -> its Maestro"
    echo -e "${BLUE}================================================================${NC}"

    get_user_input

    generate_gateway_conf
    generate_docker_compose
    generate_setup_scripts
    generate_readme

    echo -e "${GREEN}================================================================${NC}"
    echo -e "${GREEN}               Generation completed successfully!${NC}"
    echo -e "${GREEN}================================================================${NC}"
    print_status "Files created:"
    print_status "- conf/gateway.conf"
    print_status "- docker-compose.yml"
    print_status "- scripts/wait-for-nginx.sh"
    print_status "- scripts/health-check.sh"
    print_status "- scripts/route-check.sh"
    print_status "- README.md"
    echo ""
    print_status "To start the gateway, run: docker-compose up -d"
    for g in "${!GW_INSTANCES[@]}"; do
        use_gateway_entry "$g"
        for i in "${!SINFONIA_APP_IDS[@]}"; do
            print_status "${GW_LABEL}, Sinfonia ${SINFONIA_APP_IDS[$i]}: $(sinfonia_app_public_url "$GW_PORT" "$i")"
        done
    done
    print_status "Shared network: ${DOCKER_INTERNAL_NETWORK}"
    echo ""
}

main "$@"
