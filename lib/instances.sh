#!/bin/bash
# Shared helpers for Solfeggio instances.
#
# An instance is one named deployment: its own module set, Maestro containers,
# Sinfonia clients, MongoDB database, Redis database and Kafka topics. Instances
# share the infrastructure clusters and the Nginx gateway of one Docker host.
#
# Per-instance state:
#   apps/maestro/instances/<name>.env   Maestro env (seeded from apps/maestro/.env)
#   deploy/<name>/                      cloned sources, build manifests, compose files
#
# ARPEGGIO_INSTANCE names the instance in use; container, image and upstream
# names are derived from it. Empty keeps the un-instanced names (standalone
# cluster generators).

SOLFEGGIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARPEGGIO_INSTANCES_ENV_DIR="${SOLFEGGIO_DIR}/apps/maestro/instances"
ARPEGGIO_DEPLOY_ROOT="${SOLFEGGIO_DIR}/deploy"
# Instance last prepared by deploy.sh; systemUp.sh starts it when none is named.
ARPEGGIO_CURRENT_INSTANCE_FILE="${ARPEGGIO_DEPLOY_ROOT}/.current-instance"

# Lowercase only: the name ends up in Docker image tags and compose project names.
is_valid_instance_name() {
    [[ "${1:-}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]
}

instance_maestro_env_file() {
    echo "${ARPEGGIO_INSTANCES_ENV_DIR}/$1.env"
}

# Known instance names, one per line.
list_instances() {
    local env_file

    for env_file in "${ARPEGGIO_INSTANCES_ENV_DIR}"/*.env; do
        [ -f "$env_file" ] || continue
        basename "$env_file" .env
    done
}

# Maestro container for a role: Api, Kafka, Websocket, Cron, Assistant, Telegram.
maestro_container() {
    echo "maestro$1${ARPEGGIO_INSTANCE:+-${ARPEGGIO_INSTANCE}}"
}

# Selects the instance and points the deploy paths at its folder.
set_instance_paths() {
    ARPEGGIO_INSTANCE="$1"
    DEPLOY_DIR="${ARPEGGIO_DEPLOY_ROOT}/${ARPEGGIO_INSTANCE}"
    ARMONIA_DIR="${DEPLOY_DIR}/armonia"
    MAESTRO_DIR="${DEPLOY_DIR}/maestro"
    SINFONIA_DIR="${DEPLOY_DIR}/sinfonia"
    SINFONIA_APPS_ENV_FILE="${DEPLOY_DIR}/scripts/sinfonia-apps.env"
}
