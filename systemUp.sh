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
# shellcheck source=lib/sinfonia-client-apps.sh
source "${SCRIPT_DIR}/lib/sinfonia-client-apps.sh"
DEPLOY_DIR="${SCRIPT_DIR}/deploy"
ARMONIA_DIR="${DEPLOY_DIR}/armonia"
MAESTRO_DIR="${DEPLOY_DIR}/maestro"
SINFONIA_DIR="${DEPLOY_DIR}/sinfonia"
SINFONIA_APPS_ENV_FILE="${DEPLOY_DIR}/scripts/sinfonia-apps.env"
MAESTRO_DOCKERFILE="${SCRIPT_DIR}/apps/maestro/Dockerfile"
SINFONIA_DOCKERFILE="${SCRIPT_DIR}/apps/sinfonia/Dockerfile"
MAESTRO_IMAGE="${ARPEGGIO_MAESTRO_IMAGE:-arpeggio-maestro:latest}"
SERVERS_COMPOSE_FILE="${DEPLOY_DIR}/docker-compose.servers.yml"
FRONTEND_COMPOSE_FILE="${DEPLOY_DIR}/docker-compose.frontend.yml"
SERVERS_COMPOSE_PROJECT="servers"
FRONTEND_COMPOSE_PROJECT="frontend"
COMPOSE_NETWORK_KEY="arpeggio-internal"
CLUSTER_ENV_CANDIDATES=(nginx mongo kafka redis clamv ollama prometheus)
KAFKA_CLUSTER_DIR="${SCRIPT_DIR}/clusters/kafka"
REDIS_CLUSTER_DIR="${SCRIPT_DIR}/clusters/redis"
MONGO_CLUSTER_DIR="${SCRIPT_DIR}/clusters/mongo"
CLAMAV_CLUSTER_DIR="${SCRIPT_DIR}/clusters/clamv"
OLLAMA_CLUSTER_DIR="${SCRIPT_DIR}/clusters/ollama"
NGINX_CLUSTER_DIR="${SCRIPT_DIR}/clusters/nginx"
PROMETHEUS_CLUSTER_DIR="${SCRIPT_DIR}/clusters/prometheus"
INFRA_CLUSTER_START_ORDER=(
    "MongoDB|${MONGO_CLUSTER_DIR}"
    "Redis|${REDIS_CLUSTER_DIR}"
    "Kafka|${KAFKA_CLUSTER_DIR}"
    "ClamAV|${CLAMAV_CLUSTER_DIR}"
    "Ollama|${OLLAMA_CLUSTER_DIR}"
    "Prometheus|${PROMETHEUS_CLUSTER_DIR}"
)

MAESTRO_API_CONTAINER="maestroApi"
MAESTRO_KAFKA_CONTAINER="maestroKafka"
MAESTRO_WEBSOCKET_CONTAINER="maestroWebsocket"
MAESTRO_CRON_CONTAINER="maestroCron"
MAESTRO_ASSISTANT_CONTAINER="maestroAssistant"
MAESTRO_TELEGRAM_CONTAINER="maestroTelegram"

STARTED_CLUSTERS=()
DOCKER_BUILD_NO_CACHE=false

for arg in "$@"; do
    case "$arg" in
        --no-cache)
            DOCKER_BUILD_NO_CACHE=true
            ;;
        -h|--help)
            echo "Usage: $0 [--no-cache]"
            echo "  --no-cache  Build Maestro and selected Sinfonia client images without Docker layer cache"
            exit 0
            ;;
        *)
            print_error "Unknown argument: $arg"
            echo "Usage: $0 [--no-cache]"
            exit 1
            ;;
    esac
done

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
    local i app_html

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

    if [ ! -f "$SINFONIA_APPS_ENV_FILE" ]; then
        print_error "Missing Sinfonia apps manifest: ${SINFONIA_APPS_ENV_FILE}"
        print_error "Run ./deploy.sh and choose which client apps to deploy."
        missing=1
    elif ! load_sinfonia_apps_manifest "$SINFONIA_APPS_ENV_FILE"; then
        print_error "Invalid Sinfonia apps manifest: ${SINFONIA_APPS_ENV_FILE}"
        missing=1
    else
        print_status "Sinfonia clients to deploy: $(build_sinfonia_client_apps_spec)"
        for i in "${!SINFONIA_APP_IDS[@]}"; do
            app_html="${SINFONIA_DIR}/src/apps/${SINFONIA_APP_IDS[$i]}/index.html"
            if [ ! -f "$app_html" ]; then
                print_error "Selected client \"${SINFONIA_APP_IDS[$i]}\" is missing ${app_html}"
                missing=1
            else
                print_status "Found client ${SINFONIA_APP_IDS[$i]} -> ${SINFONIA_APP_IMAGES[$i]}"
            fi
        done
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

    local build_args=(-f "$MAESTRO_DOCKERFILE" -t "$MAESTRO_IMAGE")
    if [ "$DOCKER_BUILD_NO_CACHE" = "true" ]; then
        build_args+=(--no-cache)
        print_status "Building without cache (--no-cache)"
    fi

    docker build "${build_args[@]}" "$DEPLOY_DIR"

    print_status "Maestro image built successfully"
}

