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

# Function to validate port availability
check_port() {
    local port=$1
    if lsof -Pi :$port -sTCP:LISTEN -t >/dev/null 2>&1 ; then
        print_warning "Port $port is already in use"
        return 1
    fi
    return 0
}

# Function to get user input
get_user_input() {
    echo -e ""
    echo -e "${BLUE}================================================================${NC}"
    echo -e "Ready to configure the Prometheus cluster, please provide the needed information:"
    echo -e ""

    while true; do
        read -p "Enter Prometheus external port (0-65535) [default: 9090]: " prometheus_port
        prometheus_port=${prometheus_port:-9090}
        if validate_number "$prometheus_port" 0 65535; then
            if check_port "$prometheus_port"; then
                break
            else
                read -p "Port $prometheus_port is in use. Continue anyway? (y/N): " continue_anyway
                if [[ "$continue_anyway" =~ ^[Yy]$ ]]; then
                    break
                fi
            fi
        fi
    done

    while true; do
        read -p "Enter Grafana external port (0-65535) [default: 3000]: " grafana_port
        grafana_port=${grafana_port:-3000}
        if validate_number "$grafana_port" 0 65535; then
            if check_port "$grafana_port"; then
                break
            else
                read -p "Port $grafana_port is in use. Continue anyway? (y/N): " continue_anyway
                if [[ "$continue_anyway" =~ ^[Yy]$ ]]; then
                    break
                fi
            fi
        fi
    done

    read -p "Enter target application host (for scraping metrics) [default: host.docker.internal]: " target_host
    target_host=${target_host:-host.docker.internal}

    read -p "Enter target application port [default: 3000]: " target_port
    target_port=${target_port:-3000}

    read -p "Enter metrics path [default: /auxiliary/metrics]: " metrics_path
    metrics_path=${metrics_path:-/auxiliary/metrics}

    read -p "Enter scrape interval (e.g., 15s, 30s, 1m) [default: 15s]: " scrape_interval
    scrape_interval=${scrape_interval:-15s}

    read -p "Include Grafana? (y/N): " include_grafana
    include_grafana=${include_grafana:-n}

    echo -e ""
    print_status "Configuration Summary:"
    print_status "- Prometheus port: ${GREEN}$prometheus_port${NC}"
    print_status "- Grafana port: ${GREEN}$grafana_port${NC} ${YELLOW}(if enabled)${NC}"
    print_status "- Target host: ${GREEN}$target_host${NC}"
    print_status "- Target port: ${GREEN}$target_port${NC}"
    print_status "- Metrics path: ${GREEN}$metrics_path${NC}"
    print_status "- Scrape interval: ${GREEN}$scrape_interval${NC}"
    print_status "- Grafana included: ${GREEN}$include_grafana${NC}"
    echo -e "${BLUE}================================================================${NC}"
    echo ""

    read -p "Proceed with this configuration? (Y/n): " confirm
    confirm=${confirm:-y}
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_warning "Operation cancelled by user. NO docker-compose was generated!"
        exit 0
    fi
}

# Function to generate prometheus.yml
generate_prometheus_config() {
    local target_host=$1
    local target_port=$2
    local metrics_path=$3
    local scrape_interval=$4

    cat > prometheus.yml << EOF
global:
  scrape_interval: $scrape_interval
  evaluation_interval: $scrape_interval
  external_labels:
    cluster: 'arpeggio-maestro'
    environment: 'development'

scrape_configs:
  - job_name: 'arpeggio-maestro'
    metrics_path: '$metrics_path'
    static_configs:
      - targets: ['$target_host:$target_port']
        labels:
          service: 'maestro-api'
          instance: 'maestro-1'

  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']
        labels:
          service: 'prometheus'
EOF

    print_status "Generated prometheus.yml configuration"
}

