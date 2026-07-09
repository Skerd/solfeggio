#!/bin/bash

set -euo pipefail

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
DEPLOY_DIR="${SCRIPT_DIR}/deploy"
ARMONIA_DIR="${DEPLOY_DIR}/armonia"
ARMONIA_MODULES_DIR="${ARMONIA_DIR}/src/modules"
ARMONIA_CORE_URL="https://github.com/Skerd/armonia_core.git"
MAESTRO_DIR="${DEPLOY_DIR}/maestro"
MAESTRO_MODULES_DIR="${MAESTRO_DIR}/modules"
MAESTRO_CORE_URL="https://github.com/Skerd/maestro_core.git"
SINFONIA_DIR="${DEPLOY_DIR}/sinfonia"
SINFONIA_MODULES_DIR="${SINFONIA_DIR}/src/modules"
SINFONIA_CORE_URL="https://github.com/Skerd/sinfonia_core.git"
KAFKA_CLUSTER_DIR="${SCRIPT_DIR}/clusters/kafka"
REDIS_CLUSTER_DIR="${SCRIPT_DIR}/clusters/redis"
MONGO_CLUSTER_DIR="${SCRIPT_DIR}/clusters/mongo"
CLAMAV_CLUSTER_DIR="${SCRIPT_DIR}/clusters/clamv"
NGINX_CLUSTER_DIR="${SCRIPT_DIR}/clusters/nginx"
MAESTRO_ENV_FILE="${SCRIPT_DIR}/apps/maestro/.env"
MAESTRO_SECRETS_SRC="${SCRIPT_DIR}/apps/maestro/secrets"
MAESTRO_SECRETS_DIR="${MAESTRO_DIR}/secrets"
MAESTRO_KAFKA_CERTS_DIR="${MAESTRO_SECRETS_DIR}/certificates/kafka"
MAESTRO_MONGO_CERTS_DIR="${MAESTRO_SECRETS_DIR}/certificates/mongo"
DEFAULT_BRANCH="main"
DEFAULT_INTERNAL_NETWORK="arpeggio_internal_network"
MAESTRO_API_CONTAINER="maestroApi"
MAESTRO_WEBSOCKET_CONTAINER="maestroWebsocket"
SINFONIA_FRONTEND_CONTAINER="frontend"
PROMETHEUS_CONTAINER="prometheus"
MONGODB_CONTAINER="router-01"
MONGODB_INTERNAL_PORT="27017"
CLAMAV_CONTAINER="clamav-1"
CLAMAV_INTERNAL_PORT="3310"
REDIS_INTERNAL_PORT="6379"
KAFKA_ACTIVATED="false"
REDIS_ACTIVATED="false"
CLAMAV_ACTIVATED="false"

read_env_value() {
    local file="$1"
    local key="$2"
    local value

    value="$(grep -E "^${key}=" "$file" 2>/dev/null | head -1 | cut -d= -f2-)"
    echo "$value"
}

validate_deploy_number() {
    local num="$1"
    local min="$2"
    local max="$3"
    local label="$4"

    if ! [[ "$num" =~ ^[0-9]+$ ]]; then
        print_error "${label} must be a valid number"
        return 1
    fi

    if [ "$num" -lt "$min" ] || [ "$num" -gt "$max" ]; then
        print_error "${label} must be between ${min} and ${max}"
        return 1
    fi

    return 0
}

clone_or_update_repo() {
    local repo_url="$1"
    local target_dir="$2"
    local branch="$3"
    local label="$4"

    if [ -d "$target_dir/.git" ]; then
        print_status "Updating ${label} in ${target_dir}"
        git -C "$target_dir" fetch origin "$branch"
        git -C "$target_dir" checkout "$branch"
        git -C "$target_dir" pull --ff-only origin "$branch"
        return 0
    fi

    if [ -e "$target_dir" ]; then
        print_error "Path exists but is not a git repository: ${target_dir}"
        return 1
    fi

    print_status "Cloning ${label} from ${repo_url} (branch: ${branch})"
    git clone --branch "$branch" --single-branch "$repo_url" "$target_dir"
}

set_env_var() {
    local file="$1"
    local key="$2"
    local value="$3"
    local tmp

    if [ ! -f "$file" ]; then
        print_error "Env file not found: ${file}"
        exit 1
    fi

    tmp="$(mktemp)"
    awk -v key="$key" -v val="$value" '
        BEGIN { found = 0 }
        $0 ~ "^" key "=" { print key "=" val; found = 1; next }
        { print }
        END { if (!found) print key "=" val }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
}

cluster_is_generated() {
    local cluster_dir="$1"
    [ -f "${cluster_dir}/docker-compose.yml" ]
}

parse_nginx_external_port() {
    local compose_file="${NGINX_CLUSTER_DIR}/docker-compose.yml"
    local port

    if [ ! -f "$compose_file" ]; then
        echo "80"
        return 0
    fi

    port="$(grep -m1 -E '^\s+-\s+"[0-9]+:[0-9]+"' "$compose_file" | sed -E 's/.*"([0-9]+):[0-9]+".*/\1/')"
    echo "${port:-80}"
}

configure_cluster_network_env_files() {
    local cluster_dir env_file

    for cluster_dir in kafka redis mongo clamv nginx prometheus; do
        env_file="${SCRIPT_DIR}/clusters/${cluster_dir}/.env"
        if [ -f "$env_file" ]; then
            set_env_var "$env_file" "DOCKER_INTERNAL_NETWORK" "$DOCKER_INTERNAL_NETWORK"
        fi
    done

    print_status "Docker internal network set to: ${DOCKER_INTERNAL_NETWORK}"
}

configure_maestro_service_hosts() {
    set_env_var "$MAESTRO_ENV_FILE" "WEBSOCKET_HOST" "$MAESTRO_WEBSOCKET_CONTAINER"
    set_env_var "$MAESTRO_ENV_FILE" "PROMETHEUS_HOST" "$PROMETHEUS_CONTAINER"
    print_status "Maestro service hosts updated to container names in ${MAESTRO_ENV_FILE}"
}

parse_kafka_brokers() {
    local compose_file="$1"
    local brokers="" broker

    if [ ! -f "$compose_file" ]; then
        print_error "Kafka docker-compose file not found: ${compose_file}"
        exit 1
    fi

    while IFS= read -r broker; do
        if [ -n "$brokers" ]; then
            brokers+=","
        fi
        brokers+="$broker"
    done < <(grep -oE 'SASL_SSL://kafka-[0-9]+:29092' "$compose_file" | sed 's|SASL_SSL://||' | sort -t- -k2 -n)

    if [ -z "$brokers" ]; then
        print_error "Could not determine Kafka broker addresses from ${compose_file}"
        exit 1
    fi

    echo "$brokers"
}

