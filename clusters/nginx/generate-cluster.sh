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

NGINX_IMAGE="${NGINX_IMAGE:-nginx:1.27-alpine}"
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
SINFONIA_CLIENT_APPS="${SINFONIA_CLIENT_APPS:-core@80}"
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
    nginx_external_port="${SINFONIA_APP_EXTERNAL_PORTS[0]}"
}

print_configuration_summary() {
    local i

    echo -e ""
    print_status "Configuration Summary:"
    print_status "- Nginx gateway nodes: ${GREEN}${num_nginx_nodes}${NC}"
    for i in "${!SINFONIA_APP_IDS[@]}"; do
        print_status "- Client ${SINFONIA_APP_IDS[$i]}: host ${GREEN}${SINFONIA_APP_EXTERNAL_PORTS[$i]}${NC} -> ${SINFONIA_APP_CONTAINERS[$i]}:${FRONTEND_UPSTREAM_PORT}"
    done
    print_status "- Frontend replicas per client: ${GREEN}${num_frontend_backends}${NC}"
    print_status "- API upstream servers: ${GREEN}${num_api_backends}${NC} (${API_UPSTREAM_HOST}:${API_UPSTREAM_PORT})"
    print_status "- WebSocket upstream servers: ${GREEN}${num_websocket_backends}${NC} (${WEBSOCKET_UPSTREAM_HOST}:${WEBSOCKET_UPSTREAM_PORT})"
    print_status "- Nginx image: ${GREEN}${NGINX_IMAGE}${NC}"
    print_status "- Gateway network: ${GREEN}${DOCKER_INTERNAL_NETWORK}${NC}"
    print_status "- API load balance method: ${GREEN}${API_LOAD_BALANCE_METHOD}${NC}"
    print_status "- WebSocket load balance method: ${GREEN}${WEBSOCKET_LOAD_BALANCE_METHOD}${NC}"
    print_status "- Frontend load balance method: ${GREEN}${FRONTEND_LOAD_BALANCE_METHOD}${NC}"
    echo -e "${BLUE}================================================================${NC}"
    echo ""
}

get_user_input() {
    local apps_input first_port_input extra_port_input
    local -a selected_ids=()

    if [ "${NGINX_DEPLOY_MODE:-false}" = "true" ]; then
        num_nginx_nodes="${NGINX_NUM_NODES:-1}"
        num_frontend_backends="${NGINX_NUM_FRONTEND_BACKENDS:-${SINFONIA_FRONTEND_REPLICAS:-1}}"
        num_api_backends="${NGINX_NUM_API_BACKENDS:-1}"
        num_websocket_backends="${NGINX_NUM_WEBSOCKET_BACKENDS:-1}"
        SINFONIA_CLIENT_APPS="${SINFONIA_CLIENT_APPS:-core@80}"
        SINFONIA_FRONTEND_REPLICAS="$num_frontend_backends"

        validate_number "$num_nginx_nodes" 1 5 || exit 1
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

    while true; do
        read -p "Enter number of Nginx gateway nodes (1-5) [default: 1]: " num_nginx_nodes
        num_nginx_nodes=${num_nginx_nodes:-1}
        if validate_number "$num_nginx_nodes" 1 5; then
            break
        fi
    done

    while true; do
        read -p "Sinfonia client apps (comma-separated ids) [default: core]: " apps_input
        apps_input="$(echo "${apps_input:-core}" | tr -d '[:space:]')"
        IFS=',' read -r -a selected_ids <<< "$apps_input"
        if [ "${#selected_ids[@]}" -eq 0 ]; then
            print_error "At least one client app is required"
            continue
        fi
        break
    done

    while true; do
        read -p "External base port for the first client app (0-65535) [default: 80]: " first_port_input
        first_port_input=${first_port_input:-80}
        if validate_number "$first_port_input" 0 65535; then
            break
        fi
    done

    extra_port_input=8080
    if [ "${#selected_ids[@]}" -gt 1 ]; then
        while true; do
            read -p "External base port for additional client apps (0-65535) [default: 8080]: " extra_port_input
            extra_port_input=${extra_port_input:-8080}
            if validate_number "$extra_port_input" 0 65535; then
                if [ "$extra_port_input" = "$first_port_input" ]; then
                    print_error "Additional base port must differ from the first client port"
                    continue
                fi
                break
            fi
        done
    fi

    SINFONIA_CLIENT_APPS="$(build_sinfonia_client_apps_spec_from_ids "$(IFS=,; echo "${selected_ids[*]}")" "$first_port_input" "$extra_port_input")"
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

generate_spa_server_block() {
    local listen_port=$1
    local frontend_upstream=$2

    cat <<EOF
server {
    listen ${listen_port};
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

    location / {
        proxy_pass http://${frontend_upstream};
    }

    location /assets/ {
        proxy_pass http://${frontend_upstream};

        proxy_buffering off;

        expires ${STATIC_ASSETS_EXPIRES};
        access_log off;

        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

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
        # Trailing slash strips the /ws/ prefix before forwarding (same as
        # sinfonia vite dev proxy rewrite).
        proxy_pass http://maestroWebsocket/;

        proxy_http_version 1.1;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_read_timeout ${WEBSOCKET_READ_TIMEOUT};
        proxy_send_timeout ${WEBSOCKET_SEND_TIMEOUT};
    }
}
EOF
}

generate_gateway_conf() {
    local frontend_method_line api_method_line websocket_method_line
    local i

    mkdir -p conf

    frontend_method_line="$(normalize_load_balance_method "$FRONTEND_LOAD_BALANCE_METHOD")"
    api_method_line="$(normalize_load_balance_method "$API_LOAD_BALANCE_METHOD")"
    websocket_method_line="$(normalize_load_balance_method "$WEBSOCKET_LOAD_BALANCE_METHOD")"

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

        for i in "${!SINFONIA_APP_IDS[@]}"; do
            generate_spa_server_block "${SINFONIA_APP_LISTEN_PORTS[$i]}" "${SINFONIA_APP_UPSTREAMS[$i]}"
            echo ""
        done
    } > conf/gateway.conf

    print_status "Finished generating conf/gateway.conf"
}

