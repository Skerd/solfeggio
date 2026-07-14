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

    grep -E "^${key}=" "$file" 2>/dev/null | head -1 | cut -d= -f2-
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
NGINX_LISTEN_PORT="${NGINX_LISTEN_PORT:-80}"
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

load_client_apps_or_exit() {
    if ! parse_sinfonia_client_apps "$SINFONIA_CLIENT_APPS"; then
        print_error "Invalid SINFONIA_CLIENT_APPS=\"${SINFONIA_CLIENT_APPS}\""
        exit 1
    fi
}

print_configuration_summary() {
    local i

    echo -e ""
    print_status "Configuration Summary:"
    print_status "- Nginx gateway nodes: ${GREEN}${num_nginx_nodes}${NC}"
    print_status "- Gateway external base port: ${GREEN}${nginx_external_port}${NC}"
    for i in "${!SINFONIA_APP_IDS[@]}"; do
        print_status "- Client ${SINFONIA_APP_IDS[$i]}: path ${GREEN}${SINFONIA_APP_PATHS[$i]}${NC} -> ${SINFONIA_APP_CONTAINERS[$i]}:${FRONTEND_UPSTREAM_PORT}"
    done
    print_status "- Frontend replicas per client: ${GREEN}${num_frontend_backends}${NC}"
    print_status "- API upstream servers: ${GREEN}${num_api_backends}${NC} (${API_UPSTREAM_HOST}:${API_UPSTREAM_PORT})"
    print_status "- WebSocket upstream servers: ${GREEN}${num_websocket_backends}${NC} (${WEBSOCKET_UPSTREAM_HOST}:${WEBSOCKET_UPSTREAM_PORT})"
    print_status "- Nginx image: ${GREEN}${NGINX_IMAGE}${NC}"
    print_status "- Gateway network: ${GREEN}${DOCKER_INTERNAL_NETWORK}${NC}"
    echo -e "${BLUE}================================================================${NC}"
    echo ""
}