copy_kafka_certificates() {
    local kafka_cluster_dir="$1"
    local dest_dir="$2"
    local source_ca="${kafka_cluster_dir}/secrets/ca.crt.pem"

    mkdir -p "$dest_dir"

    if [ ! -f "$source_ca" ]; then
        print_error "Kafka CA certificate not found: ${source_ca}"
        exit 1
    fi

    cp "$source_ca" "${dest_dir}/ca.crt.pem"
    print_status "Copied Kafka CA certificate to ${dest_dir}/ca.crt.pem"
}

show_kafka_enabled_features() {
    echo "  - Async transactional emails (activation, invitation, forgot password, MFA disable)"
    echo "  - Login history persistence"
    echo "  - API access event logging and live metrics aggregation"
    echo "  - Distributed cron job execution via Kafka queue"
    echo "  - Property management client emails (reservations and sales)"
    echo "  - Dedicated kafkaServer process for background consumers"
    echo "  - Consumer health tracking in the server health dashboard"
    echo "  - Dead-letter queue handling for failed Kafka messages"
}

show_kafka_disabled_effects() {
    echo "  - KAFKA_ENABLED will be set to false in ${MAESTRO_ENV_FILE}"
    echo "  - kafkaServer consumers will not start"
    echo "  - User emails will not be dispatched through Kafka consumers"
    echo "  - Login history will not be persisted via Kafka"
    echo "  - API access metrics streaming via Kafka will be unavailable"
    echo "  - Cron jobs will not use the Kafka queue adapter"
    echo "  - Property management reservation/sale client emails will not be sent via Kafka"
    echo "  - The API server can still run for direct HTTP operations without Kafka"
}

configure_maestro_kafka_disabled() {
    set_env_var "$MAESTRO_ENV_FILE" "KAFKA_ENABLED" "false"
    print_status "Kafka disabled in ${MAESTRO_ENV_FILE}"
}

configure_maestro_kafka_enabled() {
    local kafka_env_file="${KAFKA_CLUSTER_DIR}/.env"
    local compose_file="${KAFKA_CLUSTER_DIR}/docker-compose.yml"
    local brokers kafka_username kafka_password

    if [ ! -f "$kafka_env_file" ]; then
        print_error "Kafka cluster .env not found: ${kafka_env_file}"
        exit 1
    fi

    # shellcheck disable=SC1090
    source "$kafka_env_file"

    if [ -z "${KAFKA_USERNAME:-}" ] || [ -z "${KAFKA_PASSWORD:-}" ]; then
        print_error "Kafka cluster .env must define KAFKA_USERNAME and KAFKA_PASSWORD"
        exit 1
    fi

    brokers="$(parse_kafka_brokers "$compose_file")"
    kafka_username="$KAFKA_USERNAME"
    kafka_password="$KAFKA_PASSWORD"

    print_status "Copying Kafka SSL certificates to ${MAESTRO_KAFKA_CERTS_DIR}"
    copy_kafka_certificates "$KAFKA_CLUSTER_DIR" "$MAESTRO_KAFKA_CERTS_DIR"

    set_env_var "$MAESTRO_ENV_FILE" "KAFKA_ENABLED" "true"
    set_env_var "$MAESTRO_ENV_FILE" "KAFKA_BROKERS" "$brokers"
    set_env_var "$MAESTRO_ENV_FILE" "KAFKA_SECURITY_PROTOCOL" "SASL_SSL"
    set_env_var "$MAESTRO_ENV_FILE" "KAFKA_SASL_MECHANISM" "plain"
    set_env_var "$MAESTRO_ENV_FILE" "KAFKA_USERNAME" "$kafka_username"
    set_env_var "$MAESTRO_ENV_FILE" "KAFKA_PASSWORD" "$kafka_password"
    set_env_var "$MAESTRO_ENV_FILE" "KAFKA_SSL_CA_PATH" "secrets/certificates/kafka/ca.crt.pem"
    set_env_var "$MAESTRO_ENV_FILE" "KAFKA_SSL_REJECT_UNAUTHORIZED" "true"

    print_status "Kafka enabled in ${MAESTRO_ENV_FILE}"
    print_status "Kafka brokers: ${brokers}"
    print_status "Kafka CA path: secrets/certificates/kafka/ca.crt.pem"
}

prompt_kafka_activation() {
    if cluster_is_generated "$KAFKA_CLUSTER_DIR"; then
        print_status "Kafka cluster already generated at ${KAFKA_CLUSTER_DIR}, activating automatically"
        return 0
    fi

    echo ""
    echo -e "${BLUE}================================================================${NC}"
    echo -e "Kafka activation"
    echo -e "${BLUE}================================================================${NC}"
    echo ""
    echo "Do you want to activate Kafka?"
    echo ""
    echo "If yes, Kafka features will be available:"
    show_kafka_enabled_features
    echo ""
    echo "If no, the following will apply:"
    show_kafka_disabled_effects
    echo ""

    while true; do
        read -r -p "Activate Kafka? (y/N): " activate_kafka_input
        case "${activate_kafka_input:-N}" in
            [Yy]|[Yy][Ee][Ss])
                return 0
                ;;
            [Nn]|[Nn][Oo]|"")
                return 1
                ;;
            *)
                print_warning "Please answer y or n."
                ;;
        esac
    done
}

setup_kafka_cluster() {
    local generate_script="${KAFKA_CLUSTER_DIR}/generate-cluster.sh"

    if cluster_is_generated "$KAFKA_CLUSTER_DIR"; then
        print_status "Kafka cluster already generated, skipping generator"
        return 0
    fi

    if [ ! -x "$generate_script" ]; then
        chmod +x "$generate_script"
    fi

    print_status "Running Kafka cluster generator"
    (
        cd "$KAFKA_CLUSTER_DIR"
        ./generate-cluster.sh
    )

    if [ ! -f "${KAFKA_CLUSTER_DIR}/docker-compose.yml" ]; then
        print_warning "Kafka cluster generation was not completed. Skipping Kafka env configuration."
        return 1
    fi

    return 0
}

parse_redis_root_nodes() {
    local compose_file="$1"
    local nodes="" port

    if [ ! -f "$compose_file" ]; then
        print_error "Redis docker-compose file not found: ${compose_file}"
        exit 1
    fi

    while IFS= read -r master; do
        if [ -n "$nodes" ]; then
            nodes+=","
        fi
        nodes+="${master}:${REDIS_INTERNAL_PORT}"
    done < <(grep -oE 'redis-master-[0-9]+' "$compose_file" | sort -t- -k3 -n | uniq)

    if [ -z "$nodes" ]; then
        print_error "Could not determine Redis master addresses from ${compose_file}"
        exit 1
    fi

    echo "$nodes"
}

show_redis_enabled_features() {
    echo "  - API rate limiting across instances"
    echo "  - Kafka consumer retry tracking and consumer registry heartbeats"
    echo "  - Distributed cron job locking and scheduler heartbeat"
    echo "  - Service counters, stats snapshots, and health snapshot caching"
    echo "  - WebSocket cross-instance connection coordination"
    echo "  - Telegram health snapshot persistence"
}

