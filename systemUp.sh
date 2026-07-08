#!/bin/bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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
DEPLOY_DIR="${SCRIPT_DIR}/deploy"
ARMONIA_DIR="${DEPLOY_DIR}/armonia"
MAESTRO_DIR="${DEPLOY_DIR}/maestro"
SINFONIA_DIR="${DEPLOY_DIR}/sinfonia"
MAESTRO_DOCKERFILE="${SCRIPT_DIR}/apps/maestro/Dockerfile"
SINFONIA_DOCKERFILE="${SCRIPT_DIR}/apps/sinfonia/Dockerfile"
MAESTRO_IMAGE="${ARPEGGIO_MAESTRO_IMAGE:-arpeggio-maestro:latest}"
FRONTEND_IMAGE="${ARPEGGIO_FRONTEND_IMAGE:-arpeggio-frontend:latest}"
SERVERS_COMPOSE_FILE="${DEPLOY_DIR}/docker-compose.servers.yml"
FRONTEND_COMPOSE_FILE="${DEPLOY_DIR}/docker-compose.frontend.yml"
SERVERS_COMPOSE_PROJECT="servers"
FRONTEND_COMPOSE_PROJECT="frontend"
COMPOSE_NETWORK_KEY="arpeggio-internal"
CLUSTER_ENV_CANDIDATES=(nginx mongo kafka redis clamv prometheus)
KAFKA_CLUSTER_DIR="${SCRIPT_DIR}/clusters/kafka"
REDIS_CLUSTER_DIR="${SCRIPT_DIR}/clusters/redis"
MONGO_CLUSTER_DIR="${SCRIPT_DIR}/clusters/mongo"
CLAMAV_CLUSTER_DIR="${SCRIPT_DIR}/clusters/clamv"
NGINX_CLUSTER_DIR="${SCRIPT_DIR}/clusters/nginx"
PROMETHEUS_CLUSTER_DIR="${SCRIPT_DIR}/clusters/prometheus"
INFRA_CLUSTER_START_ORDER=(
    "MongoDB|${MONGO_CLUSTER_DIR}"
    "Redis|${REDIS_CLUSTER_DIR}"
    "Kafka|${KAFKA_CLUSTER_DIR}"
    "ClamAV|${CLAMAV_CLUSTER_DIR}"
    "Prometheus|${PROMETHEUS_CLUSTER_DIR}"
)

MAESTRO_API_CONTAINER="maestroApi"
MAESTRO_KAFKA_CONTAINER="maestroKafka"
MAESTRO_WEBSOCKET_CONTAINER="maestroWebsocket"
MAESTRO_CRON_CONTAINER="maestroCron"
SINFONIA_FRONTEND_CONTAINER="frontend"

STARTED_CLUSTERS=()

read_env_value() {
    local file="$1"
    local key="$2"

    grep -E "^${key}=" "$file" 2>/dev/null | head -1 | cut -d= -f2-
}

docker_compose() {
    if docker compose version >/dev/null 2>&1; then
        docker compose "$@"
    elif command -v docker-compose >/dev/null 2>&1; then
        docker-compose "$@"
    else
        print_error "Docker Compose is not installed."
        exit 1
    fi
}

validate_deploy_sources() {
    local missing=0

    echo ""
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${BLUE}                 Validating deploy sources${NC}"
    echo -e "${BLUE}================================================================${NC}"
    echo ""

    if [ ! -d "$ARMONIA_DIR" ]; then
        print_error "Missing deploy source: ${ARMONIA_DIR}"
        missing=1
    else
        print_status "Found Armonia: ${ARMONIA_DIR}"
    fi

    if [ ! -d "$MAESTRO_DIR" ]; then
        print_error "Missing deploy source: ${MAESTRO_DIR}"
        missing=1
    else
        print_status "Found Maestro: ${MAESTRO_DIR}"
    fi

    if [ ! -d "$SINFONIA_DIR" ]; then
        print_error "Missing deploy source: ${SINFONIA_DIR}"
        missing=1
    else
        print_status "Found Sinfonia: ${SINFONIA_DIR}"
    fi

    if [ ! -f "${MAESTRO_DIR}/.env" ]; then
        print_error "Missing Maestro env file: ${MAESTRO_DIR}/.env"
        print_error "Run ./deploy.sh first to prepare deployment sources."
        missing=1
    else
        print_status "Found Maestro env: ${MAESTRO_DIR}/.env"
    fi

    if [ ! -f "$MAESTRO_DOCKERFILE" ]; then
        print_error "Missing Dockerfile: ${MAESTRO_DOCKERFILE}"
        missing=1
    fi

    if [ ! -f "$SINFONIA_DOCKERFILE" ]; then
        print_error "Missing Sinfonia Dockerfile: ${SINFONIA_DOCKERFILE}"
        missing=1
    fi

    if [ "$missing" -ne 0 ]; then
        exit 1
    fi
}

