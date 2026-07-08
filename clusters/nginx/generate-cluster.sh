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
MAESTRO_ENV_FILE="${MAESTRO_ENV_FILE:-${SCRIPT_DIR}/../../apps/maestro/.env}"

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

NGINX_IMAGE="${NGINX_IMAGE:-nginx:1.27-alpine}"
NGINX_LISTEN_PORT="${NGINX_LISTEN_PORT:-80}"
FRONTEND_UPSTREAM_HOST="${FRONTEND_UPSTREAM_HOST:-frontend}"
FRONTEND_UPSTREAM_PORT="${FRONTEND_UPSTREAM_PORT:-80}"
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
DOCKER_INTERNAL_NETWORK="${DOCKER_INTERNAL_NETWORK:-arpeggio_internal_network}"

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

print_configuration_summary() {
    echo -e ""
    print_status "Configuration Summary:"
    print_status "- Nginx gateway nodes: ${GREEN}${num_nginx_nodes}${NC}"
    print_status "- Nginx external base port: ${GREEN}${nginx_external_port}${NC}"
    print_status "- Frontend upstream servers: ${GREEN}${num_frontend_backends}${NC} (${FRONTEND_UPSTREAM_HOST}:${FRONTEND_UPSTREAM_PORT})"
    print_status "- API upstream servers: ${GREEN}${num_api_backends}${NC} (${API_UPSTREAM_HOST}:${API_UPSTREAM_PORT})"
    print_status "- WebSocket upstream servers: ${GREEN}${num_websocket_backends}${NC} (${WEBSOCKET_UPSTREAM_HOST}:${WEBSOCKET_UPSTREAM_PORT})"
    print_status "- Nginx image: ${GREEN}${NGINX_IMAGE}${NC}"
    print_status "- Gateway network: ${GREEN}${DOCKER_INTERNAL_NETWORK}${NC}"
    print_status "- API load balance method: ${GREEN}${API_LOAD_BALANCE_METHOD}${NC}"
    print_status "- WebSocket load balance method: ${GREEN}${WEBSOCKET_LOAD_BALANCE_METHOD}${NC}"
    print_status "- Frontend load balance method: ${GREEN}${FRONTEND_LOAD_BALANCE_METHOD}${NC}"
    if [ "$num_nginx_nodes" -gt 1 ]; then
        print_status "- Gateway node ports: ${GREEN}$(for i in $(seq 1 "$num_nginx_nodes"); do echo -n "$((nginx_external_port + i - 1))"; if [ "$i" -lt "$num_nginx_nodes" ]; then echo -n ", "; fi; done)${NC}"
    fi
    echo -e "${BLUE}================================================================${NC}"
    echo ""
}