show_redis_disabled_effects() {
    echo "  - Redis connection settings will be cleared in ${MAESTRO_ENV_FILE}"
    echo "  - Rate limiting will be skipped when Redis is unavailable"
    echo "  - Kafka retry tracking and consumer health registry will not persist in Redis"
    echo "  - Cron distributed locks and scheduler heartbeat will be unavailable"
    echo "  - Stats and health snapshots will not be cached in Redis"
    echo "  - WebSocket scaling coordination across instances will be degraded"
    echo "  - Maestro startup validation requires REDIS_ROOT_NODES to be configured"
}

configure_maestro_redis_disabled() {
    set_env_var "$MAESTRO_ENV_FILE" "REDIS_ROOT_NODES" ""
    set_env_var "$MAESTRO_ENV_FILE" "REDIS_USERNAME" ""
    set_env_var "$MAESTRO_ENV_FILE" "REDIS_PASSWORD" ""
    print_status "Redis connection settings cleared in ${MAESTRO_ENV_FILE}"
}

configure_maestro_redis_enabled() {
    local redis_env_file="${REDIS_CLUSTER_DIR}/.env"
    local compose_file="${REDIS_CLUSTER_DIR}/docker-compose.yml"
    local root_nodes

    if [ ! -f "$redis_env_file" ]; then
        print_error "Redis cluster .env not found: ${redis_env_file}"
        exit 1
    fi

    # shellcheck disable=SC1090
    source "$redis_env_file"

    root_nodes="$(parse_redis_root_nodes "$compose_file")"

    set_env_var "$MAESTRO_ENV_FILE" "REDIS_ROOT_NODES" "$root_nodes"
    set_env_var "$MAESTRO_ENV_FILE" "REDIS_USERNAME" "${REDIS_USERNAME:-}"
    set_env_var "$MAESTRO_ENV_FILE" "REDIS_PASSWORD" "${REDIS_PASSWORD:-}"
    set_env_var "$MAESTRO_ENV_FILE" "REDIS_DATABASE" "${REDIS_DATABASE:-0}"
    set_env_var "$MAESTRO_ENV_FILE" "REDIS_KEY_PREFIX" "${REDIS_KEY_PREFIX:-arpeggio}"

    print_status "Redis enabled in ${MAESTRO_ENV_FILE}"
    print_status "Redis root nodes: ${root_nodes}"
}

prompt_redis_activation() {
    if cluster_is_generated "$REDIS_CLUSTER_DIR"; then
        print_status "Redis cluster already generated at ${REDIS_CLUSTER_DIR}, activating automatically"
        return 0
    fi

    echo ""
    echo -e "${BLUE}================================================================${NC}"
    echo -e "Redis activation"
    echo -e "${BLUE}================================================================${NC}"
    echo ""
    echo "Do you want to activate Redis?"
    echo ""
    echo "If yes, Redis features will be available:"
    show_redis_enabled_features
    echo ""
    echo "If no, the following will apply:"
    show_redis_disabled_effects
    echo ""

    while true; do
        read -r -p "Activate Redis? (y/N): " activate_redis_input
        case "${activate_redis_input:-N}" in
            [Yy]|[Yy][Ee][Ss])
                return 0
                ;;
            [Nn]|[Nn][Oo]|"")
                return 1
                ;;
            *)
                print_warning "Please answer y or n."
                ;;
        esac
    done
}

setup_redis_cluster() {
    local generate_script="${REDIS_CLUSTER_DIR}/generate-cluster.sh"

    if cluster_is_generated "$REDIS_CLUSTER_DIR"; then
        print_status "Redis cluster already generated, skipping generator"
        return 0
    fi

    if [ ! -x "$generate_script" ]; then
        chmod +x "$generate_script"
    fi

    print_status "Running Redis cluster generator"
    (
        cd "$REDIS_CLUSTER_DIR"
        ./generate-cluster.sh
    )

    if [ ! -f "${REDIS_CLUSTER_DIR}/docker-compose.yml" ]; then
        print_warning "Redis cluster generation was not completed. Skipping Redis env configuration."
        return 1
    fi

    return 0
}

parse_mongo_router_host() {
    local compose_file="$1"
    local router_host

    if [ ! -f "$compose_file" ]; then
        print_error "MongoDB docker-compose file not found: ${compose_file}"
        exit 1
    fi

    router_host="$(grep -m1 -E 'container_name: router-' "$compose_file" | awk '{print $2}')"

    if [ -z "$router_host" ]; then
        router_host="$MONGODB_CONTAINER"
    fi

    echo "$router_host"
}

copy_mongo_certificates() {
    local mongo_cluster_dir="$1"
    local dest_dir="$2"
    local source_ca="${mongo_cluster_dir}/certs/ca.crt.pem"
    local source_router_cert="${mongo_cluster_dir}/certs/router-01.pem"

    mkdir -p "$dest_dir"

    if [ ! -f "$source_ca" ]; then
        print_error "MongoDB CA certificate not found: ${source_ca}"
        exit 1
    fi

    if [ ! -f "$source_router_cert" ]; then
        print_error "MongoDB router certificate not found: ${source_router_cert}"
        exit 1
    fi

    cp "$source_ca" "${dest_dir}/ca.crt.pem"
    cp "$source_router_cert" "${dest_dir}/router-01.pem"
    print_status "Copied MongoDB certificates to ${dest_dir}"
}

show_mongo_enabled_features() {
    echo "  - Primary application data persistence (users, companies, finance, media)"
    echo "  - Mongoose models, CRUD services, indexes, and view configs"
    echo "  - GridFS media storage and audit/soft-delete plugins"
    echo "  - Database initialization and seed data (when MONGODB_INIT=true)"
    echo "  - Required by apiServer, kafkaServer, cronServer, and webSocketServer"
    echo "  - TLS-secured connection to the MongoDB sharded cluster router"
}

