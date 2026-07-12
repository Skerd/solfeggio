#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}
print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}
print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

ENV_FILE=".env"

# Load environment variables from .env file if it exists
if [ -f "$ENV_FILE" ]; then
    export $(grep -v '^#' "$ENV_FILE" | xargs)
    print_status "Loaded environment variables from .env file"
else
    print_warning ".env file not found. Using default values for Ollama configuration."
fi

DOCKER_INTERNAL_NETWORK="${DOCKER_INTERNAL_NETWORK:-arpeggio_internal_network}"
OLLAMA_HOST="${OLLAMA_HOST:-ollama}"
OLLAMA_INTERNAL_PORT="${OLLAMA_INTERNAL_PORT:-11434}"

# Persist a key=value back into .env so deploy.sh can source authoritative values.
set_env_var() {
    local key="$1"
    local value="$2"
    local tmp

    if [ ! -f "$ENV_FILE" ]; then
        printf '%s=%s\n' "$key" "$value" > "$ENV_FILE"
        return 0
    fi

    tmp="$(mktemp)"
    awk -v key="$key" -v val="$value" '
        BEGIN { found = 0 }
        $0 ~ "^" key "=" { print key "=" val; found = 1; next }
        { print }
        END { if (!found) print key "=" val }
    ' "$ENV_FILE" > "$tmp"
    mv "$tmp" "$ENV_FILE"
}

# Function to validate a numeric input
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

# Function to gather user input
get_user_input() {
    echo -e ""
    echo -e "${BLUE}================================================================${NC}"
    echo -e "Ready to configure the Ollama cluster, please provide the needed information:"
    echo -e ""

    while true; do
        read -p "Enter Ollama external port (0-65535) [default: ${OLLAMA_EXTERNAL_PORT:-11434}]: " ollama_port
        ollama_port=${ollama_port:-${OLLAMA_EXTERNAL_PORT:-11434}}
        if validate_number "$ollama_port" 0 65535; then
            break
        fi
    done

    read -p "Enter Ollama model tag [default: ${OLLAMA_MODEL:-llama3.1:8b}]: " ollama_model
    ollama_model=${ollama_model:-${OLLAMA_MODEL:-llama3.1:8b}}

    if [ -z "$OLLAMA_IMAGE" ]; then
        ollama_image="ollama/ollama:latest"
        print_status "Using default Ollama image: $ollama_image"
    else
        ollama_image="$OLLAMA_IMAGE"
        print_status "Using Ollama image from environment variable: $ollama_image"
    fi

    echo -e ""
    print_status "Configuration Summary:"
    print_status "- Ollama container:  ${GREEN}${OLLAMA_HOST}${NC}"
    print_status "- Internal port:     ${GREEN}${OLLAMA_INTERNAL_PORT}${NC} (used by Maestro on the internal network)"
    print_status "- External port:     ${GREEN}${ollama_port}${NC} (host access/debugging)"
    print_status "- Model:             ${GREEN}${ollama_model}${NC}"
    print_status "- Image:             ${GREEN}${ollama_image}${NC}"
    print_status "- Docker network:    ${GREEN}${DOCKER_INTERNAL_NETWORK}${NC}"
    echo -e "${BLUE}================================================================${NC}"
    echo ""

    read -p "Proceed with this configuration? (Y/n): " confirm
    confirm=${confirm:-y}
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_warning "Operation cancelled by user. NO docker-compose was generated!"
        exit 0
    fi

    # Persist choices so deploy.sh can source authoritative values.
    set_env_var "OLLAMA_EXTERNAL_PORT" "$ollama_port"
    set_env_var "OLLAMA_MODEL" "$ollama_model"
    set_env_var "OLLAMA_IMAGE" "$ollama_image"
}