get_user_input() {
    if [ "${NGINX_DEPLOY_MODE:-false}" = "true" ]; then
        num_nginx_nodes="${NGINX_NUM_NODES:-1}"
        nginx_external_port="${NGINX_EXTERNAL_PORT:-80}"
        num_frontend_backends="${NGINX_NUM_FRONTEND_BACKENDS:-1}"
        num_api_backends="${NGINX_NUM_API_BACKENDS:-1}"
        num_websocket_backends="${NGINX_NUM_WEBSOCKET_BACKENDS:-1}"

        validate_number "$num_nginx_nodes" 1 5 || exit 1
        validate_number "$nginx_external_port" 0 65535 || exit 1
        validate_number "$num_frontend_backends" 1 10 || exit 1
        validate_number "$num_api_backends" 1 10 || exit 1
        validate_number "$num_websocket_backends" 1 10 || exit 1

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
        read -p "Enter Nginx external base port (0-65535) [default: 80]: " nginx_external_port
        nginx_external_port=${nginx_external_port:-80}
        if validate_number "$nginx_external_port" 0 65535; then
            break
        fi
    done

    while true; do
        read -p "Enter number of frontend upstream servers (1-10) [default: 1]: " num_frontend_backends
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

generate_gateway_conf() {
    local frontend_method_line api_method_line websocket_method_line

    mkdir -p conf

    frontend_method_line="$(normalize_load_balance_method "$FRONTEND_LOAD_BALANCE_METHOD")"
    api_method_line="$(normalize_load_balance_method "$API_LOAD_BALANCE_METHOD")"
    websocket_method_line="$(normalize_load_balance_method "$WEBSOCKET_LOAD_BALANCE_METHOD")"

    print_status "Generating conf/gateway.conf..."

    {
        generate_upstream_block "frontend" "$FRONTEND_UPSTREAM_HOST" "$FRONTEND_UPSTREAM_PORT" "$num_frontend_backends" "$frontend_method_line"
        generate_upstream_block "api" "$API_UPSTREAM_HOST" "$API_UPSTREAM_PORT" "$num_api_backends" "$api_method_line"
        generate_upstream_block "maestroWebsocket" "$WEBSOCKET_UPSTREAM_HOST" "$WEBSOCKET_UPSTREAM_PORT" "$num_websocket_backends" "$websocket_method_line"

        cat <<EOF
server {
    listen ${NGINX_LISTEN_PORT};
    server_name _;

    # ---------------- GLOBAL PROXY SETTINGS ----------------
    proxy_http_version 1.1;

    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;

    proxy_connect_timeout ${PROXY_CONNECT_TIMEOUT};
    proxy_send_timeout ${PROXY_SEND_TIMEOUT};
    proxy_read_timeout ${PROXY_READ_TIMEOUT};

    # ---------------- FRONTEND SPA ----------------
    location / {
        proxy_pass http://frontend;
    }

    # ---------------- STATIC ASSETS ----------------
    location /assets/ {
        proxy_pass http://frontend;

        proxy_buffering off;

        expires ${STATIC_ASSETS_EXPIRES};
        access_log off;

        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    # ---------------- API ----------------
    location /api/ {
        proxy_pass http://api;
        client_max_body_size ${CLIENT_MAX_BODY_SIZE};

        proxy_buffering off;
    }

    # ---------------- MEDIA (IMPORTANT FIX) ----------------
    location /api/auxiliary/media/ {
        proxy_pass http://api;

        proxy_buffering off;

        proxy_set_header Connection "";
    }

    # ---------------- WEBSOCKETS ----------------
    location /ws/ {
        # Trailing slash strips the /ws/ prefix before forwarding (same as
        # sinfonia vite dev proxy rewrite). Without it the WS server receives
        # /ws/{token}/{lang} and treats "ws" as the JWT.
        proxy_pass http://maestroWebsocket/;

        proxy_http_version 1.1;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_read_timeout ${WEBSOCKET_READ_TIMEOUT};
        proxy_send_timeout ${WEBSOCKET_SEND_TIMEOUT};
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
    mkdir -p scripts

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
check_route "Frontend root" "/" "200 301 302 404 502 503 504"
check_route "Static assets" "/assets/" "200 301 302 404 502 503 504"
check_route "API" "/api/" "200 301 302 404 405 502 503 504"
check_route "Media API" "/api/auxiliary/media/" "200 301 302 404 405 502 503 504"
check_route "WebSocket path" "/ws/" "400 426 502 503 504"
EOF

    chmod +x scripts/*.sh
    print_status "Finished generating setup scripts"
}

generate_readme() {
    cat > README.md << EOF
# Nginx Gateway Cluster

Generated Nginx reverse proxy / load balancer for the Arpeggio stack.

## Routes

| Path | Upstream | Purpose |
|------|----------|---------|
| \`/\` | frontend | Sinfonia SPA |
| \`/assets/\` | frontend | Static assets |
| \`/api/\` | api | Maestro REST API |
| \`/api/auxiliary/media/\` | api | Media uploads/downloads |
| \`/ws/\` | maestroWebsocket | Maestro WebSocket server |

## Upstreams

- Frontend: ${num_frontend_backends} server(s) at \`${FRONTEND_UPSTREAM_HOST}\` port ${FRONTEND_UPSTREAM_PORT}
- API: ${num_api_backends} server(s) at \`${API_UPSTREAM_HOST}\` port ${API_UPSTREAM_PORT}
- WebSocket: ${num_websocket_backends} server(s) at \`${WEBSOCKET_UPSTREAM_HOST}\` port ${WEBSOCKET_UPSTREAM_PORT}

## Gateway nodes

- ${num_nginx_nodes} Nginx node(s)
- External base port: ${nginx_external_port}

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
    echo -e ""
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${BLUE}              xCloud Nginx Gateway Cluster Generator${NC}"
    echo -e "${BLUE}================================================================${NC}"
    echo -e "This script will generate a dynamic Nginx gateway configuration."
    echo -e "The gateway will route:"
    echo -e "- ${GREEN}/${NC} and ${GREEN}/assets/${NC} -> Sinfonia frontend"
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
    print_status "Gateway URL: http://localhost:${nginx_external_port}"
    print_status "Shared network: ${DOCKER_INTERNAL_NETWORK}"
    echo ""
    print_status "Thank you for using xCloud Nginx Gateway Cluster Generator"
    echo ""
    echo -e "${GREEN}================================================================${NC}"
    echo ""
}

main "$@"