configure_maestro_mongo_enabled() {
    local mongo_env_file="${MONGO_CLUSTER_DIR}/.env"
    local compose_file="${MONGO_CLUSTER_DIR}/docker-compose.yml"
    local mongo_host

    if [ ! -f "$mongo_env_file" ]; then
        print_error "MongoDB cluster .env not found: ${mongo_env_file}"
        exit 1
    fi

    # shellcheck disable=SC1090
    source "$mongo_env_file"

    if [ -z "${APP_USERNAME:-}" ] || [ -z "${APP_PASSWORD:-}" ] || [ -z "${COLLECTION_NAME:-}" ]; then
        print_error "MongoDB cluster .env must define APP_USERNAME, APP_PASSWORD, and COLLECTION_NAME"
        exit 1
    fi

    mongo_host="$(parse_mongo_router_host "$compose_file")"

    print_status "Copying MongoDB TLS certificates to ${MAESTRO_MONGO_CERTS_DIR}"
    copy_mongo_certificates "$MONGO_CLUSTER_DIR" "$MAESTRO_MONGO_CERTS_DIR"

    set_env_var "$MAESTRO_ENV_FILE" "MONGODB_PRE_HOST" "mongodb://"
    set_env_var "$MAESTRO_ENV_FILE" "MONGODB_HOST" "$mongo_host"
    set_env_var "$MAESTRO_ENV_FILE" "MONGODB_PORT" "$MONGODB_INTERNAL_PORT"
    set_env_var "$MAESTRO_ENV_FILE" "MONGODB_DB_NAME" "$COLLECTION_NAME"
    set_env_var "$MAESTRO_ENV_FILE" "MONGODB_USER" "$APP_USERNAME"
    set_env_var "$MAESTRO_ENV_FILE" "MONGODB_PASSWORD" "$APP_PASSWORD"
    set_env_var "$MAESTRO_ENV_FILE" "MONGODB_PARAMS" "?tls=true&authSource=${COLLECTION_NAME}"
    set_env_var "$MAESTRO_ENV_FILE" "MONGODB_ROOT_CA_CERT_PATH" "secrets/certificates/mongo/ca.crt.pem"
    set_env_var "$MAESTRO_ENV_FILE" "MONGODB_TLS_CERTIFICATE_KEY_FILE_PATH" "secrets/certificates/mongo/router-01.pem"
    set_env_var "$MAESTRO_ENV_FILE" "MONGODB_AUTH_SOURCE" "$COLLECTION_NAME"

    print_status "MongoDB enabled in ${MAESTRO_ENV_FILE}"
    print_status "MongoDB router: ${mongo_host}:${MONGODB_INTERNAL_PORT}"
    print_status "MongoDB database: ${COLLECTION_NAME}"
}

setup_mongo_cluster() {
    local generate_script="${MONGO_CLUSTER_DIR}/generate-cluster.sh"

    if cluster_is_generated "$MONGO_CLUSTER_DIR"; then
        print_status "MongoDB cluster already generated, skipping generator"
        return 0
    fi

    if [ ! -x "$generate_script" ]; then
        chmod +x "$generate_script"
    fi

    print_status "Running MongoDB cluster generator"
    (
        cd "$MONGO_CLUSTER_DIR"
        ./generate-cluster.sh
    )

    if [ ! -f "${MONGO_CLUSTER_DIR}/docker-compose.yml" ]; then
        print_error "MongoDB cluster generation was not completed. MongoDB is required for deployment."
        exit 1
    fi

    return 0
}

setup_mandatory_mongodb() {
    echo ""
    echo -e "${BLUE}================================================================${NC}"
    echo -e "MongoDB setup (required)"
    echo -e "${BLUE}================================================================${NC}"
    echo ""

    if cluster_is_generated "$MONGO_CLUSTER_DIR"; then
        print_status "Using existing MongoDB cluster at ${MONGO_CLUSTER_DIR}"
    else
        echo "MongoDB is the primary database. Deployment cannot continue without it."
        echo ""
        echo "The following will be configured:"
        show_mongo_enabled_features
        echo ""
    fi

    setup_mongo_cluster
    configure_maestro_mongo_enabled
    print_status "MongoDB cluster configuration completed"
    print_status "Start the cluster with: cd ${MONGO_CLUSTER_DIR} && docker-compose up -d"
}

show_clamav_enabled_features() {
    echo "  - Real malware scanning for uploaded files via ClamAV"
    echo "  - Production file upload validation for media and GridFS storage"
    echo "  - Virus signature checks before files are accepted by Maestro"
    echo "  - Dedicated ClamAV cluster with health checks and auto-restart"
}

show_clamav_disabled_effects() {
    echo "  - FILE_SCANNER_TYPE will be set to mock in ${MAESTRO_ENV_FILE}"
    echo "  - Uploads will skip real antivirus scanning"
    echo "  - MOCK_SCANNER_SIMULATE_THREATS will be set to false"
    echo "  - Suitable for local development without a ClamAV cluster"
}

configure_maestro_clamav_disabled() {
    set_env_var "$MAESTRO_ENV_FILE" "FILE_SCANNER_TYPE" "mock"
    set_env_var "$MAESTRO_ENV_FILE" "MOCK_SCANNER_SIMULATE_THREATS" "false"
    print_status "File scanner set to mock in ${MAESTRO_ENV_FILE}"
}

configure_maestro_clamav_enabled() {
    local clamav_env_file="${CLAMAV_CLUSTER_DIR}/.env"
    local compose_file="${CLAMAV_CLUSTER_DIR}/docker-compose.yml"
    local clamav_host

    if [ -f "$clamav_env_file" ]; then
        # shellcheck disable=SC1090
        source "$clamav_env_file"
    fi

    if [ -f "$compose_file" ]; then
        clamav_host="$(grep -m1 -E 'container_name: clamav-' "$compose_file" | awk '{print $2}')"
    fi
    clamav_host="${clamav_host:-${CLAMAV_HOST:-$CLAMAV_CONTAINER}}"

    set_env_var "$MAESTRO_ENV_FILE" "FILE_SCANNER_TYPE" "clamav"
    set_env_var "$MAESTRO_ENV_FILE" "MOCK_SCANNER_SIMULATE_THREATS" "false"
    set_env_var "$MAESTRO_ENV_FILE" "CLAMAV_HOST" "$clamav_host"
    set_env_var "$MAESTRO_ENV_FILE" "CLAMAV_PORT" "$CLAMAV_INTERNAL_PORT"

    print_status "ClamAV enabled in ${MAESTRO_ENV_FILE}"
    print_status "ClamAV endpoint: ${clamav_host}:${CLAMAV_INTERNAL_PORT}"
}

show_nginx_gateway_features() {
    echo "  - Public entry point for Sinfonia frontend, Maestro API, and WebSocket traffic"
    echo "  - Routes / and /assets/ to ${SINFONIA_FRONTEND_CONTAINER}"
    echo "  - Routes /api/ and /api/auxiliary/media/ to ${MAESTRO_API_CONTAINER}"
    echo "  - Routes /ws/ to ${MAESTRO_WEBSOCKET_CONTAINER}"
    echo "  - Uses shared Docker network: ${DOCKER_INTERNAL_NETWORK}"
}

print_deploy_context_for_nginx() {
    local module

    echo "Deployment context:"
    echo "  - Selected modules (${#CLEANED_MODULES[@]}):"
    for module in "${CLEANED_MODULES[@]}"; do
        echo "      - ${module}"
    done
    echo "  - Docker internal network: ${DOCKER_INTERNAL_NETWORK}"
    echo "  - Kafka cluster: $([ "$KAFKA_ACTIVATED" = "true" ] && echo "enabled" || echo "disabled")"
    echo "  - Redis cluster: $([ "$REDIS_ACTIVATED" = "true" ] && echo "enabled" || echo "disabled")"
    echo "  - ClamAV cluster: $([ "$CLAMAV_ACTIVATED" = "true" ] && echo "enabled" || echo "disabled")"
    echo "  - MongoDB cluster: required (enabled)"
    echo "  - Maestro API upstream: ${MAESTRO_API_CONTAINER}:$(read_env_value "$MAESTRO_ENV_FILE" "SERVER_PORT")"
    echo "  - Maestro WebSocket upstream: ${MAESTRO_WEBSOCKET_CONTAINER}:$(read_env_value "$MAESTRO_ENV_FILE" "WEBSOCKET_PORT")"
    echo "  - Sinfonia frontend upstream: ${SINFONIA_FRONTEND_CONTAINER}:80"
    echo ""
}