# Function to generate docker-compose.yml
generate_docker_compose() {
    local prometheus_port=$1
    local grafana_port=$2
    local include_grafana=$3

    cat > docker-compose.yml << EOF
version: '3.8'

services:
  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    hostname: prometheus
    ports:
      - "$prometheus_port:9090"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml
      - prometheus-data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--storage.tsdb.retention.time=30d'
      - '--web.console.libraries=/usr/share/prometheus/console_libraries'
      - '--web.console.templates=/usr/share/prometheus/consoles'
      - '--web.enable-lifecycle'
    restart: always
    networks:
      - arpeggio-internal
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:9090/-/healthy"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s
EOF

    if [[ "$include_grafana" =~ ^[Yy]$ ]]; then
        cat >> docker-compose.yml << EOF

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    hostname: grafana
    ports:
      - "$grafana_port:3000"
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=admin
      - GF_USERS_ALLOW_SIGN_UP=false
      - GF_SERVER_ROOT_URL=http://localhost:$grafana_port
      - GF_INSTALL_PLUGINS=
    volumes:
      - grafana-data:/var/lib/grafana
      - ./scripts/grafana-datasource.yml:/etc/grafana/provisioning/datasources/datasource.yml
    restart: always
    depends_on:
      - prometheus
    networks:
      - arpeggio-internal
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:3000/api/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
EOF
    fi

    cat >> docker-compose.yml << EOF

volumes:
  prometheus-data:
EOF

    if [[ "$include_grafana" =~ ^[Yy]$ ]]; then
        cat >> docker-compose.yml << EOF
  grafana-data:
EOF
    fi

    cat >> docker-compose.yml << EOF

networks:
  arpeggio-internal:
    external: true
    name: ${DOCKER_INTERNAL_NETWORK}
EOF

    print_status "Generated docker-compose.yml"
}

# Function to generate Grafana datasource configuration
generate_grafana_datasource() {
    mkdir -p scripts
    cat > scripts/grafana-datasource.yml << EOF
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: true
EOF

    print_status "Generated Grafana datasource configuration"
}

# Main execution
main() {
    if [ -f .env ]; then
        set -a
        # shellcheck disable=SC1091
        source .env
        set +a
        print_status "Loaded environment variables from .env file"
    fi

    DOCKER_INTERNAL_NETWORK="${DOCKER_INTERNAL_NETWORK:-arpeggio_internal_network}"

    print_status "Starting Prometheus cluster generator..."
    
    # Get user input
    get_user_input
    
    # Generate prometheus.yml
    generate_prometheus_config "$target_host" "$target_port" "$metrics_path" "$scrape_interval"
    
    # Generate docker-compose.yml
    generate_docker_compose "$prometheus_port" "$grafana_port" "$include_grafana"
    
    # Generate Grafana datasource if Grafana is included
    if [[ "$include_grafana" =~ ^[Yy]$ ]]; then
        generate_grafana_datasource
    fi
    
    print_status "Prometheus cluster configuration generated successfully!"
    echo ""
    print_status "Next steps:"
    print_status "1. Review the generated files:"
    print_status "   - docker-compose.yml"
    print_status "   - prometheus.yml"
    if [[ "$include_grafana" =~ ^[Yy]$ ]]; then
        print_status "   - scripts/grafana-datasource.yml"
    fi
    echo ""
    print_status "2. Start the cluster:"
    print_status "   ${GREEN}docker-compose up -d${NC}"
    echo ""
    print_status "3. Access Prometheus:"
    print_status "   ${GREEN}http://localhost:$prometheus_port${NC}"
    if [[ "$include_grafana" =~ ^[Yy]$ ]]; then
        print_status "4. Access Grafana:"
        print_status "   ${GREEN}http://localhost:$grafana_port${NC}"
        print_status "   Default credentials: admin/admin"
    fi
    echo ""
    print_status "5. Verify metrics are being scraped:"
    print_status "   ${GREEN}http://localhost:$prometheus_port/targets${NC}"
    echo ""
}

# Run main function
main