load_internal_network_name() {
    local cluster_dir env_file network_name network_source=""

    if [ -n "${DOCKER_INTERNAL_NETWORK:-}" ]; then
        print_status "Docker internal network: ${DOCKER_INTERNAL_NETWORK} (from environment)"
        return 0
    fi

    for cluster_dir in "${CLUSTER_ENV_CANDIDATES[@]}"; do
        env_file="${SCRIPT_DIR}/clusters/${cluster_dir}/.env"
        if [ ! -f "$env_file" ]; then
            continue
        fi

        network_name="$(read_env_value "$env_file" "DOCKER_INTERNAL_NETWORK")"
        if [ -n "$network_name" ]; then
            DOCKER_INTERNAL_NETWORK="$network_name"
            network_source="$env_file"
            break
        fi
    done

    if [ -z "${DOCKER_INTERNAL_NETWORK:-}" ]; then
        print_error "Could not resolve DOCKER_INTERNAL_NETWORK from cluster configuration."
        print_error "Run ./deploy.sh first to configure cluster .env files."
        exit 1
    fi

    print_status "Docker internal network: ${DOCKER_INTERNAL_NETWORK} (from ${network_source})"
}

ensure_internal_network() {
    if docker network inspect "$DOCKER_INTERNAL_NETWORK" >/dev/null 2>&1; then
        print_status "Docker network already exists: ${DOCKER_INTERNAL_NETWORK}"
        return 0
    fi

    print_status "Creating Docker network: ${DOCKER_INTERNAL_NETWORK}"
    docker network create "$DOCKER_INTERNAL_NETWORK" >/dev/null
}

prepare_maestro_build_context() {
    local manifest_dest="${DEPLOY_DIR}/scripts/modules.manifest.json"
    local manifest_src=""

    if [ -f "$manifest_dest" ]; then
        print_status "Using deployment-generated module manifest: ${manifest_dest}"
        sync_maestro_build_scripts
        return 0
    fi

    if [ -f "${SCRIPT_DIR}/scripts/modules.manifest.json" ]; then
        manifest_src="${SCRIPT_DIR}/scripts/modules.manifest.json"
    elif [ -f "${SCRIPT_DIR}/apps/maestro/scripts/modules.manifest.json" ]; then
        manifest_src="${SCRIPT_DIR}/apps/maestro/scripts/modules.manifest.json"
    elif [ -f "${MAESTRO_DIR}/scripts/modules.manifest.json" ]; then
        manifest_src="${MAESTRO_DIR}/scripts/modules.manifest.json"
    fi

    if [ -z "$manifest_src" ]; then
        print_error "Missing modules.manifest.json for Maestro image build."
        print_error "Run ./deploy.sh first to generate ${manifest_dest}, or place a manifest at:"
        print_error "  ${SCRIPT_DIR}/scripts/modules.manifest.json"
        print_error "  ${SCRIPT_DIR}/apps/maestro/scripts/modules.manifest.json"
        exit 1
    fi

    mkdir -p "${DEPLOY_DIR}/scripts"
    cp "$manifest_src" "$manifest_dest"
    sync_maestro_build_scripts
    print_status "Prepared Maestro build manifest: ${manifest_dest}"
}