prompt_nginx_gateway_settings() {
    local api_port websocket_port

    api_port="$(read_env_value "$MAESTRO_ENV_FILE" "SERVER_PORT")"
    websocket_port="$(read_env_value "$MAESTRO_ENV_FILE" "WEBSOCKET_PORT")"
    api_port="${api_port:-81}"
    websocket_port="${websocket_port:-82}"

    echo ""
    echo -e "${BLUE}================================================================${NC}"
    echo -e "Nginx gateway setup (required)"
    echo -e "${BLUE}================================================================${NC}"
    echo ""
    echo "The Nginx gateway is the public entry point for the deployed stack."
    echo ""
    show_nginx_gateway_features
    echo ""
    print_deploy_context_for_nginx

    while true; do
        read -r -p "Enter number of Nginx gateway nodes (1-5) [default: 1]: " nginx_nodes_input
        NGINX_NUM_NODES="${nginx_nodes_input:-1}"
        if validate_deploy_number "$NGINX_NUM_NODES" 1 5 "Number of Nginx gateway nodes"; then
            break
        fi
    done

    while true; do
        read -r -p "Enter Nginx external base port (0-65535) [default: 80]: " nginx_port_input
        NGINX_EXTERNAL_PORT="${nginx_port_input:-80}"
        if validate_deploy_number "$NGINX_EXTERNAL_PORT" 0 65535 "Nginx external base port"; then
            break
        fi
    done

    while true; do
        read -r -p "Enter number of frontend upstream servers (1-10) [default: 1]: " frontend_backends_input
        NGINX_NUM_FRONTEND_BACKENDS="${frontend_backends_input:-1}"
        if validate_deploy_number "$NGINX_NUM_FRONTEND_BACKENDS" 1 10 "Number of frontend upstream servers"; then
            break
        fi
    done

    while true; do
        read -r -p "Enter number of API upstream servers (1-10) [default: 1]: " api_backends_input
        NGINX_NUM_API_BACKENDS="${api_backends_input:-1}"
        if validate_deploy_number "$NGINX_NUM_API_BACKENDS" 1 10 "Number of API upstream servers"; then
            break
        fi
    done

    while true; do
        read -r -p "Enter number of WebSocket upstream servers (1-10) [default: 1]: " websocket_backends_input
        NGINX_NUM_WEBSOCKET_BACKENDS="${websocket_backends_input:-1}"
        if validate_deploy_number "$NGINX_NUM_WEBSOCKET_BACKENDS" 1 10 "Number of WebSocket upstream servers"; then
            break
        fi
    done

    echo ""
    print_status "Nginx gateway summary:"
    print_status "- Gateway nodes: ${NGINX_NUM_NODES}"
    print_status "- External base port: ${NGINX_EXTERNAL_PORT}"
    print_status "- Frontend upstream servers: ${NGINX_NUM_FRONTEND_BACKENDS} (${SINFONIA_FRONTEND_CONTAINER}:80)"
    print_status "- API upstream servers: ${NGINX_NUM_API_BACKENDS} (${MAESTRO_API_CONTAINER}:${api_port})"
    print_status "- WebSocket upstream servers: ${NGINX_NUM_WEBSOCKET_BACKENDS} (${MAESTRO_WEBSOCKET_CONTAINER}:${websocket_port})"
    print_status "- Shared network: ${DOCKER_INTERNAL_NETWORK}"
    echo ""
}

configure_nginx_cluster_env() {
    local nginx_env_file="${NGINX_CLUSTER_DIR}/.env"
    local api_port websocket_port

    api_port="$(read_env_value "$MAESTRO_ENV_FILE" "SERVER_PORT")"
    websocket_port="$(read_env_value "$MAESTRO_ENV_FILE" "WEBSOCKET_PORT")"
    api_port="${api_port:-81}"
    websocket_port="${websocket_port:-82}"

    if [ ! -f "$nginx_env_file" ]; then
        print_error "Nginx env file not found: ${nginx_env_file}"
        exit 1
    fi

    set_env_var "$nginx_env_file" "DOCKER_INTERNAL_NETWORK" "$DOCKER_INTERNAL_NETWORK"
    set_env_var "$nginx_env_file" "FRONTEND_UPSTREAM_HOST" "$SINFONIA_FRONTEND_CONTAINER"
    set_env_var "$nginx_env_file" "FRONTEND_UPSTREAM_PORT" "80"
    set_env_var "$nginx_env_file" "API_UPSTREAM_HOST" "$MAESTRO_API_CONTAINER"
    set_env_var "$nginx_env_file" "API_UPSTREAM_PORT" "$api_port"
    set_env_var "$nginx_env_file" "WEBSOCKET_UPSTREAM_HOST" "$MAESTRO_WEBSOCKET_CONTAINER"
    set_env_var "$nginx_env_file" "WEBSOCKET_UPSTREAM_PORT" "$websocket_port"
    set_env_var "$nginx_env_file" "NGINX_LISTEN_PORT" "80"

    print_status "Nginx cluster .env synchronized with deployment settings"
}

setup_nginx_gateway() {
    local generate_script="${NGINX_CLUSTER_DIR}/generate-cluster.sh"

    configure_nginx_cluster_env

    if cluster_is_generated "$NGINX_CLUSTER_DIR"; then
        print_status "Nginx gateway already generated, skipping generator"
        return 0
    fi

    if [ ! -x "$generate_script" ]; then
        chmod +x "$generate_script"
    fi

    print_status "Running Nginx gateway cluster generator"
    (
        cd "$NGINX_CLUSTER_DIR"
        export NGINX_DEPLOY_MODE=true
        export MAESTRO_ENV_FILE
        export NGINX_NUM_NODES
        export NGINX_EXTERNAL_PORT
        export NGINX_NUM_FRONTEND_BACKENDS
        export NGINX_NUM_API_BACKENDS
        export NGINX_NUM_WEBSOCKET_BACKENDS
        ./generate-cluster.sh
    )

    if [ ! -f "${NGINX_CLUSTER_DIR}/docker-compose.yml" ]; then
        print_error "Nginx gateway generation was not completed. Nginx is required for deployment."
        exit 1
    fi

    return 0
}

configure_maestro_nginx_gateway() {
    local gateway_host="nginx-gateway-1"
    local gateway_url="http://${gateway_host}:${NGINX_EXTERNAL_PORT}"

    set_env_var "$MAESTRO_ENV_FILE" "CLIENT_HOST" "$gateway_url"
    print_status "Maestro CLIENT_HOST set to ${gateway_url}"
}

