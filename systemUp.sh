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
# shellcheck source=lib/instances.sh
source "${SCRIPT_DIR}/lib/instances.sh"
MAESTRO_DOCKERFILE="${SCRIPT_DIR}/apps/maestro/Dockerfile"
SINFONIA_DOCKERFILE="${SCRIPT_DIR}/apps/sinfonia/Dockerfile"
# Compose projects of the stack as it was deployed before instances existed.
LEGACY_COMPOSE_PROJECTS=(servers frontend)
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

STARTED_CLUSTERS=()
DOCKER_BUILD_NO_CACHE=false
SKIP_MAESTRO_BUILD=false
SKIP_FRONTEND_BUILD=false
INSTANCE_ARG=""

print_usage() {
    echo "Usage: $0 [instance] [--no-cache] [--skip-maestro] [--skip-frontend]"
    echo "  instance         Instance to build and start (default: the one deploy.sh prepared last)"
    echo "  --no-cache       Build Maestro and selected Sinfonia client images without Docker layer cache"
    echo "  --skip-maestro   Reuse the existing Maestro image (SPA-only changes)"
    echo "  --skip-frontend  Reuse existing Sinfonia images (API-only changes)"
}

for arg in "$@"; do
    case "$arg" in
        --no-cache)
            DOCKER_BUILD_NO_CACHE=true
            ;;
        --skip-maestro|--frontend-only)
            SKIP_MAESTRO_BUILD=true
            ;;
        --skip-frontend|--maestro-only)
            SKIP_FRONTEND_BUILD=true
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        -*)
            print_error "Unknown argument: $arg"
            print_usage
            exit 1
            ;;
        *)
            if [ -n "$INSTANCE_ARG" ]; then
                print_error "Only one instance can be started per run (got ${INSTANCE_ARG} and ${arg})."
                print_usage
                exit 1
            fi
            INSTANCE_ARG="$arg"
            ;;
    esac
done

if [ "$SKIP_MAESTRO_BUILD" = "true" ] && [ "$SKIP_FRONTEND_BUILD" = "true" ]; then
    print_error "Cannot combine --skip-maestro and --skip-frontend."
    exit 1
fi

select_instance() {
    local name="$INSTANCE_ARG"

    if [ -z "$name" ] && [ -f "$ARPEGGIO_CURRENT_INSTANCE_FILE" ]; then
        name="$(head -1 "$ARPEGGIO_CURRENT_INSTANCE_FILE")"
    fi

    if [ -z "$name" ] || [ ! -f "$(instance_maestro_env_file "$name")" ]; then
        print_error "Unknown instance: ${name:-none selected}"
        print_error "Known instances: $(list_instances | paste -sd' ' -)"
        print_error "Run ./deploy.sh first to prepare an instance."
        exit 1
    fi

    set_instance_paths "$name"
    INSTANCE_MAESTRO_ENV_FILE="$(instance_maestro_env_file "$name")"
    MAESTRO_IMAGE="${ARPEGGIO_MAESTRO_IMAGE:-arpeggio-maestro-${name}:latest}"
    SERVERS_COMPOSE_FILE="${DEPLOY_DIR}/docker-compose.servers.yml"
    FRONTEND_COMPOSE_FILE="${DEPLOY_DIR}/docker-compose.frontend.yml"
    SERVERS_COMPOSE_PROJECT="servers-${name}"
    FRONTEND_COMPOSE_PROJECT="frontend-${name}"
    MAESTRO_API_CONTAINER="$(maestro_container Api)"
    MAESTRO_KAFKA_CONTAINER="$(maestro_container Kafka)"
    MAESTRO_WEBSOCKET_CONTAINER="$(maestro_container Websocket)"
    MAESTRO_CRON_CONTAINER="$(maestro_container Cron)"
    MAESTRO_ASSISTANT_CONTAINER="$(maestro_container Assistant)"
    MAESTRO_TELEGRAM_CONTAINER="$(maestro_container Telegram)"
}