sync_maestro_build_scripts() {
    local scripts_src="${SCRIPT_DIR}/apps/maestro/scripts"
    local scripts_dest="${DEPLOY_DIR}/scripts"

    if [ ! -d "$scripts_src" ]; then
        return 0
    fi

    mkdir -p "$scripts_dest"

    for script_file in "$scripts_src"/*; do
        if [ -f "$script_file" ]; then
            cp "$script_file" "$scripts_dest/"
        fi
    done

    chmod +x "$scripts_dest"/*.sh 2>/dev/null || true
    print_status "Synced Maestro build scripts to ${scripts_dest}"
}

build_maestro_image() {
    echo ""
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${BLUE}                 Building Maestro image${NC}"
    echo -e "${BLUE}================================================================${NC}"
    echo ""

    print_status "Image: ${MAESTRO_IMAGE}"
    print_status "Dockerfile: ${MAESTRO_DOCKERFILE}"
    print_status "Context: ${DEPLOY_DIR}"

    docker build \
        -f "$MAESTRO_DOCKERFILE" \
        -t "$MAESTRO_IMAGE" \
        "$DEPLOY_DIR"

    print_status "Maestro image built successfully"
}

build_sinfonia_image() {
    echo ""
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${BLUE}                 Building Sinfonia image${NC}"
    echo -e "${BLUE}================================================================${NC}"
    echo ""

    print_status "Image: ${FRONTEND_IMAGE}"
    print_status "Dockerfile: ${SINFONIA_DOCKERFILE}"
    print_status "Context: ${DEPLOY_DIR}"

    docker build \
        -f "$SINFONIA_DOCKERFILE" \
        -t "$FRONTEND_IMAGE" \
        "$DEPLOY_DIR"

    print_status "Sinfonia image built successfully"
}

validate_cluster_bind_mounts() {
    local cluster_dir="$1"
    local compose_file="${cluster_dir}/docker-compose.yml"
    local line host_path abs_path base_name
    local failed=0

    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line#- }"
        host_path="${line%%:*}"
        host_path="${host_path#./}"

        base_name="$(basename "$host_path")"
        if [[ "$base_name" != *.* ]]; then
            continue
        fi

        abs_path="${cluster_dir}/${host_path}"
        if [ -d "$abs_path" ]; then
            print_error "Bind mount path is a directory, expected a file: ${abs_path}"
            print_error "Fix: cd ${cluster_dir} && rm -rf \"${host_path}\" && ./generate-cluster.sh"
            failed=1
        elif [ ! -f "$abs_path" ]; then
            print_error "Missing bind mount file: ${abs_path}"
            print_error "Fix: cd ${cluster_dir} && ./generate-cluster.sh"
            failed=1
        fi
    done < <(grep -E '^\s+- \./[^:]+:' "$compose_file" 2>/dev/null || true)

    return "$failed"
}

start_cluster_if_generated() {
    local label="$1"
    local cluster_dir="$2"
    local compose_file="${cluster_dir}/docker-compose.yml"

    if [ ! -f "$compose_file" ]; then
        print_status "Skipping ${label}: no generated docker-compose.yml"
        return 0
    fi

    if ! validate_cluster_bind_mounts "$cluster_dir"; then
        print_error "Skipping ${label}: bind mount validation failed"
        return 1
    fi

    echo ""
    print_status "Starting ${label} cluster (${cluster_dir})"
    (
        cd "$cluster_dir"
        docker_compose up -d --build
    )

    STARTED_CLUSTERS+=("$label")
    print_status "${label} cluster is up"
}

start_infrastructure_clusters() {
    local cluster_spec label cluster_dir

    echo ""
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${BLUE}            Starting infrastructure clusters${NC}"
    echo -e "${BLUE}================================================================${NC}"

    for cluster_spec in "${INFRA_CLUSTER_START_ORDER[@]}"; do
        label="${cluster_spec%%|*}"
        cluster_dir="${cluster_spec#*|}"
        if ! start_cluster_if_generated "$label" "$cluster_dir"; then
            print_warning "${label} was not started due to validation errors"
        fi
    done
}

start_gateway_cluster() {
    echo ""
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${BLUE}                 Starting Nginx gateway${NC}"
    echo -e "${BLUE}================================================================${NC}"

    if ! start_cluster_if_generated "Nginx gateway" "$NGINX_CLUSTER_DIR"; then
        print_warning "Nginx gateway was not started due to validation errors"
    fi
}

start_full_stack() {
    start_infrastructure_clusters
    start_application_stack
    start_gateway_cluster
}

generate_servers_compose() {
    print_status "Generating servers compose file: ${SERVERS_COMPOSE_FILE}"

    cat > "$SERVERS_COMPOSE_FILE" <<EOF
version: '3.8'

services:
  ${MAESTRO_API_CONTAINER}:
    image: ${MAESTRO_IMAGE}
    container_name: ${MAESTRO_API_CONTAINER}
    hostname: ${MAESTRO_API_CONTAINER}
    working_dir: /maestro
    command: ["npm", "run", "api"]
    env_file:
      - ./maestro/.env
    volumes:
      - ./maestro/secrets:/maestro/secrets:ro
    networks:
      - ${COMPOSE_NETWORK_KEY}
    restart: unless-stopped

  ${MAESTRO_KAFKA_CONTAINER}:
    image: ${MAESTRO_IMAGE}
    container_name: ${MAESTRO_KAFKA_CONTAINER}
    hostname: ${MAESTRO_KAFKA_CONTAINER}
    working_dir: /maestro
    command: ["npm", "run", "kafka"]
    env_file:
      - ./maestro/.env
    volumes:
      - ./maestro/secrets:/maestro/secrets:ro
    networks:
      - ${COMPOSE_NETWORK_KEY}
    restart: unless-stopped

  ${MAESTRO_WEBSOCKET_CONTAINER}:
    image: ${MAESTRO_IMAGE}
    container_name: ${MAESTRO_WEBSOCKET_CONTAINER}
    hostname: ${MAESTRO_WEBSOCKET_CONTAINER}
    working_dir: /maestro
    command: ["npm", "run", "websocket"]
    env_file:
      - ./maestro/.env
    volumes:
      - ./maestro/secrets:/maestro/secrets:ro
    networks:
      - ${COMPOSE_NETWORK_KEY}
    restart: unless-stopped

  ${MAESTRO_CRON_CONTAINER}:
    image: ${MAESTRO_IMAGE}
    container_name: ${MAESTRO_CRON_CONTAINER}
    hostname: ${MAESTRO_CRON_CONTAINER}
    working_dir: /maestro
    command: ["npm", "run", "cron"]
    env_file:
      - ./maestro/.env
    volumes:
      - ./maestro/secrets:/maestro/secrets:ro
    networks:
      - ${COMPOSE_NETWORK_KEY}
    restart: unless-stopped

networks:
  ${COMPOSE_NETWORK_KEY}:
    external: true
    name: ${DOCKER_INTERNAL_NETWORK}
EOF
}

generate_frontend_compose() {
    print_status "Generating frontend compose file: ${FRONTEND_COMPOSE_FILE}"

    cat > "$FRONTEND_COMPOSE_FILE" <<EOF
version: '3.8'

services:
  ${SINFONIA_FRONTEND_CONTAINER}:
    image: ${FRONTEND_IMAGE}
    container_name: ${SINFONIA_FRONTEND_CONTAINER}
    hostname: ${SINFONIA_FRONTEND_CONTAINER}
    networks:
      - ${COMPOSE_NETWORK_KEY}
    restart: unless-stopped

networks:
  ${COMPOSE_NETWORK_KEY}:
    external: true
    name: ${DOCKER_INTERNAL_NETWORK}
EOF
}

generate_application_compose_files() {
    generate_servers_compose
    generate_frontend_compose
}

start_application_stack() {
    echo ""
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${BLUE}                 Starting application stack${NC}"
    echo -e "${BLUE}================================================================${NC}"
    echo ""

    (
        cd "$DEPLOY_DIR"
        docker_compose -p "$SERVERS_COMPOSE_PROJECT" -f "$SERVERS_COMPOSE_FILE" up -d
        docker_compose -p "$FRONTEND_COMPOSE_PROJECT" -f "$FRONTEND_COMPOSE_FILE" up -d
    )

    print_status "Application stack started (projects: ${SERVERS_COMPOSE_PROJECT}, ${FRONTEND_COMPOSE_PROJECT})"
}

print_system_up_summary() {
    local api_port websocket_port nginx_port cluster

    api_port="$(read_env_value "${MAESTRO_DIR}/.env" "SERVER_PORT")"
    websocket_port="$(read_env_value "${MAESTRO_DIR}/.env" "WEBSOCKET_PORT")"
    api_port="${api_port:-81}"
    websocket_port="${websocket_port:-82}"
    nginx_port="$(read_env_value "${NGINX_CLUSTER_DIR}/.env" "NGINX_LISTEN_PORT")"
    nginx_port="${nginx_port:-80}"

    echo ""
    echo -e "${GREEN}================================================================${NC}"
    echo -e "${GREEN}                    System is up${NC}"
    echo -e "${GREEN}================================================================${NC}"
    echo ""
    echo -e "${BLUE}Images${NC}"
    echo "  - Maestro:  ${MAESTRO_IMAGE}"
    echo "  - Frontend: ${FRONTEND_IMAGE}"
    echo ""
    if [ "${#STARTED_CLUSTERS[@]}" -gt 0 ]; then
        echo -e "${BLUE}Infrastructure clusters started${NC}"
        for cluster in "${STARTED_CLUSTERS[@]}"; do
            echo "  - ${cluster}"
        done
        echo ""
    fi
    echo -e "${BLUE}Maestro services (shared image)${NC}"
    echo "  - API:       ${MAESTRO_API_CONTAINER}  -> npm run api        (port ${api_port})"
    echo "  - Kafka:     ${MAESTRO_KAFKA_CONTAINER} -> npm run kafka"
    echo "  - WebSocket: ${MAESTRO_WEBSOCKET_CONTAINER} -> npm run websocket (port ${websocket_port})"
    echo "  - Cron:      ${MAESTRO_CRON_CONTAINER} -> npm run cron"
    echo ""
    echo -e "${BLUE}Frontend${NC}"
    echo "  - ${SINFONIA_FRONTEND_CONTAINER} (Sinfonia SPA on port 80 inside the network)"
    echo ""
    echo -e "${BLUE}Network${NC}"
    echo "  - ${DOCKER_INTERNAL_NETWORK}"
    echo ""
    if [ -f "${NGINX_CLUSTER_DIR}/docker-compose.yml" ]; then
        echo -e "${BLUE}Public entry point${NC}"
        echo "  - Nginx gateway: http://localhost:${nginx_port}"
        echo ""
    fi
    echo -e "${BLUE}Manage Maestro servers${NC}"
    echo "  - Status:  cd ${DEPLOY_DIR} && docker compose -p ${SERVERS_COMPOSE_PROJECT} -f docker-compose.servers.yml ps"
    echo "  - Logs:    cd ${DEPLOY_DIR} && docker compose -p ${SERVERS_COMPOSE_PROJECT} -f docker-compose.servers.yml logs -f"
    echo "  - Stop:    cd ${DEPLOY_DIR} && docker compose -p ${SERVERS_COMPOSE_PROJECT} -f docker-compose.servers.yml down"
    echo ""
    echo -e "${BLUE}Manage frontend${NC}"
    echo "  - Status:  cd ${DEPLOY_DIR} && docker compose -p ${FRONTEND_COMPOSE_PROJECT} -f docker-compose.frontend.yml ps"
    echo "  - Logs:    cd ${DEPLOY_DIR} && docker compose -p ${FRONTEND_COMPOSE_PROJECT} -f docker-compose.frontend.yml logs -f"
    echo "  - Stop:    cd ${DEPLOY_DIR} && docker compose -p ${FRONTEND_COMPOSE_PROJECT} -f docker-compose.frontend.yml down"
    echo ""
    echo -e "${BLUE}Manage infrastructure clusters${NC}"
    echo "  - Example: cd ${MONGO_CLUSTER_DIR} && docker compose ps"
    echo "  - Example: cd ${NGINX_CLUSTER_DIR} && docker compose logs -f"
    echo -e "${GREEN}================================================================${NC}"
    echo ""
}

main() {
    echo ""
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${BLUE}                    Arpeggio systemUp${NC}"
    echo -e "${BLUE}================================================================${NC}"

    validate_deploy_sources
    load_internal_network_name
    ensure_internal_network
    prepare_maestro_build_context
    build_maestro_image
    build_sinfonia_image
    generate_application_compose_files
    start_full_stack
    print_system_up_summary
}

main "$@"