setup_mandatory_nginx_gateway() {
    if cluster_is_generated "$NGINX_CLUSTER_DIR"; then
        print_status "Using existing Nginx gateway at ${NGINX_CLUSTER_DIR}"
        NGINX_EXTERNAL_PORT="$(parse_nginx_external_port)"
        setup_nginx_gateway
        configure_maestro_nginx_gateway
    else
        prompt_nginx_gateway_settings
        setup_nginx_gateway
        configure_maestro_nginx_gateway
    fi

    print_status "Nginx gateway configuration completed"
    print_status "Start the gateway with: cd ${NGINX_CLUSTER_DIR} && docker-compose up -d"
}

copy_maestro_secrets_to_deploy() {
    if [ ! -d "$MAESTRO_SECRETS_SRC" ]; then
        print_warning "Maestro secrets source not found: ${MAESTRO_SECRETS_SRC}"
        return 0
    fi

    if [ -z "$(ls -A "$MAESTRO_SECRETS_SRC" 2>/dev/null)" ]; then
        print_status "Maestro secrets source is empty, skipping copy"
        return 0
    fi

    mkdir -p "$MAESTRO_SECRETS_DIR"
    cp -R "${MAESTRO_SECRETS_SRC}/." "$MAESTRO_SECRETS_DIR/"
    print_status "Copied Maestro secrets to ${MAESTRO_SECRETS_DIR}"
}

copy_maestro_env_to_deploy() {
    local dest_file="${MAESTRO_DIR}/.env"

    if [ ! -f "$MAESTRO_ENV_FILE" ]; then
        print_error "Maestro env file not found: ${MAESTRO_ENV_FILE}"
        exit 1
    fi

    mkdir -p "$MAESTRO_DIR"
    cp "$MAESTRO_ENV_FILE" "$dest_file"
    print_status "Copied Maestro env to ${dest_file}"
}

generate_modules_manifest() {
    local manifest_file="${DEPLOY_DIR}/scripts/modules.manifest.json"
    local module
    local first=true

    mkdir -p "${DEPLOY_DIR}/scripts"

    {
        echo "{"
        for module in "${CLEANED_MODULES[@]}"; do
            if [ "$first" = true ]; then
                first=false
            else
                echo ","
            fi
            printf '  "%s": {\n    "dependsOn": ["core"]\n  }' "$module"
        done
        echo ""
        echo "}"
    } > "$manifest_file"

    print_status "Generated module manifest: ${manifest_file}"
}

sync_maestro_build_scripts_from_apps() {
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

configure_maestro_enabled_modules() {
    local enabled_modules

    enabled_modules="$(IFS=,; echo "${CLEANED_MODULES[*]}")"
    set_env_var "$MAESTRO_ENV_FILE" "ENABLED_MODULES" "$enabled_modules"
    print_status "Maestro ENABLED_MODULES set to: ${enabled_modules}"
}

print_cluster_start_hint() {
    local label="$1"
    local cluster_dir="$2"

    if [ -f "${cluster_dir}/docker-compose.yml" ]; then
        echo "    cd ${cluster_dir} && docker-compose up -d"
    else
        echo "    ${label}: not generated"
    fi
}

print_deploy_summary() {
    local deploy_maestro_env="${MAESTRO_DIR}/.env"
    local module i
    local kafka_enabled redis_nodes file_scanner mongo_host mongo_db
    local api_port websocket_port client_host

    kafka_enabled="$(read_env_value "$deploy_maestro_env" "KAFKA_ENABLED")"
    redis_nodes="$(read_env_value "$deploy_maestro_env" "REDIS_ROOT_NODES")"
    file_scanner="$(read_env_value "$deploy_maestro_env" "FILE_SCANNER_TYPE")"
    mongo_host="$(read_env_value "$deploy_maestro_env" "MONGODB_HOST")"
    mongo_db="$(read_env_value "$deploy_maestro_env" "MONGODB_DB_NAME")"
    api_port="$(read_env_value "$deploy_maestro_env" "SERVER_PORT")"
    websocket_port="$(read_env_value "$deploy_maestro_env" "WEBSOCKET_PORT")"
    client_host="$(read_env_value "$deploy_maestro_env" "CLIENT_HOST")"

    echo ""
    echo -e "${GREEN}================================================================${NC}"
    echo -e "${GREEN}                    Deployment summary${NC}"
    echo -e "${GREEN}================================================================${NC}"
    echo ""

    echo -e "${BLUE}Modules (${#CLEANED_MODULES[@]})${NC}"
    for i in "${!CLEANED_MODULES[@]}"; do
        module="${CLEANED_MODULES[$i]}"
        echo "  - ${module}"
        echo "      Armonia:  ${ARMONIA_MODULE_BRANCHES[$i]}"
        echo "      Maestro:  ${MAESTRO_MODULE_BRANCHES[$i]}"
        echo "      Sinfonia: ${SINFONIA_MODULE_BRANCHES[$i]}"
    done
    echo ""

    echo -e "${BLUE}Docker network${NC}"
    echo "  - ${DOCKER_INTERNAL_NETWORK}"
    echo ""

    echo -e "${BLUE}Source code${NC}"
    echo "  - Deploy root:     ${DEPLOY_DIR}"
    echo "  - Armonia core:    ${ARMONIA_DIR} (${ARMONIA_CORE_BRANCH})"
    echo "  - Maestro core:    ${MAESTRO_DIR} (${MAESTRO_CORE_BRANCH})"
    echo "  - Sinfonia core:   ${SINFONIA_DIR} (${SINFONIA_CORE_BRANCH})"
    echo "  - Maestro env:     ${deploy_maestro_env}"
    echo "  - Module manifest: ${DEPLOY_DIR}/scripts/modules.manifest.json"
    echo ""

    echo -e "${BLUE}Infrastructure${NC}"

    if [ "$kafka_enabled" = "true" ]; then
        echo "  - Kafka: enabled"
        echo "      Brokers: $(read_env_value "$deploy_maestro_env" "KAFKA_BROKERS")"
        echo "      Certs:   ${MAESTRO_KAFKA_CERTS_DIR}"
    else
        echo "  - Kafka: disabled"
    fi

    if [ -n "$redis_nodes" ]; then
        echo "  - Redis: enabled"
        echo "      Root nodes: ${redis_nodes}"
    else
        echo "  - Redis: disabled"
    fi

    if [ "$file_scanner" = "clamav" ]; then
        echo "  - ClamAV: enabled"
        echo "      Endpoint: $(read_env_value "$deploy_maestro_env" "CLAMAV_HOST"):$(read_env_value "$deploy_maestro_env" "CLAMAV_PORT")"
    else
        echo "  - ClamAV: disabled (file scanner: ${file_scanner:-mock})"
    fi

    echo "  - MongoDB: enabled (required)"
    echo "      Router:   ${mongo_host}:${MONGODB_INTERNAL_PORT}"
    echo "      Database: ${mongo_db}"
    echo "      Certs:    ${MAESTRO_MONGO_CERTS_DIR}"

    echo "  - Nginx gateway: enabled (required)"
    echo "      Nodes:              ${NGINX_NUM_NODES:-1}"
    echo "      External base port: ${NGINX_EXTERNAL_PORT:-80}"
    echo "      Frontend upstreams: ${NGINX_NUM_FRONTEND_BACKENDS:-1} (${SINFONIA_FRONTEND_CONTAINER}:80)"
    echo "      API upstreams:      ${NGINX_NUM_API_BACKENDS:-1} (${MAESTRO_API_CONTAINER}:${api_port:-81})"
    echo "      WebSocket upstreams: ${NGINX_NUM_WEBSOCKET_BACKENDS:-1} (${MAESTRO_WEBSOCKET_CONTAINER}:${websocket_port:-82})"
    echo ""

    echo -e "${BLUE}Maestro service endpoints${NC}"
    echo "  - API:        ${MAESTRO_API_CONTAINER}:${api_port:-81}"
    echo "  - WebSocket:  ${MAESTRO_WEBSOCKET_CONTAINER}:${websocket_port:-82}"
    echo "  - Prometheus: ${PROMETHEUS_CONTAINER}"
    echo "  - Client URL: ${client_host}"
    echo ""

    echo -e "${BLUE}Start infrastructure clusters${NC}"
    if [ "$kafka_enabled" = "true" ]; then
        print_cluster_start_hint "Kafka" "$KAFKA_CLUSTER_DIR"
    fi
    if [ -n "$redis_nodes" ]; then
        print_cluster_start_hint "Redis" "$REDIS_CLUSTER_DIR"
    fi
    if [ "$file_scanner" = "clamav" ]; then
        print_cluster_start_hint "ClamAV" "$CLAMAV_CLUSTER_DIR"
    fi
    print_cluster_start_hint "MongoDB" "$MONGO_CLUSTER_DIR"
    print_cluster_start_hint "Nginx" "$NGINX_CLUSTER_DIR"
    echo ""

    echo -e "${BLUE}Bring the stack online${NC}"
    echo "  Configuration and source preparation are complete."
    echo "  To build images and start the full Arpeggio stack, run:"
    echo ""
    echo "    cd ${SCRIPT_DIR} && ./systemUp.sh"
    echo ""

    echo -e "${GREEN}Deployment sources ready in: ${DEPLOY_DIR}${NC}"
    echo -e "${GREEN}================================================================${NC}"
    echo ""
}

prompt_clamav_activation() {
    if cluster_is_generated "$CLAMAV_CLUSTER_DIR"; then
        print_status "ClamAV cluster already generated at ${CLAMAV_CLUSTER_DIR}, activating automatically"
        return 0
    fi

    echo ""
    echo -e "${BLUE}================================================================${NC}"
    echo -e "ClamAV activation"
    echo -e "${BLUE}================================================================${NC}"
    echo ""
    echo "Do you want to activate ClamAV?"
    echo ""
    echo "If yes, ClamAV features will be available:"
    show_clamav_enabled_features
    echo ""
    echo "If no, the following will apply:"
    show_clamav_disabled_effects
    echo ""

    while true; do
        read -r -p "Activate ClamAV? (y/N): " activate_clamav_input
        case "${activate_clamav_input:-N}" in
            [Yy]|[Yy][Ee][Ss])
                return 0
                ;;
            [Nn]|[Nn][Oo]|"")
                return 1
                ;;
            *)
                print_warning "Please answer y or n."
                ;;
        esac
    done
}