generate_docker_compose() {
    local i j external_port
    local first_listen="${SINFONIA_APP_LISTEN_PORTS[0]}"

    print_status "Generating docker-compose.yml..."

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
        for j in "${!SINFONIA_APP_IDS[@]}"; do
            external_port=$((SINFONIA_APP_EXTERNAL_PORTS[j] + i - 1))
            cat >> docker-compose.yml << EOF
      - "${external_port}:${SINFONIA_APP_LISTEN_PORTS[$j]}"
EOF
        done
        cat >> docker-compose.yml << EOF
    volumes:
      - ./conf/gateway.conf:/etc/nginx/conf.d/default.conf:ro
    networks:
      - arpeggio-internal
    healthcheck:
      test: ["CMD-SHELL", "wget -q --spider http://127.0.0.1:${first_listen}/ || exit 1"]
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
    local ports_csv=""
    local ids_csv=""

    mkdir -p scripts

    for i in "${!SINFONIA_APP_IDS[@]}"; do
        if [ -n "$ports_csv" ]; then
            ports_csv+=","
            ids_csv+=","
        fi
        ports_csv+="${SINFONIA_APP_EXTERNAL_PORTS[$i]}"
        ids_csv+="${SINFONIA_APP_IDS[$i]}"
    done

    print_status "Generating scripts/wait-for-nginx.sh..."
    cat > scripts/wait-for-nginx.sh << EOF
#!/bin/bash

set -euo pipefail

NUM_NODES=${num_nginx_nodes}
APP_IDS=(${ids_csv//,/ })
BASE_PORTS=(${ports_csv//,/ })
MAX_ATTEMPTS=30

for i in \$(seq 1 "\$NUM_NODES"); do
    for idx in "\${!APP_IDS[@]}"; do
        port=\$((BASE_PORTS[idx] + i - 1))
        app="\${APP_IDS[idx]}"
        attempt=0
        until curl -fsS "http://localhost:\${port}/" >/dev/null 2>&1 || [ "\$attempt" -ge "\$MAX_ATTEMPTS" ]; do
            attempt=\$((attempt + 1))
            echo "Waiting for nginx-gateway-\${i} client \${app} on port \${port}... (\${attempt}/\${MAX_ATTEMPTS})"
            sleep 2
        done

        if [ "\$attempt" -ge "\$MAX_ATTEMPTS" ]; then
            echo "Nginx gateway node \${i} client \${app} did not become ready on port \${port}"
            exit 1
        fi

        echo "Nginx gateway node \${i} client \${app} is ready on port \${port}"
    done
done
EOF

    print_status "Generating scripts/health-check.sh..."
    cat > scripts/health-check.sh << EOF
#!/bin/bash

set -euo pipefail

NUM_NODES=${num_nginx_nodes}
APP_IDS=(${ids_csv//,/ })
BASE_PORTS=(${ports_csv//,/ })
all_healthy=true

for i in \$(seq 1 "\$NUM_NODES"); do
    for idx in "\${!APP_IDS[@]}"; do
        port=\$((BASE_PORTS[idx] + i - 1))
        app="\${APP_IDS[idx]}"
        if curl -fsS "http://localhost:\${port}/" >/dev/null 2>&1; then
            echo "[OK] nginx-gateway-\${i} client \${app} responding on port \${port}"
        else
            echo "[FAIL] nginx-gateway-\${i} client \${app} not responding on port \${port}"
            all_healthy=false
        fi
    done
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

APP_IDS=(${ids_csv//,/ })
BASE_PORTS=(${ports_csv//,/ })

check_route() {
    local label="\$1"
    local base_port="\$2"
    local path="\$3"
    local expected_codes="\$4"

    status_code=\$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:\${base_port}\${path}")
    if echo "\${expected_codes}" | grep -qw "\${status_code}"; then
        echo "[OK] \${label} -> \${path} (HTTP \${status_code})"
    else
        echo "[WARN] \${label} -> \${path} (HTTP \${status_code}, expected one of: \${expected_codes})"
    fi
}

for idx in "\${!APP_IDS[@]}"; do
    app="\${APP_IDS[idx]}"
    port="\${BASE_PORTS[idx]}"
    echo "Checking gateway routes for client \${app} on port \${port}..."
    check_route "\${app} root" "\$port" "/" "200 301 302 404 502 503 504"
    check_route "\${app} assets" "\$port" "/assets/" "200 301 302 404 502 503 504"
    check_route "\${app} API" "\$port" "/api/" "200 301 302 404 405 502 503 504"
    check_route "\${app} media API" "\$port" "/api/auxiliary/media/" "200 301 302 404 405 502 503 504"
    check_route "\${app} WebSocket path" "\$port" "/ws/" "400 426 502 503 504"
done
EOF

    chmod +x scripts/*.sh
    print_status "Finished generating setup scripts"
}

generate_readme() {
    local i
    local rows=""
    local upstream_rows=""

    for i in "${!SINFONIA_APP_IDS[@]}"; do
        rows+="| \`${SINFONIA_APP_EXTERNAL_PORTS[$i]}\` | ${SINFONIA_APP_UPSTREAMS[$i]} | Sinfonia client \`${SINFONIA_APP_IDS[$i]}\` |
"
        upstream_rows+="- ${SINFONIA_APP_IDS[$i]}: ${num_frontend_backends} server(s) at \`${SINFONIA_APP_CONTAINERS[$i]}\` port ${FRONTEND_UPSTREAM_PORT}
"
    done

    cat > README.md << EOF
# Nginx Gateway Cluster

Generated Nginx reverse proxy / load balancer for the Arpeggio stack.

## Entry points

| Host port | Upstream SPA | Purpose |
|-----------|--------------|---------|
${rows}
Each entry point exposes the same API/WebSocket routes.

## Routes (per entry point)

| Path | Upstream | Purpose |
|------|----------|---------|
| \`/\` | selected client | Sinfonia SPA for that entry point |
| \`/assets/\` | selected client | Static assets for that SPA |
| \`/api/\` | api | Maestro REST API |
| \`/api/auxiliary/media/\` | api | Media uploads/downloads |
| \`/ws/\` | maestroWebsocket | Maestro WebSocket server |

## Upstreams

${upstream_rows}- API: ${num_api_backends} server(s) at \`${API_UPSTREAM_HOST}\` port ${API_UPSTREAM_PORT}
- WebSocket: ${num_websocket_backends} server(s) at \`${WEBSOCKET_UPSTREAM_HOST}\` port ${WEBSOCKET_UPSTREAM_PORT}

## Gateway nodes

- ${num_nginx_nodes} Nginx node(s)
- Client apps: ${SINFONIA_CLIENT_APPS}

## Start

\`\`\`bash
docker-compose up -d
./scripts/wait-for-nginx.sh
./scripts/health-check.sh
./scripts/route-check.sh
\`\`\`

## Application integration

Attach Maestro, Sinfonia, and other application containers to the shared Docker network:

\`\`\`
${DOCKER_INTERNAL_NETWORK}
\`\`\`

When using multiple upstream replicas, name services using the \`-1\`, \`-2\`, ... suffix pattern configured by the generator.

## Generated files

- \`conf/gateway.conf\`
- \`docker-compose.yml\`
- \`scripts/wait-for-nginx.sh\`
- \`scripts/health-check.sh\`
- \`scripts/route-check.sh\`
EOF
}

main() {
    local i

    echo -e ""
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${BLUE}              xCloud Nginx Gateway Cluster Generator${NC}"
    echo -e "${BLUE}================================================================${NC}"
    echo -e "This script will generate a dynamic Nginx gateway configuration."
    echo -e "Each selected Sinfonia client gets its own host port for / and /assets/."
    echo -e "All client ports also route:"
    echo -e "- ${GREEN}/api/${NC} -> Maestro API"
    echo -e "- ${GREEN}/api/auxiliary/media/${NC} -> Maestro media API"
    echo -e "- ${GREEN}/ws/${NC} -> Maestro WebSocket server"
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
        print_status "Sinfonia ${SINFONIA_APP_IDS[$i]}: http://localhost:${SINFONIA_APP_EXTERNAL_PORTS[$i]}"
    done
    print_status "Shared network: ${DOCKER_INTERNAL_NETWORK}"
    echo ""
    print_status "Thank you for using xCloud Nginx Gateway Cluster Generator"
    echo ""
    echo -e "${GREEN}================================================================${NC}"
    echo ""
}

main "$@"