read_env_value() {
    local file="$1"
    local key="$2"

    strip_env_quotes "$(grep -E "^${key}=" "$file" 2>/dev/null | head -1 | cut -d= -f2-)"
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
        print_status "Sinfonia clients to deploy: $(build_sinfonia_client_apps_spec) (mode=${SINFONIA_GATEWAY_MODE:-path})"
        for i in "${!SINFONIA_APP_IDS[@]}"; do
            if ! app_html="$(resolve_sinfonia_app_index_html "$SINFONIA_DIR" "${SINFONIA_APP_IDS[$i]}")"; then
                print_error "Selected client \"${SINFONIA_APP_IDS[$i]}\" is missing under ${SINFONIA_DIR}/src/modules/*/apps/${SINFONIA_APP_IDS[$i]}/"
                missing=1
            else
                if [ "${SINFONIA_GATEWAY_MODE:-path}" = "host" ]; then
                    print_status "Found client ${SINFONIA_APP_IDS[$i]} @ ${SINFONIA_APP_HOSTS[$i]} (${app_html}) -> ${SINFONIA_APP_IMAGES[$i]}"
                else
                    print_status "Found client ${SINFONIA_APP_IDS[$i]} @ ${SINFONIA_APP_PATHS[$i]} (${app_html}) -> ${SINFONIA_APP_IMAGES[$i]}"
                fi
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

install_deploy_dockerignore() {
    local src="${SCRIPT_DIR}/apps/deploy.dockerignore"
    local dest="${DEPLOY_DIR}/.dockerignore"

    if [ ! -f "$src" ]; then
        print_warning "Missing ${src}; Docker build context will not be pruned"
        return 0
    fi

    cp "$src" "$dest"
    print_status "Installed Docker build ignore file: ${dest}"
}

require_docker_image() {
    local image="$1"
    local label="$2"

    if docker image inspect "$image" >/dev/null 2>&1; then
        print_status "Reusing existing ${label} image: ${image}"
        return 0
    fi

    print_error "No ${label} image named ${image}."
    print_error "Run ./systemUp.sh without skip flags once to build it."
    exit 1
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
    local i pid
    local -a pids=()
    local -a app_ids=()
    local -a log_files=()
    local logs_dir="${DEPLOY_DIR}/.build-logs"
    local failed=0

    echo ""
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${BLUE}         Building Sinfonia client images (${#SINFONIA_APP_IDS[@]})${NC}"
    echo -e "${BLUE}================================================================${NC}"
    echo ""

    if [ "${#SINFONIA_APP_IDS[@]}" -le 1 ]; then
        for i in "${!SINFONIA_APP_IDS[@]}"; do
            build_sinfonia_app_image "${SINFONIA_APP_IDS[$i]}" "${SINFONIA_APP_IMAGES[$i]}"
        done
        return 0
    fi

    mkdir -p "$logs_dir"
    print_status "Building ${#SINFONIA_APP_IDS[@]} Sinfonia images in parallel (shared npm layers)"

    local app_id log_file
    for i in "${!SINFONIA_APP_IDS[@]}"; do
        app_id="${SINFONIA_APP_IDS[$i]}"
        log_file="${logs_dir}/${app_id}.log"
        print_status "Starting ${app_id} -> ${SINFONIA_APP_IMAGES[$i]} (log: ${log_file})"
        (
            build_sinfonia_app_image "$app_id" "${SINFONIA_APP_IMAGES[$i]}"
        ) >"$log_file" 2>&1 &
        pids+=("$!")
        app_ids+=("$app_id")
        log_files+=("$log_file")
    done

    for i in "${!pids[@]}"; do
        pid="${pids[$i]}"
        if wait "$pid"; then
            print_status "Sinfonia ${app_ids[$i]} image built successfully"
        else
            print_error "Sinfonia ${app_ids[$i]} build failed. Last log lines:"
            tail -n 80 "${log_files[$i]}" || true
            failed=1
        fi
    done

    if [ "$failed" -ne 0 ]; then
        exit 1
    fi
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

# Generated compose files pin the external network under networks.*.name.
# deploy.sh updates cluster .env without rewriting those files, so a renamed
# network (pronix_internal_network -> arpeggio_internal_network) leaves the
# compose file pointing at a network this run does not create.
read_compose_external_network_name() {
    local compose_file="$1"

    awk '
        /^networks:/ { in_networks = 1; next }
        in_networks && /^[^[:space:]]/ { exit }
        in_networks && /^[[:space:]]+name:/ {
            sub(/^[[:space:]]+name:[[:space:]]*/, "")
            gsub(/["'\'']/, "")
            print
            exit
        }
    ' "$compose_file"
}

align_compose_external_network() {
    local compose_file="$1"
    local declared_network tmp

    declared_network="$(read_compose_external_network_name "$compose_file")"
    if [ -z "$declared_network" ] || [ "$declared_network" = "$DOCKER_INTERNAL_NETWORK" ]; then
        return 0
    fi

    tmp="$(mktemp)"
    awk -v from="$declared_network" -v to="$DOCKER_INTERNAL_NETWORK" '
        /^networks:/ { in_networks = 1 }
        in_networks && /^[^[:space:]]/ && !/^networks:/ { in_networks = 0 }
        in_networks && /^[[:space:]]+name:/ {
            value = $0
            sub(/^[[:space:]]+name:[[:space:]]*/, "", value)
            gsub(/["'\'']/, "", value)
            if (value == from) {
                sub(/name:.*/, "name: " to)
            }
        }
        { print }
    ' "$compose_file" > "$tmp"
    mv "$tmp" "$compose_file"
    print_status "Joined ${compose_file} to ${DOCKER_INTERNAL_NETWORK} (was ${declared_network})"
}

start_cluster_if_generated() {
    local label="$1"
    local cluster_dir="$2"
    local compose_file="${cluster_dir}/docker-compose.yml"
    local declared_network compose_status=0

    if [ ! -f "$compose_file" ]; then
        print_status "Skipping ${label}: no generated docker-compose.yml"
        return 0
    fi

    if ! validate_cluster_bind_mounts "$cluster_dir"; then
        print_error "Skipping ${label}: bind mount validation failed"
        return 1
    fi

    align_compose_external_network "$compose_file"
    declared_network="$(read_compose_external_network_name "$compose_file")"
    if [ -n "$declared_network" ] && ! docker network inspect "$declared_network" >/dev/null 2>&1; then
        print_error "Docker network not found: ${declared_network}"
        print_error "Create it with: docker network create ${declared_network}"
        return 1
    fi

    echo ""
    print_status "Starting ${label} cluster (${cluster_dir})"
    # Called from `if !`, which disables set -e for this whole function.
    if ! (
        cd "$cluster_dir"
        docker_compose up -d --build
    ); then
        compose_status=$?
        print_error "${label} cluster failed to start (docker compose exit ${compose_status})"
        return 1
    fi

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
            print_error "${label} cluster failed to start"
            exit 1
        fi
    done
}

start_gateway_cluster() {
    echo ""
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${BLUE}                 Starting Nginx gateway${NC}"
    echo -e "${BLUE}================================================================${NC}"

    if ! start_cluster_if_generated "Nginx gateway" "$NGINX_CLUSTER_DIR"; then
        print_error "Nginx gateway failed to start"
        exit 1
    fi
}

# Edits to the instance's Maestro env take effect on the next systemUp.sh
# without re-running deploy.sh.
sync_instance_maestro_env() {
    if [ ! -d "$MAESTRO_DIR" ]; then
        return 0
    fi

    cp "$INSTANCE_MAESTRO_ENV_FILE" "${MAESTRO_DIR}/.env"
    print_status "Synced Maestro env of instance ${ARPEGGIO_INSTANCE} to ${MAESTRO_DIR}/.env"
}

# The stack deployed before instances existed uses un-instanced container
# names, and would run its crons and consumers next to the instance that
# replaces it.
remove_legacy_stack() {
    local project names confirm_input
    local legacy_names=""

    for project in "${LEGACY_COMPOSE_PROJECTS[@]}"; do
        names="$(docker ps -a --filter "label=com.docker.compose.project=${project}" --format '{{.Names}}')"
        if [ -n "$names" ]; then
            legacy_names+="${names}"$'\n'
        fi
    done

    if [ -z "$legacy_names" ]; then
        return 0
    fi

    echo ""
    print_warning "Found containers of the stack deployed before instances existed:"
    echo "$legacy_names" | sed '/^$/d; s/^/  - /'
    print_warning "They are replaced by the containers of instance ${ARPEGGIO_INSTANCE} and must be removed first."
    print_warning "Only the containers are removed; MongoDB, Redis and Kafka data is untouched."

    read -r -p "Remove these containers now? (y/N): " confirm_input
    case "${confirm_input:-N}" in
        [Yy]|[Yy][Ee][Ss]) ;;
        *)
            print_error "Cannot start instance ${ARPEGGIO_INSTANCE} next to the previous stack."
            exit 1
            ;;
    esac

    # shellcheck disable=SC2086
    docker rm -f $legacy_names >/dev/null
    print_status "Removed the previous stack's containers"
}

# Creates the instance's database and user on the shared MongoDB cluster.
# The cluster's entrypoint only creates the database it was generated with.
ensure_instance_mongo_database() {
    local env_file="${MAESTRO_DIR}/.env"
    local router database username password uri attempt=0 max_attempts=60

    router="$(read_env_value "$env_file" "MONGODB_HOST")"
    database="$(read_env_value "$env_file" "MONGODB_DB_NAME")"
    username="$(read_env_value "$env_file" "MONGODB_USER")"
    password="$(read_env_value "$env_file" "MONGODB_PASSWORD")"

    echo ""
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${BLUE}        Preparing MongoDB database: ${database}${NC}"
    echo -e "${BLUE}================================================================${NC}"
    echo ""

    if [ -z "$router" ] || [ -z "$database" ] || [ -z "$username" ] || [ -z "$password" ]; then
        print_error "MONGODB_HOST, MONGODB_DB_NAME, MONGODB_USER and MONGODB_PASSWORD must be set in ${env_file}"
        exit 1
    fi

    if ! docker inspect "$router" >/dev/null 2>&1; then
        print_error "MongoDB router container not found: ${router}"
        exit 1
    fi

    uri="mongodb://localhost:27017/?tls=true&tlsCAFile=/certs/ca.crt.pem&tlsCertificateKeyFile=/certs/${router}.pem"

    # A freshly started router answers before its entrypoint has added the shards.
    until docker exec "$router" mongosh "$uri" --quiet \
        --eval 'db.getSiblingDB("config").shards.countDocuments({}) > 0' 2>/dev/null | grep -q 'true'; do
        attempt=$((attempt + 1))
        if [ "$attempt" -ge "$max_attempts" ]; then
            print_error "MongoDB router ${router} did not become ready"
            exit 1
        fi
        print_status "Waiting for MongoDB router ${router}... (${attempt}/${max_attempts})"
        sleep 5
    done

    docker exec \
        -e INSTANCE_DB="$database" \
        -e INSTANCE_USER="$username" \
        -e INSTANCE_PASSWORD="$password" \
        "$router" mongosh "$uri" --quiet --eval '
            const database = db.getSiblingDB(process.env.INSTANCE_DB);
            if (database.getUser(process.env.INSTANCE_USER)) {
                print("User " + process.env.INSTANCE_USER + " already exists on " + process.env.INSTANCE_DB);
            } else {
                database.createUser({
                    user: process.env.INSTANCE_USER,
                    pwd: process.env.INSTANCE_PASSWORD,
                    roles: [{ role: "readWrite", db: process.env.INSTANCE_DB }]
                });
                print("User " + process.env.INSTANCE_USER + " created on " + process.env.INSTANCE_DB);
            }
            try {
                sh.enableSharding(process.env.INSTANCE_DB);
            } catch (e) {
                print("Sharding not enabled (may already be enabled): " + e);
            }
        '

    print_status "MongoDB database ${database} is ready for instance ${ARPEGGIO_INSTANCE}"
}

# Nginx refuses to start when an upstream host does not resolve, so the gateway
# only routes to this instance and to the other instances that are running.
generate_gateway_for_running_instances() {
    local name
    local instances="$ARPEGGIO_INSTANCE"

    if [ ! -f "${NGINX_CLUSTER_DIR}/docker-compose.yml" ]; then
        return 0
    fi

    for name in $(list_instances); do
        [ "$name" != "$ARPEGGIO_INSTANCE" ] || continue
        if [ "$(docker inspect -f '{{.State.Running}}' "$(ARPEGGIO_INSTANCE="$name" maestro_container Api)" 2>/dev/null)" = "true" ]; then
            instances+=",${name}"
        fi
    done

    echo ""
    print_status "Regenerating Nginx gateway for running instances: ${instances}"
    (
        cd "$NGINX_CLUSTER_DIR"
        NGINX_DEPLOY_MODE=true NGINX_GATEWAY_INSTANCES="$instances" ./generate-cluster.sh
    )
}

start_full_stack() {
    start_infrastructure_clusters
    ensure_instance_mongo_database
    start_application_stack
    generate_gateway_for_running_instances
    start_gateway_cluster
}

restart_nginx_gateway() {
    local compose_file="${NGINX_CLUSTER_DIR}/docker-compose.yml"

    if [ ! -f "$compose_file" ]; then
        print_status "Skipping Nginx restart: no generated docker-compose.yml"
        return 0
    fi

    echo ""
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${BLUE}                 Restarting Nginx gateway${NC}"
    echo -e "${BLUE}================================================================${NC}"
    echo ""

    print_status "Restarting Nginx so it reloads current Maestro and Sinfonia upstreams"
    (
        cd "$NGINX_CLUSTER_DIR"
        docker_compose restart
    )
    print_status "Nginx gateway restarted"
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
    echo -e "${GREEN}            Instance ${ARPEGGIO_INSTANCE} is up${NC}"
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
        echo -e "${BLUE}Public entry points (Nginx gateway port ${NGINX_EXTERNAL_PORT:-80}, mode=${SINFONIA_GATEWAY_MODE:-path})${NC}"
        for i in "${!SINFONIA_APP_IDS[@]}"; do
            echo "  - ${SINFONIA_APP_IDS[$i]}: $(sinfonia_app_public_url "${NGINX_EXTERNAL_PORT:-80}" "$i")"
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

    export DOCKER_BUILDKIT=1

    select_instance
    print_status "Instance: ${ARPEGGIO_INSTANCE}"
    sync_instance_maestro_env
    validate_deploy_sources
    load_internal_network_name
    ensure_internal_network
    prepare_maestro_build_context
    install_deploy_dockerignore

    if [ "$SKIP_MAESTRO_BUILD" = "true" ]; then
        require_docker_image "$MAESTRO_IMAGE" "Maestro"
    else
        build_maestro_image
    fi

    if [ "$SKIP_FRONTEND_BUILD" = "true" ]; then
        local i
        for i in "${!SINFONIA_APP_IDS[@]}"; do
            require_docker_image "${SINFONIA_APP_IMAGES[$i]}" "Sinfonia ${SINFONIA_APP_IDS[$i]}"
        done
    else
        build_sinfonia_image
    fi

    generate_application_compose_files
    remove_legacy_stack
    start_full_stack
    restart_nginx_gateway
    print_system_up_summary
}

main "$@"