setup_clamav_cluster() {
    local generate_script="${CLAMAV_CLUSTER_DIR}/generate-cluster.sh"

    if cluster_is_generated "$CLAMAV_CLUSTER_DIR"; then
        print_status "ClamAV cluster already generated, skipping generator"
        return 0
    fi

    if [ ! -x "$generate_script" ]; then
        chmod +x "$generate_script"
    fi

    print_status "Running ClamAV cluster generator"
    (
        cd "$CLAMAV_CLUSTER_DIR"
        ./generate-cluster.sh
    )

    if [ ! -f "${CLAMAV_CLUSTER_DIR}/docker-compose.yml" ]; then
        print_warning "ClamAV cluster generation was not completed. Skipping ClamAV env configuration."
        return 1
    fi

    return 0
}

echo -e ""
echo -e "${BLUE}================================================================${NC}"
echo -e "Solfeggio deployment"
echo -e "${BLUE}================================================================${NC}"
echo -e ""
echo "Enter the modules to deploy as a comma-separated list."
echo "Example: eCommerce,propertyManagement"
echo ""

read -r -p "Modules to deploy: " module_input

module_input="${module_input// /}"

if [ -z "$module_input" ]; then
    print_error "No modules provided. Exiting."
    exit 1
fi

IFS=',' read -r -a SELECTED_MODULES <<< "$module_input"

# Remove empty entries (e.g. trailing commas)
CLEANED_MODULES=()
for module in "${SELECTED_MODULES[@]}"; do
    if [ -n "$module" ]; then
        CLEANED_MODULES+=("$module")
    fi
done

if [ "${#CLEANED_MODULES[@]}" -eq 0 ]; then
    print_error "No valid modules provided. Exiting."
    exit 1
fi

print_status "Selected modules (${#CLEANED_MODULES[@]}):"
for module in "${CLEANED_MODULES[@]}"; do
    echo "  - $module"
done

echo -e ""
print_status "Ready to continue, a deploy folder will be created that contains all codes to deploy"
echo ""

read -r -p "Enter Docker internal network name [default: ${DEFAULT_INTERNAL_NETWORK}]: " network_input
DOCKER_INTERNAL_NETWORK="${network_input:-$DEFAULT_INTERNAL_NETWORK}"

if [ -z "$DOCKER_INTERNAL_NETWORK" ]; then
    print_error "Docker internal network name cannot be empty. Exiting."
    exit 1
fi

configure_cluster_network_env_files
configure_maestro_service_hosts
echo ""

echo -e "${BLUE}--- Armonia branches ---${NC}"
read -r -p "Enter Armonia core git branch [default: ${DEFAULT_BRANCH}]: " armonia_core_branch_input
ARMONIA_CORE_BRANCH="${armonia_core_branch_input:-$DEFAULT_BRANCH}"

if [ -z "$ARMONIA_CORE_BRANCH" ]; then
    print_error "Armonia core git branch cannot be empty. Exiting."
    exit 1
fi

ARMONIA_MODULE_BRANCHES=()
for module in "${CLEANED_MODULES[@]}"; do
    read -r -p "Enter Armonia git branch for module ${module} [default: ${DEFAULT_BRANCH}]: " module_branch_input
    module_branch="${module_branch_input:-$DEFAULT_BRANCH}"

    if [ -z "$module_branch" ]; then
        print_error "Armonia git branch for module ${module} cannot be empty. Exiting."
        exit 1
    fi

    ARMONIA_MODULE_BRANCHES+=("$module_branch")
done