build_sinfonia_app_image() {
    local app_id="$1"
    local image_tag="$2"

    print_status "Building Sinfonia app=${app_id} -> ${image_tag}"
    print_status "Dockerfile: ${SINFONIA_DOCKERFILE}"
    print_status "Context: ${DEPLOY_DIR}"

    local build_args=(
        -f "$SINFONIA_DOCKERFILE"
        -t "$image_tag"
        --build-arg "VITE_SINFONIA_APP=${app_id}"
    )
    if [ "$DOCKER_BUILD_NO_CACHE" = "true" ]; then
        build_args+=(--no-cache)
        print_status "Building without cache (--no-cache)"
    fi

    docker build "${build_args[@]}" "$DEPLOY_DIR"

    print_status "Sinfonia ${app_id} image built successfully"
}

build_sinfonia_image() {
    local i

    echo ""
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${BLUE}         Building Sinfonia client images (${#SINFONIA_APP_IDS[@]})${NC}"
    echo -e "${BLUE}================================================================${NC}"
    echo ""

    for i in "${!SINFONIA_APP_IDS[@]}"; do
        build_sinfonia_app_image "${SINFONIA_APP_IDS[$i]}" "${SINFONIA_APP_IMAGES[$i]}"
    done
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

  ${MAESTRO_ASSISTANT_CONTAINER}:
    image: ${MAESTRO_IMAGE}
    container_name: ${MAESTRO_ASSISTANT_CONTAINER}
    hostname: ${MAESTRO_ASSISTANT_CONTAINER}
    working_dir: /maestro
    command: ["npm", "run", "assistant"]
    env_file:
      - ./maestro/.env
    volumes:
      - ./maestro/secrets:/maestro/secrets:ro
    networks:
      - ${COMPOSE_NETWORK_KEY}
    restart: unless-stopped

  ${MAESTRO_TELEGRAM_CONTAINER}:
    image: ${MAESTRO_IMAGE}
    container_name: ${MAESTRO_TELEGRAM_CONTAINER}
    hostname: ${MAESTRO_TELEGRAM_CONTAINER}
    working_dir: /maestro
    command: ["npm", "run", "telegram"]
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
    local i

    print_status "Generating frontend compose file: ${FRONTEND_COMPOSE_FILE}"

    {
        cat <<EOF
version: '3.8'

services:
EOF
        for i in "${!SINFONIA_APP_IDS[@]}"; do
            cat <<EOF
  ${SINFONIA_APP_CONTAINERS[$i]}:
    image: ${SINFONIA_APP_IMAGES[$i]}
    container_name: ${SINFONIA_APP_CONTAINERS[$i]}
    hostname: ${SINFONIA_APP_CONTAINERS[$i]}
    networks:
      - ${COMPOSE_NETWORK_KEY}
    restart: unless-stopped

EOF
        done
        cat <<EOF
networks:
  ${COMPOSE_NETWORK_KEY}:
    external: true
    name: ${DOCKER_INTERNAL_NETWORK}
EOF
    } > "$FRONTEND_COMPOSE_FILE"
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
    local api_port websocket_port cluster i

    api_port="$(read_env_value "${MAESTRO_DIR}/.env" "SERVER_PORT")"
    websocket_port="$(read_env_value "${MAESTRO_DIR}/.env" "WEBSOCKET_PORT")"
    api_port="${api_port:-81}"
    websocket_port="${websocket_port:-82}"

    echo ""
    echo -e "${GREEN}================================================================${NC}"
    echo -e "${GREEN}                    System is up${NC}"
    echo -e "${GREEN}================================================================${NC}"
    echo ""
    echo -e "${BLUE}Images${NC}"
    echo "  - Maestro: ${MAESTRO_IMAGE}"
    for i in "${!SINFONIA_APP_IDS[@]}"; do
        echo "  - Sinfonia ${SINFONIA_APP_IDS[$i]}: ${SINFONIA_APP_IMAGES[$i]}"
    done
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
    echo "  - Assistant: ${MAESTRO_ASSISTANT_CONTAINER} -> npm run assistant"
    echo "  - Telegram:  ${MAESTRO_TELEGRAM_CONTAINER} -> npm run telegram"
    echo ""
    echo -e "${BLUE}Frontend${NC}"
    for i in "${!SINFONIA_APP_IDS[@]}"; do
        echo "  - ${SINFONIA_APP_CONTAINERS[$i]} (${SINFONIA_APP_IDS[$i]} SPA on port 80 inside the network)"
    done
    echo ""
    echo -e "${BLUE}Network${NC}"
    echo "  - ${DOCKER_INTERNAL_NETWORK}"
    echo ""
    if [ -f "${NGINX_CLUSTER_DIR}/docker-compose.yml" ]; then
        echo -e "${BLUE}Public entry points (Nginx gateway)${NC}"
        for i in "${!SINFONIA_APP_IDS[@]}"; do
            echo "  - ${SINFONIA_APP_IDS[$i]}: http://localhost:${SINFONIA_APP_EXTERNAL_PORTS[$i]}"
        done
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