# Function to generate docker-compose.yml
generate_docker_compose() {
    local ollama_port=$1
    local ollama_model=$2
    local ollama_image=$3

    print_status "Generating docker-compose.yml..."

    print_status " 1. Adding ${GREEN}Ollama${NC} server service"
    cat > docker-compose.yml << EOF
version: '3.8'

services:
  ${OLLAMA_HOST}:
    image: ${ollama_image}
    container_name: ${OLLAMA_HOST}
    hostname: ${OLLAMA_HOST}
    restart: unless-stopped
    ports:
      - "${ollama_port}:${OLLAMA_INTERNAL_PORT}"
    volumes:
      - ollama-data:/root/.ollama
    environment:
      OLLAMA_HOST: 0.0.0.0:${OLLAMA_INTERNAL_PORT}
      OLLAMA_KEEP_ALIVE: 24h
    networks:
      - arpeggio-internal
    healthcheck:
      test: ["CMD-SHELL", "ollama list >/dev/null 2>&1 || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s
    # ---------------------------------------------------------------------
    # GPU acceleration (optional): requires the NVIDIA Container Toolkit on
    # the host. Uncomment to let Ollama use the GPU. CPU-only works as-is.
    # deploy:
    #   resources:
    #     reservations:
    #       devices:
    #         - driver: nvidia
    #           count: all
    #           capabilities: [gpu]

EOF

    print_status " 2. Adding ${GREEN}model puller${NC} (one-shot) for ${ollama_model}"
    cat >> docker-compose.yml << EOF
  ${OLLAMA_HOST}-pull:
    image: ${ollama_image}
    container_name: ${OLLAMA_HOST}-pull
    depends_on:
      ${OLLAMA_HOST}:
        condition: service_healthy
    environment:
      OLLAMA_HOST: http://${OLLAMA_HOST}:${OLLAMA_INTERNAL_PORT}
    entrypoint: ["/bin/sh", "-c"]
    command:
      - >
        echo 'Pulling model ${ollama_model} into the Ollama server...' &&
        ollama pull ${ollama_model} &&
        echo 'Model ${ollama_model} is ready.'
    networks:
      - arpeggio-internal
    restart: "no"

EOF

    print_status " 3. Adding ${GREEN}volumes${NC} section"
    cat >> docker-compose.yml << EOF
volumes:
  ollama-data:

EOF

    print_status " 4. Adding ${GREEN}networks${NC} section"
    cat >> docker-compose.yml << EOF
networks:
  arpeggio-internal:
    external: true
    name: ${DOCKER_INTERNAL_NETWORK}
EOF

    print_status "Finished generating docker-compose.yml"
    echo -e ""
}

# Function to generate helper scripts
generate_setup_scripts() {
    local ollama_port=$1
    local ollama_model=$2

    print_status "Generating setup scripts..."

    print_status " 1. Creating ${GREEN}scripts${NC} directory"
    mkdir -p scripts

    print_status " 2. Creating ${GREEN}wait-for-ollama.sh${NC} script"
    cat > scripts/wait-for-ollama.sh << 'EOF'
#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

if [ $# -lt 1 ]; then
    print_error "Usage: $0 <external_port> [model]"
    exit 1
fi

PORT="$1"
MODEL="${2:-}"

print_status "Waiting for Ollama on localhost:${PORT}..."
print_warning "First startup downloads the model and may take several minutes."

attempt=0
max_attempts=120
until curl -fsS "http://localhost:${PORT}/api/tags" >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge "$max_attempts" ]; then
        print_error "Timed out waiting for Ollama on port ${PORT}"
        exit 1
    fi
    sleep 5
done
print_status "Ollama API is responding on port ${PORT}."

if [ -n "$MODEL" ]; then
    print_status "Waiting for model ${MODEL} to be available..."
    attempt=0
    until curl -fsS "http://localhost:${PORT}/api/tags" 2>/dev/null | grep -q "$MODEL"; do
        attempt=$((attempt + 1))
        if [ "$attempt" -ge "$max_attempts" ]; then
            print_error "Timed out waiting for model ${MODEL} to be pulled"
            exit 1
        fi
        sleep 5
    done
    print_status "Model ${MODEL} is available."
fi
EOF

    print_status " 3. Creating ${GREEN}health-check.sh${NC} script"
    cat > scripts/health-check.sh << EOF
#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_status() {
    echo -e "\${GREEN}[INFO]\${NC} \$1"
}
print_warning() {
    echo -e "\${YELLOW}[WARNING]\${NC} \$1"
}
print_error() {
    echo -e "\${RED}[ERROR]\${NC} \$1"
}

PORT=${ollama_port}
MODEL="${ollama_model}"
healthy=true

print_status "Checking Ollama container health..."
if command -v docker >/dev/null 2>&1; then
    health=\$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${OLLAMA_HOST}" 2>/dev/null)
    if [ "\$health" = "healthy" ]; then
        print_status "✓ ${OLLAMA_HOST} container healthcheck is healthy"
    elif [ "\$health" = "starting" ]; then
        print_warning "${OLLAMA_HOST} healthcheck is still starting"
        healthy=false
    else
        print_warning "${OLLAMA_HOST} container health: \${health:-unknown}"
    fi
fi

print_status "Checking Ollama API on localhost:\${PORT}..."
if curl -fsS "http://localhost:\${PORT}/api/tags" >/dev/null 2>&1; then
    print_status "✓ Ollama API is responding"
else
    print_error "✗ Ollama API is not responding on port \${PORT}"
    healthy=false
fi

if [ -n "\$MODEL" ]; then
    if curl -fsS "http://localhost:\${PORT}/api/tags" 2>/dev/null | grep -q "\$MODEL"; then
        print_status "✓ Model \${MODEL} is available"
    else
        print_warning "Model \${MODEL} is not available yet (it may still be pulling)"
        healthy=false
    fi
fi

echo ""
print_status "=== Health Check Summary ==="
if \$healthy; then
    print_status "✓ Ollama is healthy and serving \${MODEL} on localhost:\${PORT}"
else
    print_error "✗ Ollama has issues that need attention"
    exit 1
fi
EOF

    print_status " 4. Making ${GREEN}scripts${NC} executable"
    chmod +x scripts/*.sh

    print_status "Finished generating setup scripts"
    echo -e ""
}

# Main execution
main() {
    echo -e ""
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${BLUE}                xCloud Ollama Cluster Generator${NC}"
    echo -e "${BLUE}================================================================${NC}"
    echo -e "This script will generate a local-LLM (Ollama) cluster for the"
    echo -e "AI-assistant chat. The cluster will have:"
    echo -e "- ${GREEN}One Ollama server${NC} (OpenAI-free, serves the model over :11434)"
    echo -e "- ${GREEN}A one-shot model puller${NC} that pulls the chosen model on startup"
    echo -e "- ${GREEN}A persistent volume${NC} so pulled models survive restarts"
    echo -e "- ${GREEN}Health checks${NC} and wait/health helper scripts"
    echo -e "${BLUE}================================================================${NC}"

    get_user_input

    generate_docker_compose "$ollama_port" "$ollama_model" "$ollama_image"
    generate_setup_scripts "$ollama_port" "$ollama_model"

    echo -e "${GREEN}================================================================${NC}"
    echo -e "${GREEN}               Generation completed successfully!${NC}"
    echo -e "${GREEN}================================================================${NC}"

    print_status "Files created:"
    print_status "- docker-compose.yml"
    print_status "- scripts/wait-for-ollama.sh"
    print_status "- scripts/health-check.sh"
    echo ""
    print_status "To start the cluster, run: docker-compose up -d"
    print_status "To wait for the model: ./scripts/wait-for-ollama.sh ${ollama_port} ${ollama_model}"
    print_status "To check health: ./scripts/health-check.sh"
    echo ""
    print_status "Maestro integration (.env), set automatically by deploy.sh:"
    print_status "- AI_ASSISTANT_ENABLED=true"
    print_status "- AI_ASSISTANT_BASE_URL=http://${OLLAMA_HOST}:${OLLAMA_INTERNAL_PORT}"
    print_status "- AI_ASSISTANT_MODEL=${ollama_model}"
    echo ""
    echo -e "${GREEN}================================================================${NC}"
    echo ""
}

# Run main function
main "$@"
