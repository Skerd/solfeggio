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

# Load environment variables from .env file if it exists
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
    print_status "Loaded environment variables from .env file"
else
    print_warning ".env file not found. Using default values for ClamAV configuration."
fi

DOCKER_INTERNAL_NETWORK="${DOCKER_INTERNAL_NETWORK:-arpeggio_internal_network}"

# Function to validate input
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

# Function to get user input
get_user_input() {
    echo -e ""
    echo -e "${BLUE}================================================================${NC}"
    echo -e "Ready to configure the ClamAV cluster, please provide the needed information:"
    echo -e ""

    while true; do
        read -p "Enter number of ClamAV nodes (1-5) [default: 1]: " num_nodes
        num_nodes=${num_nodes:-1}
        if validate_number "$num_nodes" 1 5; then
            break
        fi
    done

    while true; do
        read -p "Enter ClamAV base external port (0-65535) [default: 3310]: " clamav_port
        clamav_port=${clamav_port:-3310}
        if validate_number "$clamav_port" 0 65535; then
            break
        fi
    done

    if [ -z "$CLAMAV_IMAGE" ]; then
        clamav_image="clamav/clamav-debian:latest"
        print_status "Using default ClamAV image: $clamav_image"
    else
        clamav_image="$CLAMAV_IMAGE"
        print_status "Using ClamAV image from environment variable: $clamav_image"
    fi

    if [ -z "$FRESHCLAM_CHECKS" ]; then
        freshclam_checks=12
        print_status "Using default FRESHCLAM_CHECKS: $freshclam_checks"
    else
        freshclam_checks="$FRESHCLAM_CHECKS"
        if ! validate_number "$freshclam_checks" 1 50; then
            print_error "FRESHCLAM_CHECKS from .env must be between 1 and 50"
            exit 1
        fi
        print_status "Using FRESHCLAM_CHECKS from environment variable: $freshclam_checks"
    fi

    if [ -z "$CLAMD_MAXTHREADS" ]; then
        clamd_maxthreads=10
        print_status "Using default CLAMD_MAXTHREADS: $clamd_maxthreads"
    else
        clamd_maxthreads="$CLAMD_MAXTHREADS"
        if ! validate_number "$clamd_maxthreads" 1 64; then
            print_error "CLAMD_MAXTHREADS from .env must be between 1 and 64"
            exit 1
        fi
        print_status "Using CLAMD_MAXTHREADS from environment variable: $clamd_maxthreads"
    fi

    if [ -z "$CLAMAV_SCAN_MOUNT" ]; then
        scan_mount=""
        print_status "No scan directory mount configured"
    else
        scan_mount="$CLAMAV_SCAN_MOUNT"
        if [ ! -d "$scan_mount" ]; then
            print_warning "Scan mount directory does not exist: $scan_mount"
            read -p "Create directory $scan_mount? (y/N): " create_scan_dir
            if [[ "$create_scan_dir" =~ ^[Yy]$ ]]; then
                mkdir -p "$scan_mount"
                print_status "Created scan mount directory: $scan_mount"
            else
                print_warning "Continuing without creating scan mount directory"
            fi
        else
            print_status "Using scan mount directory from environment variable: $scan_mount"
        fi
    fi

    echo -e ""
    print_status "Configuration Summary:"
    print_status "- Number of ClamAV nodes: ${GREEN}$num_nodes${NC}"
    print_status "- ClamAV base port: ${GREEN}$clamav_port${NC}"
    print_status "- ClamAV image: ${GREEN}$clamav_image${NC}"
    print_status "- FRESHCLAM_CHECKS: ${GREEN}$freshclam_checks${NC}"
    print_status "- CLAMD_MAXTHREADS: ${GREEN}$clamd_maxthreads${NC}"
    print_status "- Scan mount directory: ${GREEN}${scan_mount:-"None"}${NC}"
    if [ "$num_nodes" -gt 1 ]; then
        print_status "- Node ports: ${GREEN}$(for i in $(seq 1 $num_nodes); do echo -n "$((clamav_port + i - 1))"; if [ $i -lt $num_nodes ]; then echo -n ", "; fi; done)${NC}"
    fi
    echo -e "${BLUE}================================================================${NC}"
    echo ""

    read -p "Proceed with this configuration? (Y/n): " confirm
    confirm=${confirm:-y}
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_warning "Operation cancelled by user. NO docker-compose was generated!"
        exit 0
    fi
}

