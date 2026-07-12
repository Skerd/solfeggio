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
CLUSTERS_DIR="${SCRIPT_DIR}/clusters"

# Generated cluster artifacts (see .gitignore). Cluster .env files and templates
# like .env.test and generate-cluster.sh are preserved.
CLUSTER_GENERATED_PATHS=(
    "kafka/docker-compose.yml"
    "kafka/README.md"
    "kafka/scripts"
    "kafka/certs"
    "kafka/secrets"
    "mongo/docker-compose.yml"
    "mongo/scripts"
    "mongo/certs"
    "redis/docker-compose.yml"
    "redis/scripts"
    "clamv/docker-compose.yml"
    "clamv/scripts"
    "ollama/docker-compose.yml"
    "ollama/scripts"
    "nginx/docker-compose.yml"
    "nginx/README.md"
    "nginx/conf"
    "nginx/scripts"
    "prometheus/docker-compose.yml"
    "prometheus/prometheus.yml"
    "prometheus/scripts"
)

remove_path_if_exists() {
    local target="$1"

    if [ ! -e "$target" ]; then
        return 0
    fi

    rm -rf "$target"
    print_status "Removed ${target}"
}

clean_deploy_folder() {
    if [ ! -e "$DEPLOY_DIR" ]; then
        print_status "Deploy folder not found, nothing to remove: ${DEPLOY_DIR}"
        return 0
    fi

    print_status "Removing deploy folder: ${DEPLOY_DIR}"
    rm -rf "$DEPLOY_DIR"
    print_status "Deploy folder removed"
}

clean_generated_cluster_files() {
    local relative_path cluster_path

    echo ""
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${BLUE}            Cleaning generated cluster files${NC}"
    echo -e "${BLUE}================================================================${NC}"
    echo ""

    for relative_path in "${CLUSTER_GENERATED_PATHS[@]}"; do
        cluster_path="${CLUSTERS_DIR}/${relative_path}"
        remove_path_if_exists "$cluster_path"
    done
}

confirm_cleanup() {
    echo ""
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${BLUE}                   Clean deployment${NC}"
    echo -e "${BLUE}================================================================${NC}"
    echo ""
    echo "This will permanently delete:"
    echo "  - ${DEPLOY_DIR}"
    echo "  - Generated cluster files under ${CLUSTERS_DIR}"
    echo ""
    echo "Preserved:"
    echo "  - cluster .env and .env.test files"
    echo "  - cluster generate-cluster.sh scripts"
    echo "  - apps/maestro/.env (not reverted)"
    echo ""

    while true; do
        read -r -p "Continue with cleanup? (y/N): " confirm_input
        case "${confirm_input:-N}" in
            [Yy]|[Yy][Ee][Ss])
                return 0
                ;;
            [Nn]|[Nn][Oo]|"")
                print_warning "Cleanup cancelled"
                exit 0
                ;;
            *)
                print_warning "Please answer y or n."
                ;;
        esac
    done
}

print_cleanup_summary() {
    echo ""
    echo -e "${GREEN}================================================================${NC}"
    echo -e "${GREEN}                 Cleanup completed${NC}"
    echo -e "${GREEN}================================================================${NC}"
    echo ""
    print_status "Deploy output removed"
    print_status "Generated cluster artifacts removed"
    print_status "Run ./deploy.sh to prepare a fresh deployment"
    echo -e "${GREEN}================================================================${NC}"
    echo ""
}

main() {
    confirm_cleanup
    clean_deploy_folder
    clean_generated_cluster_files
    print_cleanup_summary
}

main "$@"