get_user_input() {
    local apps_input
    local -a selected_ids=()

    if [ "${NGINX_DEPLOY_MODE:-false}" = "true" ]; then
        num_nginx_nodes="${NGINX_NUM_NODES:-1}"
        nginx_external_port="${NGINX_EXTERNAL_PORT:-80}"
        num_frontend_backends="${NGINX_NUM_FRONTEND_BACKENDS:-${SINFONIA_FRONTEND_REPLICAS:-1}}"
        num_api_backends="${NGINX_NUM_API_BACKENDS:-1}"
        num_websocket_backends="${NGINX_NUM_WEBSOCKET_BACKENDS:-1}"
        SINFONIA_CLIENT_APPS="${SINFONIA_CLIENT_APPS:-core@/}"
        SINFONIA_FRONTEND_REPLICAS="$num_frontend_backends"

        validate_number "$num_nginx_nodes" 1 5 || exit 1
        validate_number "$nginx_external_port" 0 65535 || exit 1
        validate_number "$num_frontend_backends" 1 10 || exit 1
        validate_number "$num_api_backends" 1 10 || exit 1
        validate_number "$num_websocket_backends" 1 10 || exit 1
        load_client_apps_or_exit

        print_status "Using deployment-provided Nginx configuration"
        print_configuration_summary
        return 0
    fi

    echo -e ""
    echo -e "${BLUE}================================================================${NC}"
    echo -e "Ready to configure the Nginx gateway cluster, please provide the needed information:"
    echo -e ""
    echo -e "All Sinfonia clients share one host port. The first app is served at ${GREEN}/${NC};"
    echo -e "additional apps are served at ${GREEN}/<appId>App/${NC}."
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
        read -p "Sinfonia client apps (comma-separated; first is /) [default: core]: " apps_input
        apps_input="$(echo "${apps_input:-core}" | tr -d '[:space:]')"
        IFS=',' read -r -a selected_ids <<< "$apps_input"
        if [ "${#selected_ids[@]}" -eq 0 ]; then
            print_error "At least one client app is required"
            continue
        fi
        break
    done

    SINFONIA_CLIENT_APPS="$(build_sinfonia_client_apps_spec_from_ids "$(IFS=,; echo "${selected_ids[*]}")")"
    load_client_apps_or_exit

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

generate_gateway_conf() {
    local frontend_method_line api_method_line websocket_method_line
    local i root_idx root_upstream path strip_path

    mkdir -p conf

    frontend_method_line="$(normalize_load_balance_method "$FRONTEND_LOAD_BALANCE_METHOD")"
    api_method_line="$(normalize_load_balance_method "$API_LOAD_BALANCE_METHOD")"
    websocket_method_line="$(normalize_load_balance_method "$WEBSOCKET_LOAD_BALANCE_METHOD")"
    root_idx="$(find_root_app_index)"
    root_upstream="${SINFONIA_APP_UPSTREAMS[$root_idx]}"

    print_status "Generating conf/gateway.conf..."

    {
        for i in "${!SINFONIA_APP_IDS[@]}"; do
            generate_upstream_block \
                "${SINFONIA_APP_UPSTREAMS[$i]}" \
                "${SINFONIA_APP_CONTAINERS[$i]}" \
                "$FRONTEND_UPSTREAM_PORT" \
                "$num_frontend_backends" \
                "$frontend_method_line"
        done
        generate_upstream_block "api" "$API_UPSTREAM_HOST" "$API_UPSTREAM_PORT" "$num_api_backends" "$api_method_line"
        generate_upstream_block "maestroWebsocket" "$WEBSOCKET_UPSTREAM_HOST" "$WEBSOCKET_UPSTREAM_PORT" "$num_websocket_backends" "$websocket_method_line"

        cat <<EOF
server {
    listen ${NGINX_LISTEN_PORT};
    server_name _;

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
        # container (built with matching VITE_BASE_PATH) still serves at /.
        proxy_pass http://${SINFONIA_APP_UPSTREAMS[$i]}/;
    }

EOF
        done

        cat <<EOF
    location /api/ {
        proxy_pass http://api;

        proxy_buffering off;
    }

    location /api/auxiliary/media/ {
        proxy_pass http://api;

        proxy_buffering off;

        proxy_set_header Connection "";
    }

    location /ws/ {
        proxy_pass http://maestroWebsocket/;

        proxy_http_version 1.1;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_read_timeout ${WEBSOCKET_READ_TIMEOUT};
        proxy_send_timeout ${WEBSOCKET_SEND_TIMEOUT};
    }

    location /assets/ {
        proxy_pass http://${root_upstream};

        proxy_buffering off;

        expires ${STATIC_ASSETS_EXPIRES};
        access_log off;

        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    location / {
        proxy_pass http://${root_upstream};
    }
}
EOF
    } > conf/gateway.conf

    print_status "Finished generating conf/gateway.conf"
}

generate_docker_compose() {
    local i external_port

    print_status "Generating docker-compose.yml..."

    cat > docker-compose.yml << EOF
version: '3.8'

services:
EOF

    for i in $(seq 1 "$num_nginx_nodes"); do
        external_port=$((nginx_external_port + i - 1))
        cat >> docker-compose.yml << EOF
  nginx-${i}:
    image: ${NGINX_IMAGE}
    container_name: nginx-gateway-${i}
    hostname: nginx-gateway-${i}
    restart: unless-stopped
    ports:
      - "${external_port}:${NGINX_LISTEN_PORT}"
    volumes:
      - ./conf/gateway.conf:/etc/nginx/conf.d/default.conf:ro
    networks:
      - arpeggio-internal
    healthcheck:
      test: ["CMD-SHELL", "wget -q --spider http://127.0.0.1:${NGINX_LISTEN_PORT}/ || exit 1"]
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
    local i
    local ids_csv=""
    local paths_csv=""

    mkdir -p scripts

    for i in "${!SINFONIA_APP_IDS[@]}"; do
        if [ -n "$ids_csv" ]; then
            ids_csv+=","
            paths_csv+=","
        fi
        ids_csv+="${SINFONIA_APP_IDS[$i]}"
        paths_csv+="${SINFONIA_APP_PATHS[$i]}"
    done

    print_status "Generating scripts/wait-for-nginx.sh..."
    cat > scripts/wait-for-nginx.sh << EOF
#!/bin/bash

set -euo pipefail

NUM_NODES=${num_nginx_nodes}
BASE_PORT=${nginx_external_port}
MAX_ATTEMPTS=30

for i in \$(seq 1 "\$NUM_NODES"); do
    port=\$((BASE_PORT + i - 1))
    attempt=0
    until curl -fsS "http://localhost:\${port}/" >/dev/null 2>&1 || [ "\$attempt" -ge "\$MAX_ATTEMPTS" ]; do
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
BASE_PORT=${nginx_external_port}
all_healthy=true

for i in \$(seq 1 "\$NUM_NODES"); do
    port=\$((BASE_PORT + i - 1))
    if curl -fsS "http://localhost:\${port}/" >/dev/null 2>&1; then
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
    cat > scripts/route-check.sh << EOF
#!/bin/bash

set -euo pipefail

BASE_PORT=${nginx_external_port}
APP_IDS=(${ids_csv//,/ })
APP_PATHS=(${paths_csv//,/ })

check_route() {
    local label="\$1"
    local path="\$2"
    local expected_codes="\$3"

    status_code=\$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:\${BASE_PORT}\${path}")
    if echo "\${expected_codes}" | grep -qw "\${status_code}"; then
        echo "[OK] \${label} -> \${path} (HTTP \${status_code})"
    else
        echo "[WARN] \${label} -> \${path} (HTTP \${status_code}, expected one of: \${expected_codes})"
    fi
}

echo "Checking gateway routes on port \${BASE_PORT}..."
for idx in "\${!APP_IDS[@]}"; do
    app="\${APP_IDS[idx]}"
    path="\${APP_PATHS[idx]}"
    check_route "Client \${app}" "\$path" "200 301 302 404 502 503 504"
done
check_route "API" "/api/" "200 301 302 404 405 502 503 504"
check_route "Media API" "/api/auxiliary/media/" "200 301 302 404 405 502 503 504"
check_route "WebSocket path" "/ws/" "400 426 502 503 504"
EOF

    chmod +x scripts/*.sh
    print_status "Finished generating setup scripts"
}

generate_readme() {
    local i
    local rows=""

    for i in "${!SINFONIA_APP_IDS[@]}"; do
        rows+="| \`${SINFONIA_APP_PATHS[$i]}\` | ${SINFONIA_APP_UPSTREAMS[$i]} | Sinfonia client \`${SINFONIA_APP_IDS[$i]}\` |
"
    done

    cat > README.md << EOF
# Nginx Gateway Cluster

Generated Nginx reverse proxy / load balancer for the Arpeggio stack.

All Sinfonia clients share host port \`${nginx_external_port}\`. The first selected app is at \`/\`; additional apps are at \`/<appId>App/\`.

## Entry points

| Path | Upstream | Purpose |
|------|----------|---------|
${rows}| \`/api/\` | api | Maestro REST API |
| \`/api/auxiliary/media/\` | api | Media uploads/downloads |
| \`/ws/\` | maestroWebsocket | Maestro WebSocket server |

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
    local i

    echo -e ""
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${BLUE}              xCloud Nginx Gateway Cluster Generator${NC}"
    echo -e "${BLUE}================================================================${NC}"
    echo -e "Path-based Sinfonia clients on a single gateway port."
    echo -e "- First client -> ${GREEN}/${NC}"
    echo -e "- Other clients -> ${GREEN}/<appId>App/${NC}"
    echo -e "- ${GREEN}/api/${NC} and ${GREEN}/ws/${NC} -> Maestro"
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
    for i in "${!SINFONIA_APP_IDS[@]}"; do
        print_status "Sinfonia ${SINFONIA_APP_IDS[$i]}: $(sinfonia_app_public_url "$nginx_external_port" "${SINFONIA_APP_PATHS[$i]}")"
    done
    print_status "Shared network: ${DOCKER_INTERNAL_NETWORK}"
    echo ""
}

main "$@"