# Function to generate docker-compose.yml
generate_docker_compose() {
    local num_nodes=$1
    local clamav_port=$2
    local clamav_image=$3
    local freshclam_checks=$4
    local clamd_maxthreads=$5
    local scan_mount=$6

    print_status "Generating docker-compose.yml..."

    cat > docker-compose.yml << EOF
version: '3.8'

services:
EOF

    print_status " 1. Adding ${GREEN}ClamAV${NC} services"

    for i in $(seq 1 $num_nodes); do
        local external_port=$((clamav_port + i - 1))
        cat >> docker-compose.yml << EOF
  clamav-${i}:
    image: ${clamav_image}
    container_name: clamav-${i}
    hostname: clamav-${i}
    restart: unless-stopped
    ports:
      - "${external_port}:3310"
    volumes:
      - clamav-${i}-data:/var/lib/clamav
EOF
        if [ -n "$scan_mount" ]; then
            cat >> docker-compose.yml << EOF
      - ${scan_mount}:/mnt/scan:ro
EOF
        fi
        cat >> docker-compose.yml << EOF
    environment:
      FRESHCLAM_CHECKS: ${freshclam_checks}
      CLAMD_MAXTHREADS: ${clamd_maxthreads}
    networks:
      - arpeggio-internal
    healthcheck:
      test: ["CMD-SHELL", "clamdcheck.sh"]
      interval: 1m30s
      timeout: 10s
      retries: 3
      start_period: 5m

EOF
    done

    print_status " 2. Adding ${GREEN}volumes${NC} section"
    cat >> docker-compose.yml << EOF
volumes:
EOF
    for i in $(seq 1 $num_nodes); do
        cat >> docker-compose.yml << EOF
  clamav-${i}-data:
EOF
    done

    print_status " 3. Adding ${GREEN}networks${NC} section"
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
    local num_nodes=$1
    local clamav_port=$2

    print_status "Generating setup scripts..."

    print_status " 1. Creating ${GREEN}scripts${NC} directory"
    mkdir -p scripts

    print_status " 2. Creating ${GREEN}wait-for-clamav.sh${NC} script"
    cat > scripts/wait-for-clamav.sh << 'EOF'
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

check_clamav_node() {
    local node_id=$1
    local port=$2

    print_status "Checking clamav-${node_id} on port ${port}..."

    if command -v nc >/dev/null 2>&1; then
        if nc -z localhost "$port" 2>/dev/null; then
            print_status "clamav-${node_id} is accepting TCP connections on port ${port}"
            return 0
        fi
    elif command -v bash >/dev/null 2>&1; then
        if timeout 5 bash -c "echo > /dev/tcp/localhost/${port}" 2>/dev/null; then
            print_status "clamav-${node_id} is accepting TCP connections on port ${port}"
            return 0
        fi
    fi

    print_warning "clamav-${node_id} is not ready yet on port ${port}"
    return 1
}

if [ $# -lt 2 ]; then
    print_error "Usage: $0 <num_nodes> <base_port>"
    exit 1
fi

NUM_NODES=$1
BASE_PORT=$2

print_status "Waiting for all ClamAV nodes to become available..."
print_warning "Initial virus definition download may take several minutes on first startup."

for i in $(seq 1 "$NUM_NODES"); do
    port=$((BASE_PORT + i - 1))
    attempt=0
    max_attempts=60

    while ! check_clamav_node "$i" "$port"; do
        attempt=$((attempt + 1))
        if [ "$attempt" -ge "$max_attempts" ]; then
            print_error "Timed out waiting for clamav-${i} on port ${port}"
            exit 1
        fi
        sleep 10
    done
done

print_status "All ClamAV nodes are accepting connections."
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
    echo -e "${GREEN}[INFO]${NC} \$1"
}
print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} \$1"
}
print_error() {
    echo -e "${RED}[ERROR]${NC} \$1"
}

NUM_NODES=${num_nodes}
BASE_PORT=${clamav_port}
cluster_healthy=true

check_clamav_node() {
    local node_id=\$1
    local port=\$2

    print_status "Checking clamav-\${node_id} on port \${port}..."

    if command -v docker >/dev/null 2>&1; then
        local health=\$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "clamav-\${node_id}" 2>/dev/null)
        if [ "\$health" = "healthy" ]; then
            print_status "✓ clamav-\${node_id} container healthcheck is healthy"
            return 0
        elif [ "\$health" = "starting" ]; then
            print_warning "clamav-\${node_id} healthcheck is still starting"
            return 1
        fi
    fi

    if command -v nc >/dev/null 2>&1; then
        if nc -z localhost "\$port" 2>/dev/null; then
            print_status "✓ clamav-\${node_id} is listening on port \${port}"
            return 0
        fi
    elif timeout 5 bash -c "echo > /dev/tcp/localhost/\${port}" 2>/dev/null; then
        print_status "✓ clamav-\${node_id} is listening on port \${port}"
        return 0
    fi

    print_error "✗ clamav-\${node_id} is not healthy on port \${port}"
    return 1
}

print_status "Starting ClamAV cluster health check..."
echo ""

for i in \$(seq 1 \$NUM_NODES); do
    port=\$((BASE_PORT + i - 1))
    if ! check_clamav_node "\$i" "\$port"; then
        cluster_healthy=false
    fi
done

echo ""
print_status "=== Health Check Summary ==="
if \$cluster_healthy; then
    print_status "✓ ClamAV cluster is healthy and operational!"
    for i in \$(seq 1 \$NUM_NODES); do
        port=\$((BASE_PORT + i - 1))
        print_status "clamav-\${i}: localhost:\${port}"
    done