echo ""
echo -e "${BLUE}--- Maestro branches ---${NC}"
read -r -p "Enter Maestro core git branch [default: ${DEFAULT_BRANCH}]: " maestro_core_branch_input
MAESTRO_CORE_BRANCH="${maestro_core_branch_input:-$DEFAULT_BRANCH}"

if [ -z "$MAESTRO_CORE_BRANCH" ]; then
    print_error "Maestro core git branch cannot be empty. Exiting."
    exit 1
fi

MAESTRO_MODULE_BRANCHES=()
for module in "${CLEANED_MODULES[@]}"; do
    read -r -p "Enter Maestro git branch for module ${module} [default: ${DEFAULT_BRANCH}]: " module_branch_input
    module_branch="${module_branch_input:-$DEFAULT_BRANCH}"

    if [ -z "$module_branch" ]; then
        print_error "Maestro git branch for module ${module} cannot be empty. Exiting."
        exit 1
    fi

    MAESTRO_MODULE_BRANCHES+=("$module_branch")
done

echo ""
echo -e "${BLUE}--- Sinfonia branches ---${NC}"
read -r -p "Enter Sinfonia core git branch [default: ${DEFAULT_BRANCH}]: " sinfonia_core_branch_input
SINFONIA_CORE_BRANCH="${sinfonia_core_branch_input:-$DEFAULT_BRANCH}"

if [ -z "$SINFONIA_CORE_BRANCH" ]; then
    print_error "Sinfonia core git branch cannot be empty. Exiting."
    exit 1
fi

SINFONIA_MODULE_BRANCHES=()
for module in "${CLEANED_MODULES[@]}"; do
    read -r -p "Enter Sinfonia git branch for module ${module} [default: ${DEFAULT_BRANCH}]: " module_branch_input
    module_branch="${module_branch_input:-$DEFAULT_BRANCH}"

    if [ -z "$module_branch" ]; then
        print_error "Sinfonia git branch for module ${module} cannot be empty. Exiting."
        exit 1
    fi

    SINFONIA_MODULE_BRANCHES+=("$module_branch")
done

echo ""
print_status "Armonia core branch: ${ARMONIA_CORE_BRANCH}"
for i in "${!CLEANED_MODULES[@]}"; do
    print_status "Armonia ${CLEANED_MODULES[$i]} branch: ${ARMONIA_MODULE_BRANCHES[$i]}"
done
print_status "Maestro core branch: ${MAESTRO_CORE_BRANCH}"
for i in "${!CLEANED_MODULES[@]}"; do
    print_status "Maestro ${CLEANED_MODULES[$i]} branch: ${MAESTRO_MODULE_BRANCHES[$i]}"
done
print_status "Sinfonia core branch: ${SINFONIA_CORE_BRANCH}"
for i in "${!CLEANED_MODULES[@]}"; do
    print_status "Sinfonia ${CLEANED_MODULES[$i]} branch: ${SINFONIA_MODULE_BRANCHES[$i]}"
done
echo ""

mkdir -p "$DEPLOY_DIR"

print_status "Fetching Armonia core"
clone_or_update_repo "$ARMONIA_CORE_URL" "$ARMONIA_DIR" "$ARMONIA_CORE_BRANCH" "Armonia core"

mkdir -p "$ARMONIA_MODULES_DIR"

for i in "${!CLEANED_MODULES[@]}"; do
    module="${CLEANED_MODULES[$i]}"
    module_branch="${ARMONIA_MODULE_BRANCHES[$i]}"
    module_url="https://github.com/Skerd/armonia_${module}.git"
    module_dir="${ARMONIA_MODULES_DIR}/${module}"

    print_status "Fetching Armonia module: ${module} (branch: ${module_branch})"
    clone_or_update_repo "$module_url" "$module_dir" "$module_branch" "armonia_${module}"
done

print_status "Fetching Maestro core"
clone_or_update_repo "$MAESTRO_CORE_URL" "$MAESTRO_DIR" "$MAESTRO_CORE_BRANCH" "Maestro core"

mkdir -p "$MAESTRO_MODULES_DIR"

for i in "${!CLEANED_MODULES[@]}"; do
    module="${CLEANED_MODULES[$i]}"
    module_branch="${MAESTRO_MODULE_BRANCHES[$i]}"
    module_url="https://github.com/Skerd/maestro_${module}.git"
    module_dir="${MAESTRO_MODULES_DIR}/${module}"

    print_status "Fetching Maestro module: ${module} (branch: ${module_branch})"
    clone_or_update_repo "$module_url" "$module_dir" "$module_branch" "maestro_${module}"
done

print_status "Fetching Sinfonia core"
clone_or_update_repo "$SINFONIA_CORE_URL" "$SINFONIA_DIR" "$SINFONIA_CORE_BRANCH" "Sinfonia core"

mkdir -p "$SINFONIA_MODULES_DIR"

for i in "${!CLEANED_MODULES[@]}"; do
    module="${CLEANED_MODULES[$i]}"
    module_branch="${SINFONIA_MODULE_BRANCHES[$i]}"
    module_url="https://github.com/Skerd/sinfonia_${module}.git"
    module_dir="${SINFONIA_MODULES_DIR}/${module}"

    print_status "Fetching Sinfonia module: ${module} (branch: ${module_branch})"
    clone_or_update_repo "$module_url" "$module_dir" "$module_branch" "sinfonia_${module}"
done

generate_modules_manifest
sync_maestro_build_scripts_from_apps
configure_maestro_enabled_modules

if prompt_kafka_activation; then
    if setup_kafka_cluster; then
        KAFKA_ACTIVATED="true"
        configure_maestro_kafka_enabled
        print_status "Kafka cluster configuration completed"
        print_status "Start the cluster with: cd ${KAFKA_CLUSTER_DIR} && docker-compose up -d"
    else
        print_warning "Kafka activation was not completed"
    fi
else
    configure_maestro_kafka_disabled
    print_status "Continuing deployment without Kafka"
fi

if prompt_redis_activation; then
    if setup_redis_cluster; then
        REDIS_ACTIVATED="true"
        configure_maestro_redis_enabled
        print_status "Redis cluster configuration completed"
        print_status "Start the cluster with: cd ${REDIS_CLUSTER_DIR} && docker-compose up -d"
    else
        print_warning "Redis activation was not completed"
    fi
else
    configure_maestro_redis_disabled
    print_status "Continuing deployment without Redis"
fi

if prompt_clamav_activation; then
    if setup_clamav_cluster; then
        CLAMAV_ACTIVATED="true"
        configure_maestro_clamav_enabled
        print_status "ClamAV cluster configuration completed"
        print_status "Start the cluster with: cd ${CLAMAV_CLUSTER_DIR} && docker-compose up -d"
    else
        print_warning "ClamAV activation was not completed"
    fi
else
    configure_maestro_clamav_disabled
    print_status "Continuing deployment with mock file scanner"
fi

setup_mandatory_mongodb

setup_mandatory_nginx_gateway

copy_maestro_secrets_to_deploy
copy_maestro_env_to_deploy

print_deploy_summary