else
    print_error "✗ ClamAV cluster has issues that need attention"
    exit 1
fi
EOF

    print_status " 4. Creating ${GREEN}test-scan.sh${NC} script"
    cat > scripts/test-scan.sh << EOF
#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${GREEN}[INFO]${NC} \$1"
}
print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} \$1"
}
print_error() {
    echo -e "${RED}[ERROR]${NC} \$1"
}

BASE_PORT=${clamav_port}
TEST_FILE="scripts/eicar-test.txt"

create_test_file() {
    printf '%s' 'X5O!P%@AP[4\\PZX54(P^)7CC)7}\$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!\$H+H*' > "\$TEST_FILE"
}

scan_with_clamscan() {
    local node_id=\$1
    local port=\$2

    print_status "Testing scan on clamav-\${node_id} (localhost:\${port})..."

    if ! command -v docker >/dev/null 2>&1; then
        print_warning "docker CLI not available; skipping in-container scan test for clamav-\${node_id}"
        return 0
    fi

    local result
    result=\$(docker exec "clamav-\${node_id}" sh -c "printf '%s' 'X5O!P%@AP[4\\\\PZX54(P^)7CC)7}\$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!\$H+H*' | clamdscan -" 2>&1)

    if echo "\$result" | grep -qi "FOUND"; then
        print_status "✓ clamav-\${node_id} correctly detected the EICAR test signature"
        return 0
    fi

    print_warning "clamav-\${node_id} did not report EICAR as FOUND yet (definitions may still be loading)"
    print_warning "Response: \$result"
    return 1
}

print_status "Starting ClamAV functionality test..."
echo ""

create_test_file
all_passed=true

for i in \$(seq 1 ${num_nodes}); do
    port=\$((BASE_PORT + i - 1))
    if ! scan_with_clamscan "\$i" "\$port"; then
        all_passed=false
    fi
    echo ""
done

rm -f "\$TEST_FILE"

print_status "=== Test Summary ==="
if \$all_passed; then
    print_status "✓ ClamAV scan functionality tests passed!"
else
    print_warning "Some scan tests did not pass. Wait for virus definitions to finish downloading, then retry."
    exit 1
fi
EOF

    print_status " 5. Making ${GREEN}scripts${NC} executable"
    chmod +x scripts/*.sh

    print_status "Finished generating setup scripts"
    echo -e ""
}

# Main execution
main() {
    echo -e ""
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${BLUE}                xCloud ClamAV Cluster Generator${NC}"
    echo -e "${BLUE}================================================================${NC}"
    echo -e "This script will generate a dynamic ClamAV cluster configuration."
    echo -e "The cluster will have:"
    echo -e "- ${GREEN}N${NC} ClamAV daemon nodes (clamd on TCP port 3310)"
    echo -e "- ${GREEN}Dedicated volumes${NC} for virus definition storage per node"
    echo -e "- ${GREEN}Health checks${NC} using the official clamdcheck.sh probe"
    echo -e "- ${GREEN}Optional scan mount${NC} directory for file scanning"
    echo -e "${BLUE}================================================================${NC}"

    get_user_input
    NUM_NODES=$num_nodes
    BASE_PORT=$clamav_port

    generate_docker_compose "$NUM_NODES" "$BASE_PORT" "$clamav_image" "$freshclam_checks" "$clamd_maxthreads" "$scan_mount"
    generate_setup_scripts "$NUM_NODES" "$BASE_PORT"

    echo -e "${GREEN}================================================================${NC}"
    echo -e "${GREEN}               Generation completed successfully!${NC}"
    echo -e "${GREEN}================================================================${NC}"

    print_status "Generation completed successfully!"
    print_status "Files created:"
    print_status "- docker-compose.yml"
    print_status "- scripts/wait-for-clamav.sh"
    print_status "- scripts/health-check.sh"
    print_status "- scripts/test-scan.sh"
    echo ""
    print_status "To start the cluster, run: docker-compose up -d"
    print_status "To wait for services: ./scripts/wait-for-clamav.sh $NUM_NODES $BASE_PORT"
    print_status "To check health: ./scripts/health-check.sh"
    print_status "To test scanning: ./scripts/test-scan.sh"
    echo ""
    print_status "Maestro integration (.env):"
    print_status "- FILE_SCANNER_TYPE=clamav"
    print_status "- CLAMAV_HOST=localhost"
    print_status "- CLAMAV_PORT=$BASE_PORT"
    if [ "$NUM_NODES" -gt 1 ]; then
        print_warning "Multiple nodes detected. Maestro currently connects to a single host/port."
        print_warning "Use CLAMAV_PORT=$BASE_PORT for clamav-1, or add client-side failover/load balancing."
    fi
    echo ""
    print_status "Thank you for using xCloud ClamAV Cluster Generator"
    echo ""
    echo -e "${GREEN}================================================================${NC}"
    echo ""
}

# Run main function
main "$@"
