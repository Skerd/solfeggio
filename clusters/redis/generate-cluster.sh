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

# Docker creates a directory when a bind-mounted file path is missing.
# Remove those paths so config generation can write real files.
ensure_regular_file_path() {
    local path="$1"

    if [ -d "$path" ]; then
        print_warning "Removing directory at ${path} (expected a config file — likely created by Docker on a prior failed start)"
        rm -rf "$path"
    fi
}

# Load environment variables from .env file if it exists
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
    print_status "Loaded environment variables from .env file"
else
    print_warning ".env file not found. Using default values for Redis configuration."
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
    echo -e "Ready to configure the Redis cluster, please provide the needed information:"
    echo -e ""

    while true; do
        read -p "Enter number of Redis masters (1-3) [default: 1]: " num_masters
        num_masters=${num_masters:-1}
        if validate_number "$num_masters" 1 3; then
            break
        fi
    done

    while true; do
        read -p "Enter number of Redis replicas per master (1-3) [default: 2]: " num_replicas
        num_replicas=${num_replicas:-2}
        if validate_number "$num_replicas" 1 3; then
            break
        fi
    done

    while true; do
        read -p "Enter number of Sentinel nodes (3-5) [default: 3]: " num_sentinels
        num_sentinels=${num_sentinels:-3}
        if validate_number "$num_sentinels" 3 5; then
            break
        fi
    done

    while true; do
        read -p "Enter Redis external port (0-65535) [default: 17000]: " redis_port
        redis_port=${redis_port:-17000}
        if validate_number "$redis_port" 0 65535; then
            break
        fi
    done

    while true; do
        read -p "Enter Sentinel external port (0-65535) [default: 27100]: " sentinel_port
        sentinel_port=${sentinel_port:-27100}
        if validate_number "$sentinel_port" 0 65535; then
            break
        fi
    done

    # Use environment variables if available, otherwise use defaults
    if [ -z "$REDIS_PASSWORD" ]; then
        redis_password=""
        print_status "Using default Redis password (empty - no password)"
    else
        if [ ${#REDIS_PASSWORD} -lt 6 ] && [ -n "$REDIS_PASSWORD" ]; then
            print_error "REDIS_PASSWORD from .env must be at least 6 characters long"
            exit 1
        fi
        redis_password="$REDIS_PASSWORD"
        print_status "Using Redis password from environment variable"
    fi

    if [ -z "$REDIS_USERNAME" ]; then
        redis_username=""
        print_status "Using default Redis username (empty - default user)"
    else
        redis_username="$REDIS_USERNAME"
        print_status "Using Redis username from environment variable"
    fi

    if [ -z "$REDIS_DATABASE" ]; then
        redis_database=0
        print_status "Using default Redis database (0)"
    else
        redis_database="$REDIS_DATABASE"
        if ! validate_number "$redis_database" 0 15; then
            print_error "REDIS_DATABASE from .env must be between 0 and 15"
            exit 1
        fi
        print_status "Using Redis database from environment variable"
    fi

    if [ -z "$REDIS_KEY_PREFIX" ]; then
        redis_key_prefix=""
        print_status "Using default Redis key prefix (empty - no prefix)"
    else
        redis_key_prefix="$REDIS_KEY_PREFIX"
        print_status "Using Redis key prefix from environment variable"
    fi

    # Redis max memory limit (e.g. 256mb, 1gb, or empty for no limit)
    if [ -z "$REDIS_MAXMEMORY" ]; then
        redis_maxmemory=""
        print_status "Using default Redis memory (no limit)"
    else
        redis_maxmemory="$REDIS_MAXMEMORY"
        print_status "Using Redis max memory from environment variable: $redis_maxmemory"
    fi

    echo -e ""
    print_status "Configuration Summary:"
    print_status "- Number of Redis masters: ${GREEN}$num_masters${NC}"
    print_status "- Number of Redis replicas per master: ${GREEN}$num_replicas${NC}"
    print_status "- Number of Sentinel nodes: ${GREEN}$num_sentinels${NC}"
    print_status "- Redis external port: ${GREEN}$redis_port${NC}"
    print_status "- Sentinel external port: ${GREEN}$sentinel_port${NC}"
    print_status "- Redis password: ${GREEN}${redis_password:-"None"}${NC}"
    print_status "- Redis username: ${GREEN}${redis_username:-"None"}${NC}"
    print_status "- Redis database: ${GREEN}$redis_database${NC}"
    print_status "- Redis key prefix: ${GREEN}${redis_key_prefix:-"None"}${NC}"
    print_status "- Redis max memory: ${GREEN}${redis_maxmemory:-"No limit"}${NC}"
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
    local num_masters=$1
    local num_replicas=$2
    local num_sentinels=$3
    local redis_port=$4
    local sentinel_port=$5
    local redis_password=$6
    local redis_username=$7

    print_status "Generating docker-compose.yml..."

    cat > docker-compose.yml << EOF
version: '3.8'

services:
EOF

    # Calculate total Redis instances
    local total_redis=$((num_masters * (num_replicas + 1)))
    local redis_counter=1

    print_status " 1. Adding ${GREEN}Redis${NC} services"
    
    # Generate Redis masters and replicas
    for master_id in $(seq 1 $num_masters); do
        # Master node
        cat >> docker-compose.yml << EOF
  redis-master-${master_id}:
    image: redis:7.2-alpine
    container_name: redis-master-${master_id}
    hostname: redis-master-${master_id}
    ports:
      - "$((redis_port + redis_counter - 1)):6379"
    command: redis-server /usr/local/etc/redis/redis.conf
    volumes:
      - ./scripts/redis-master-${master_id}.conf:/usr/local/etc/redis/redis.conf
      - redis-master-${master_id}-data:/data
    env_file: ${ENV_FILE:-.env}
    restart: always
    networks:
      - arpeggio-internal
    healthcheck:
      test: ["CMD", "sh", "-c", "if [ -n \"$$REDIS_USERNAME\" ]; then redis-cli --user \"$$REDIS_USERNAME\" -a \"$$REDIS_PASSWORD\" ping; elif [ -n \"$$REDIS_PASSWORD\" ]; then redis-cli -a \"$$REDIS_PASSWORD\" ping; else redis-cli ping; fi"]
      interval: 10s
      timeout: 3s
      retries: 3

EOF
        redis_counter=$((redis_counter + 1))

        # Replica nodes for this master
        for replica_id in $(seq 1 $num_replicas); do
            cat >> docker-compose.yml << EOF
  redis-replica-${master_id}-${replica_id}:
    image: redis:7.2-alpine
    container_name: redis-replica-${master_id}-${replica_id}
    hostname: redis-replica-${master_id}-${replica_id}
    ports:
      - "$((redis_port + redis_counter - 1)):6379"
    command: redis-server /usr/local/etc/redis/redis.conf
    volumes:
      - ./scripts/redis-replica-${master_id}-${replica_id}.conf:/usr/local/etc/redis/redis.conf
      - redis-replica-${master_id}-${replica_id}-data:/data
    env_file: ${ENV_FILE:-.env}
    restart: always
    depends_on:
      - redis-master-${master_id}
    networks:
      - arpeggio-internal
    healthcheck:
      test: ["CMD", "sh", "-c", "if [ -n \"$$REDIS_USERNAME\" ]; then redis-cli --user \"$$REDIS_USERNAME\" -a \"$$REDIS_PASSWORD\" ping; elif [ -n \"$$REDIS_PASSWORD\" ]; then redis-cli -a \"$$REDIS_PASSWORD\" ping; else redis-cli ping; fi"]
      interval: 10s
      timeout: 3s
      retries: 3

EOF
            redis_counter=$((redis_counter + 1))
        done
    done

    print_status " 2. Adding ${GREEN}Sentinel${NC} services"
    
    # Generate Sentinel nodes
    for sentinel_id in $(seq 1 $num_sentinels); do
        cat >> docker-compose.yml << EOF
  redis-sentinel-${sentinel_id}:
    image: redis:7.2-alpine
    container_name: redis-sentinel-${sentinel_id}
    hostname: redis-sentinel-${sentinel_id}
    ports:
      - "$((sentinel_port + sentinel_id - 1)):26379"
    command: sh -c "sleep 30 && redis-sentinel /usr/local/etc/redis/sentinel.conf"
    volumes:
      - ./scripts/sentinel-${sentinel_id}.conf:/usr/local/etc/redis/sentinel.conf
      - redis-sentinel-${sentinel_id}-data:/data
    restart: always
    depends_on:
EOF
        # Add dependencies for all Redis masters
        for master_id in $(seq 1 $num_masters); do
            echo "      - redis-master-${master_id}" >> docker-compose.yml
        done
        cat >> docker-compose.yml << EOF
    networks:
      - arpeggio-internal
    healthcheck:
      test: ["CMD", "redis-cli", "-p", "26379", "ping"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s

EOF
    done



    print_status " 3. Adding ${GREEN}volumes${NC} section"
    cat >> docker-compose.yml << EOF
volumes:
EOF
    # Add volumes for all Redis instances
    for master_id in $(seq 1 $num_masters); do
        cat >> docker-compose.yml << EOF
  redis-master-${master_id}-data:
EOF
        for replica_id in $(seq 1 $num_replicas); do
            cat >> docker-compose.yml << EOF
  redis-replica-${master_id}-${replica_id}-data:
EOF
        done
    done
    # Add volumes for Sentinel nodes
    for sentinel_id in $(seq 1 $num_sentinels); do
        cat >> docker-compose.yml << EOF
  redis-sentinel-${sentinel_id}-data:
EOF
    done

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

# Function to generate Sentinel configurations
generate_sentinel_configs() {
    local num_masters=$1
    local num_sentinels=$2
    local redis_password=$3
    local redis_username=$4

    print_status "Generating Sentinel configurations..."

    print_status " 1. Creating ${GREEN}scripts${NC} directory"
    mkdir -p scripts

    # Generate Sentinel configuration for each Sentinel node
    for sentinel_id in $(seq 1 $num_sentinels); do
        print_status " 2. Creating ${GREEN}sentinel-${sentinel_id}.conf${NC}"
        ensure_regular_file_path "scripts/sentinel-${sentinel_id}.conf"
        cat > scripts/sentinel-${sentinel_id}.conf << EOF
port 26379
dir /data
sentinel monitor mymaster-1 redis-master-1 6379 2
sentinel down-after-milliseconds mymaster-1 5000
sentinel failover-timeout mymaster-1 10000
sentinel parallel-syncs mymaster-1 1
sentinel auth-pass mymaster-1 ${redis_password}
EOF
        if [ -n "$redis_username" ]; then
            echo "sentinel auth-user mymaster-1 ${redis_username}" >> scripts/sentinel-${sentinel_id}.conf
        fi
        # Add additional masters if more than 1
        for master_id in $(seq 2 $num_masters); do
            cat >> scripts/sentinel-${sentinel_id}.conf << EOF
sentinel monitor mymaster-${master_id} redis-master-${master_id} 6379 2
sentinel down-after-milliseconds mymaster-${master_id} 5000
sentinel failover-timeout mymaster-${master_id} 10000
sentinel parallel-syncs mymaster-${master_id} 1
sentinel auth-pass mymaster-${master_id} ${redis_password}
EOF
            if [ -n "$redis_username" ]; then
                echo "sentinel auth-user mymaster-${master_id} ${redis_username}" >> scripts/sentinel-${sentinel_id}.conf
            fi
        done
    done

    print_status "Finished generating Sentinel configurations"
    echo -e ""
}

# Function to generate Redis configurations
generate_redis_configs() {
    local num_masters=$1
    local num_replicas=$2
    local redis_password=$3
    local redis_username=$4
    local redis_maxmemory=$5

    print_status "Generating Redis configurations..."

    # Generate Redis master configurations
    for master_id in $(seq 1 $num_masters); do
        print_status " 2. Creating ${GREEN}redis-master-${master_id}.conf${NC}"
        ensure_regular_file_path "scripts/redis-master-${master_id}.conf"
        cat > scripts/redis-master-${master_id}.conf << EOF
# Redis Master Configuration
port 6379
bind 0.0.0.0
protected-mode no
tcp-backlog 511
timeout 0
tcp-keepalive 300
daemonize no
supervised no
pidfile /var/run/redis_6379.pid
loglevel notice
logfile ""
databases 16
always-show-logo yes
save 900 1
save 300 10
save 60 10000
stop-writes-on-bgsave-error yes
rdbcompression yes
rdbchecksum yes
dbfilename dump.rdb
dir /data
replica-serve-stale-data yes
replica-read-only yes
repl-diskless-sync no
repl-diskless-sync-delay 5
repl-ping-replica-period 10
repl-timeout 60
repl-disable-tcp-nodelay no
repl-backlog-size 1mb
repl-backlog-ttl 3600
replica-priority 100
EOF
        if [ -n "$redis_maxmemory" ]; then
            echo "maxmemory ${redis_maxmemory}" >> scripts/redis-master-${master_id}.conf
        fi
        cat >> scripts/redis-master-${master_id}.conf << EOF
maxmemory-policy noeviction
lazyfree-lazy-eviction no
lazyfree-lazy-expire no
lazyfree-lazy-server-del no
replica-lazy-flush no
appendonly yes
appendfilename "appendonly.aof"
appendfsync everysec
no-appendfsync-on-rewrite no
auto-aof-rewrite-percentage 100
auto-aof-rewrite-min-size 64mb
aof-load-truncated yes
aof-use-rdb-preamble yes
requirepass ${redis_password}
masterauth ${redis_password}
EOF
        # Add username configuration if provided
        if [ -n "$redis_username" ]; then
            cat >> scripts/redis-master-${master_id}.conf << EOF
user default on >${redis_password} ~* &* +@all
user ${redis_username} on >${redis_password} ~* &* +@all
EOF
        fi
    done

    # Generate Redis replica configurations
    for master_id in $(seq 1 $num_masters); do
        for replica_id in $(seq 1 $num_replicas); do
            print_status " 3. Creating ${GREEN}redis-replica-${master_id}-${replica_id}.conf${NC}"
            ensure_regular_file_path "scripts/redis-replica-${master_id}-${replica_id}.conf"
            cat > scripts/redis-replica-${master_id}-${replica_id}.conf << EOF
# Redis Replica Configuration
port 6379
bind 0.0.0.0
protected-mode no
tcp-backlog 511
timeout 0
tcp-keepalive 300
daemonize no
supervised no
pidfile /var/run/redis_6379.pid
loglevel notice
logfile ""
databases 16
always-show-logo yes
save 900 1
save 300 10
save 60 10000
stop-writes-on-bgsave-error yes
rdbcompression yes
rdbchecksum yes
dbfilename dump.rdb
dir /data
replica-serve-stale-data yes
replica-read-only yes
repl-diskless-sync no
repl-diskless-sync-delay 5
repl-ping-replica-period 10
repl-timeout 60
repl-disable-tcp-nodelay no
repl-backlog-size 1mb
repl-backlog-ttl 3600
replica-priority 100
EOF
            if [ -n "$redis_maxmemory" ]; then
                echo "maxmemory ${redis_maxmemory}" >> scripts/redis-replica-${master_id}-${replica_id}.conf
            fi
            cat >> scripts/redis-replica-${master_id}-${replica_id}.conf << EOF
maxmemory-policy noeviction
lazyfree-lazy-eviction no
lazyfree-lazy-expire no
lazyfree-lazy-server-del no
replica-lazy-flush no
appendonly yes
appendfilename "appendonly.aof"
appendfsync everysec
no-appendfsync-on-rewrite no
auto-aof-rewrite-percentage 100
auto-aof-rewrite-min-size 64mb
aof-load-truncated yes
aof-use-rdb-preamble yes
requirepass ${redis_password}
masterauth ${redis_password}
replicaof redis-master-${master_id} 6379
EOF
            # Add username configuration if provided
            if [ -n "$redis_username" ]; then
                cat >> scripts/redis-replica-${master_id}-${replica_id}.conf << EOF
user default on >${redis_password} ~* &* +@all
user ${redis_username} on >${redis_password} ~* &* +@all
EOF
            fi
        done
    done

    print_status "Finished generating Redis configurations"
    echo -e ""
}

# Function to generate setup scripts
generate_setup_scripts() {
    local num_masters=$1
    local num_replicas=$2
    local num_sentinels=$3
    local redis_port=$4
    local sentinel_port=$5
    local redis_password=$6
    local redis_username=$7

    print_status "Generating setup scripts..."

    print_status " 1. Creating ${GREEN}wait-for-redis.sh${NC} script"
    cat > scripts/wait-for-redis.sh << 'EOF'
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

# Function to check if Redis instance is ready
check_redis_instance() {
    local instance=$1
    local port=$2
    local password=$3
    local username=$4
    
    echo "Checking if $instance is ready on port $port..."
    
    # Try to connect to the Redis instance (Redis 6+ ACL: AUTH username password)
    if [ -n "$username" ]; then
        timeout 10 bash -c "echo 'AUTH $username $password' | redis-cli -h localhost -p $port" 2>/dev/null | grep -q "OK"
    elif [ -n "$password" ]; then
        timeout 10 bash -c "echo 'AUTH $password' | redis-cli -h localhost -p $port" 2>/dev/null | grep -q "OK"
    else
        timeout 10 bash -c "echo 'PING' | redis-cli -h localhost -p $port" 2>/dev/null | grep -q "PONG"
    fi
    
    if [ $? -eq 0 ]; then
        print_status "$instance is ready!"
        return 0
    else
        print_warning "$instance is not ready yet..."
        return 1
    fi
}

# Function to check if Sentinel is ready
check_sentinel_instance() {
    local instance=$1
    local port=$2
    
    echo "Checking if $instance is ready on port $port..."
    
    # Try to connect to the Sentinel instance
    timeout 10 bash -c "echo 'PING' | redis-cli -h localhost -p $port" 2>/dev/null | grep -q "PONG"
    
    if [ $? -eq 0 ]; then
        print_status "$instance is ready!"
        return 0
    else
        print_warning "$instance is not ready yet..."
        return 1
    fi
}

# Wait for all Redis instances to be ready
wait_for_redis_instances() {
    local num_masters=$1
    local num_replicas=$2
    local base_port=$3
    local password=$4
    local username=$5
    
    print_status "Waiting for all Redis instances to be ready..."
    
    local port_counter=$base_port
    
    # Wait for masters
    for i in $(seq 1 $num_masters); do
        local instance="redis-master-$i"
        while ! check_redis_instance "$instance" "$port_counter" "$password" "$username"; do
            sleep 5
        done
        port_counter=$((port_counter + 1))
    done
    
    # Wait for replicas
    for i in $(seq 1 $num_masters); do
        for j in $(seq 1 $num_replicas); do
            local instance="redis-replica-$i-$j"
            while ! check_redis_instance "$instance" "$port_counter" "$password" "$username"; do
                sleep 5
            done
            port_counter=$((port_counter + 1))
        done
    done
    
    print_status "All Redis instances are ready!"
}

# Wait for all Sentinel instances to be ready
wait_for_sentinel_instances() {
    local num_sentinels=$1
    local base_port=$2
    
    print_status "Waiting for all Sentinel instances to be ready..."
    
    for i in $(seq 1 $num_sentinels); do
        local instance="redis-sentinel-$i"
        local port=$((base_port + i - 1))
        while ! check_sentinel_instance "$instance" "$port"; do
            sleep 5
        done
    done
    
    print_status "All Sentinel instances are ready!"
}

# Main execution
if [ $# -lt 6 ]; then
    print_error "Usage: $0 <num_masters> <num_replicas> <num_sentinels> <redis_base_port> <sentinel_base_port> <password> [username]"
    exit 1
fi

NUM_MASTERS=$1
NUM_REPLICAS=$2
NUM_SENTINELS=$3
REDIS_BASE_PORT=$4
SENTINEL_BASE_PORT=$5
PASSWORD=$6
USERNAME=${7:-}

wait_for_redis_instances "$NUM_MASTERS" "$NUM_REPLICAS" "$REDIS_BASE_PORT" "$PASSWORD" "$USERNAME"
wait_for_sentinel_instances "$NUM_SENTINELS" "$SENTINEL_BASE_PORT"

print_status "All Redis cluster components are ready!"
EOF

    print_status " 2. Creating ${GREEN}health-check.sh${NC} script"
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

# Configuration
REDIS_PASSWORD="${redis_password}"
REDIS_USERNAME="${redis_username}"
REDIS_BASE_PORT=${redis_port}
SENTINEL_BASE_PORT=${sentinel_port}
NUM_MASTERS=${num_masters}
NUM_REPLICAS=${num_replicas}
NUM_SENTINELS=${num_sentinels}

# Function to check Redis instance health
check_redis_instance() {
    local instance_id=\$1
    local port=\$2
    local instance_type=\$3
    
    print_status "Checking \$instance_type \$instance_id on port \$port..."
    
    if [ -n "\$REDIS_USERNAME" ]; then
        if timeout 5 bash -c "echo 'AUTH \$REDIS_USERNAME \$REDIS_PASSWORD' | redis-cli -h localhost -p \$port" 2>/dev/null | grep -q "OK"; then
            print_status "✓ \$instance_type \$instance_id is healthy"
            return 0
        else
            print_error "✗ \$instance_type \$instance_id is not responding"
            return 1
        fi
    elif [ -n "\$REDIS_PASSWORD" ]; then
        if timeout 5 bash -c "echo 'AUTH \$REDIS_PASSWORD' | redis-cli -h localhost -p \$port" 2>/dev/null | grep -q "OK"; then
            print_status "✓ \$instance_type \$instance_id is healthy"
            return 0
        else
            print_error "✗ \$instance_type \$instance_id is not responding"
            return 1
        fi
    else
        if timeout 5 bash -c "echo 'PING' | redis-cli -h localhost -p \$port" 2>/dev/null | grep -q "PONG"; then
            print_status "✓ \$instance_type \$instance_id is healthy"
            return 0
        else
            print_error "✗ \$instance_type \$instance_id is not responding"
            return 1
        fi
    fi
}

# Function to check Sentinel instance health
check_sentinel_instance() {
    local sentinel_id=\$1
    local port=\$2
    
    print_status "Checking Sentinel \$sentinel_id on port \$port..."
    
    if timeout 5 bash -c "echo 'PING' | redis-cli -h localhost -p \$port" 2>/dev/null | grep -q "PONG"; then
        print_status "✓ Sentinel \$sentinel_id is healthy"
        return 0
    else
        print_error "✗ Sentinel \$sentinel_id is not responding"
        return 1
    fi
}

# Function to check Redis replication status
check_replication_status() {
    local master_id=\$1
    local port=\$((REDIS_BASE_PORT + master_id - 1))
    
    print_status "Checking replication status for master \$master_id..."
    
    if [ -n "\$REDIS_USERNAME" ]; then
        local role=\$(timeout 5 bash -c "echo 'AUTH \$REDIS_USERNAME \$REDIS_PASSWORD' | redis-cli -h localhost -p \$port info replication" 2>/dev/null | grep "role:" | cut -d: -f2 | tr -d '\r')
    elif [ -n "\$REDIS_PASSWORD" ]; then
        local role=\$(timeout 5 bash -c "echo 'AUTH \$REDIS_PASSWORD' | redis-cli -h localhost -p \$port info replication" 2>/dev/null | grep "role:" | cut -d: -f2 | tr -d '\r')
    else
        local role=\$(timeout 5 bash -c "redis-cli -h localhost -p \$port info replication" 2>/dev/null | grep "role:" | cut -d: -f2 | tr -d '\r')
    fi
    
    if [ "\$role" = "master" ]; then
        print_status "✓ Master \$master_id is properly configured as master"
        return 0
    else
        print_error "✗ Master \$master_id is not properly configured as master"
        return 1
    fi
}

# Function to check Sentinel monitoring
check_sentinel_monitoring() {
    local sentinel_id=\$1
    local port=\$((SENTINEL_BASE_PORT + sentinel_id - 1))
    
    print_status "Checking Sentinel \$sentinel_id monitoring status..."
    
    local masters=\$(timeout 5 bash -c "echo 'SENTINEL masters' | redis-cli -h localhost -p \$port" 2>/dev/null | grep "mymaster" | wc -l)
    
    if [ "\$masters" -eq \$NUM_MASTERS ]; then
        print_status "✓ Sentinel \$sentinel_id is monitoring \$masters masters"
        return 0
    else
        print_error "✗ Sentinel \$sentinel_id is not monitoring the expected number of masters"
        return 1
    fi
}

# Function to check Redis instance health
check_redis_instance() {
    local instance_id=\$1
    local port=\$2
    local instance_type=\$3
    
    print_status "Checking \$instance_type \$instance_id on port \$port..."
    
    if [ -n "\$REDIS_USERNAME" ]; then
        if timeout 5 bash -c "echo 'AUTH \$REDIS_USERNAME \$REDIS_PASSWORD' | redis-cli -h localhost -p \$port" 2>/dev/null | grep -q "OK"; then
            print_status "✓ \$instance_type \$instance_id is healthy"
            return 0
        else
            print_error "✗ \$instance_type \$instance_id is not responding"
            return 1
        fi
    elif [ -n "\$REDIS_PASSWORD" ]; then
        if timeout 5 bash -c "echo 'AUTH \$REDIS_PASSWORD' | redis-cli -h localhost -p \$port" 2>/dev/null | grep -q "OK"; then
            print_status "✓ \$instance_type \$instance_id is healthy"
            return 0
        else
            print_error "✗ \$instance_type \$instance_id is not responding"
            return 1
        fi
    else
        if timeout 5 bash -c "echo 'PING' | redis-cli -h localhost -p \$port" 2>/dev/null | grep -q "PONG"; then
            print_status "✓ \$instance_type \$instance_id is healthy"
            return 0
        else
            print_error "✗ \$instance_type \$instance_id is not responding"
            return 1
        fi
    fi
}

# Function to check Sentinel instance health
check_sentinel_instance() {
    local sentinel_id=\$1
    local port=\$2
    
    print_status "Checking Sentinel \$sentinel_id on port \$port..."
    
    if timeout 5 bash -c "echo 'PING' | redis-cli -h localhost -p \$port" 2>/dev/null | grep -q "PONG"; then
        print_status "✓ Sentinel \$sentinel_id is healthy"
        return 0
    else
        print_error "✗ Sentinel \$sentinel_id is not responding"
        return 1
    fi
}

# Function to check Redis replication status
check_replication_status() {
    local master_id=\$1
    local port=\$((REDIS_BASE_PORT + master_id - 1))
    
    print_status "Checking replication status for master \$master_id..."
    
    if [ -n "\$REDIS_USERNAME" ]; then
        local role=\$(timeout 5 bash -c "echo 'AUTH \$REDIS_USERNAME \$REDIS_PASSWORD' | redis-cli -h localhost -p \$port info replication" 2>/dev/null | grep "role:" | cut -d: -f2 | tr -d '\r')
    elif [ -n "\$REDIS_PASSWORD" ]; then
        local role=\$(timeout 5 bash -c "echo 'AUTH \$REDIS_PASSWORD' | redis-cli -h localhost -p \$port info replication" 2>/dev/null | grep "role:" | cut -d: -f2 | tr -d '\r')
    else
        local role=\$(timeout 5 bash -c "redis-cli -h localhost -p \$port info replication" 2>/dev/null | grep "role:" | cut -d: -f2 | tr -d '\r')
    fi
    
    if [ "\$role" = "master" ]; then
        print_status "✓ Master \$master_id is properly configured as master"
        return 0
    else
        print_error "✗ Master \$master_id is not properly configured as master"
        return 1
    fi
}

# Function to check Sentinel monitoring
check_sentinel_monitoring() {
    local sentinel_id=\$1
    local port=\$((SENTINEL_BASE_PORT + sentinel_id - 1))
    
    print_status "Checking Sentinel \$sentinel_id monitoring status..."
    
    local masters=\$(timeout 5 bash -c "echo 'SENTINEL masters' | redis-cli -h localhost -p \$port" 2>/dev/null | grep "mymaster" | wc -l)
    
    if [ "\$masters" -eq \$NUM_MASTERS ]; then
        print_status "✓ Sentinel \$sentinel_id is monitoring \$masters masters"
        return 0
    else
        print_error "✗ Sentinel \$sentinel_id is not monitoring the expected number of masters"
        return 1
    fi
}

# Main execution
print_status "Starting Redis cluster health check..."
echo ""

# Check Redis masters
print_status "=== Redis Masters Health Check ==="
redis_healthy=true
for i in \$(seq 1 \$NUM_MASTERS); do
    local port=\$((REDIS_BASE_PORT + i - 1))
    if ! check_redis_instance "\$i" "\$port" "Master"; then
        redis_healthy=false
    fi
    if ! check_replication_status "\$i"; then
        redis_healthy=false
    fi
done

echo ""

# Check Redis replicas
print_status "=== Redis Replicas Health Check ==="
for i in \$(seq 1 \$NUM_MASTERS); do
    for j in \$(seq 1 \$NUM_REPLICAS); do
        local port=\$((REDIS_BASE_PORT + NUM_MASTERS + (i-1)*NUM_REPLICAS + j - 1))
        if ! check_redis_instance "\$i-\$j" "\$port" "Replica"; then
            redis_healthy=false
        fi
    done
done

echo ""

# Check Sentinel instances
print_status "=== Sentinel Health Check ==="
sentinel_healthy=true
for i in \$(seq 1 \$NUM_SENTINELS); do
    local port=\$((SENTINEL_BASE_PORT + i - 1))
    if ! check_sentinel_instance "\$i" "\$port"; then
        sentinel_healthy=false
    fi
    if ! check_sentinel_monitoring "\$i" "\$port"; then
        sentinel_healthy=false
    fi
done

echo ""

# Summary
print_status "=== Health Check Summary ==="
if \$redis_healthy && \$sentinel_healthy; then
    print_status "✓ Redis cluster is healthy and operational!"
    print_status "Redis Commander: http://localhost:8081"
    print_status "Redis masters: \$(for i in \$(seq 1 \$NUM_MASTERS); do echo -n "localhost:\$((REDIS_BASE_PORT + i - 1))"; if [ \$i -lt \$NUM_MASTERS ]; then echo -n ", "; fi; done)"
    print_status "Sentinel nodes: \$(for i in \$(seq 1 \$NUM_SENTINELS); do echo -n "localhost:\$((SENTINEL_BASE_PORT + i - 1))"; if [ \$i -lt \$NUM_SENTINELS ]; then echo -n ", "; fi; done)"
else
    print_error "✗ Redis cluster has issues that need attention"
    exit 1
fi
EOF

    print_status " 3. Creating ${GREEN}test-cluster.sh${NC} script"
    cat > scripts/test-cluster.sh << EOF
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

# Configuration
REDIS_PASSWORD="${redis_password}"
REDIS_USERNAME="${redis_username}"
REDIS_BASE_PORT=${redis_port}
SENTINEL_BASE_PORT=${sentinel_port}
NUM_MASTERS=${num_masters}

# Function to test Redis operations
test_redis_operations() {
    local master_id=\$1
    local port=\$((REDIS_BASE_PORT + master_id - 1))
    
    print_status "Testing Redis operations on master \$master_id (port \$port)..."
    
    # Test basic operations (Redis 6+ ACL: AUTH username password)
    if [ -n "\$REDIS_USERNAME" ]; then
        echo "AUTH \$REDIS_USERNAME \$REDIS_PASSWORD" | redis-cli -h localhost -p \$port > /dev/null
        echo "SET test-key-\$master_id 'Hello from master \$master_id'" | redis-cli -h localhost -p \$port > /dev/null
        
        local result=\$(echo "GET test-key-\$master_id" | redis-cli -h localhost -p \$port)
        if [ "\$result" = "Hello from master \$master_id" ]; then
            print_status "✓ Master \$master_id: Basic operations working"
            echo "EXPIRE test-key-\$master_id 10" | redis-cli -h localhost -p \$port > /dev/null
            print_status "✓ Master \$master_id: Expiration working"
            echo "LPUSH test-list-\$master_id 'item1' 'item2' 'item3'" | redis-cli -h localhost -p \$port > /dev/null
            local list_length=\$(echo "LLEN test-list-\$master_id" | redis-cli -h localhost -p \$port)
            if [ "\$list_length" = "3" ]; then
                print_status "✓ Master \$master_id: List operations working"
            else
                print_error "✗ Master \$master_id: List operations failed"
                return 1
            fi
            echo "DEL test-key-\$master_id test-list-\$master_id" | redis-cli -h localhost -p \$port > /dev/null
            return 0
        else
            print_error "✗ Master \$master_id: Basic operations failed"
            return 1
        fi
    elif [ -n "\$REDIS_PASSWORD" ]; then
        echo "AUTH \$REDIS_PASSWORD" | redis-cli -h localhost -p \$port > /dev/null
        echo "SET test-key-\$master_id 'Hello from master \$master_id'" | redis-cli -h localhost -p \$port > /dev/null
        
        # Get the test key
        local result=\$(echo "GET test-key-\$master_id" | redis-cli -h localhost -p \$port)
        
        if [ "\$result" = "Hello from master \$master_id" ]; then
            print_status "✓ Master \$master_id: Basic operations working"
            
            # Test expiration
            echo "EXPIRE test-key-\$master_id 10" | redis-cli -h localhost -p \$port > /dev/null
            print_status "✓ Master \$master_id: Expiration working"
            
            # Test list operations
            echo "LPUSH test-list-\$master_id 'item1' 'item2' 'item3'" | redis-cli -h localhost -p \$port > /dev/null
            local list_length=\$(echo "LLEN test-list-\$master_id" | redis-cli -h localhost -p \$port)
            if [ "\$list_length" = "3" ]; then
                print_status "✓ Master \$master_id: List operations working"
            else
                print_error "✗ Master \$master_id: List operations failed"
                return 1
            fi
            
            # Clean up
            echo "DEL test-key-\$master_id test-list-\$master_id" | redis-cli -h localhost -p \$port > /dev/null
            
            return 0
        else
            print_error "✗ Master \$master_id: Basic operations failed"
            return 1
        fi
    else
        # Set a test key
        echo "SET test-key-\$master_id 'Hello from master \$master_id'" | redis-cli -h localhost -p \$port > /dev/null
        
        # Get the test key
        local result=\$(echo "GET test-key-\$master_id" | redis-cli -h localhost -p \$port)
        
        if [ "\$result" = "Hello from master \$master_id" ]; then
            print_status "✓ Master \$master_id: Basic operations working"
            
            # Test expiration
            echo "EXPIRE test-key-\$master_id 10" | redis-cli -h localhost -p \$port > /dev/null
            print_status "✓ Master \$master_id: Expiration working"
            
            # Test list operations
            echo "LPUSH test-list-\$master_id 'item1' 'item2' 'item3'" | redis-cli -h localhost -p \$port > /dev/null
            local list_length=\$(echo "LLEN test-list-\$master_id" | redis-cli -h localhost -p \$port)
            if [ "\$list_length" = "3" ]; then
                print_status "✓ Master \$master_id: List operations working"
            else
                print_error "✗ Master \$master_id: List operations failed"
                return 1
            fi
            
            # Clean up
            echo "DEL test-key-\$master_id test-list-\$master_id" | redis-cli -h localhost -p \$port > /dev/null
            
            return 0
        else
            print_error "✗ Master \$master_id: Basic operations failed"
            return 1
        fi
    fi
}

# Function to test Sentinel failover simulation
test_sentinel_failover() {
    print_status "Testing Sentinel failover capabilities..."
    
    # Get master information from Sentinel
    local sentinel_port=\$((SENTINEL_BASE_PORT + 1))
    local master_info=\$(echo "SENTINEL master mymaster-1" | redis-cli -h localhost -p \$sentinel_port)
    
    if [ -n "\$master_info" ]; then
        print_status "✓ Sentinel is providing master information"
        
        # Get current master IP and port
        local master_ip=\$(echo "\$master_info" | grep "ip" | cut -d' ' -f2)
        local master_port=\$(echo "\$master_info" | grep "port" | cut -d' ' -f2)
        
        print_status "Current master: \$master_ip:\$master_port"
        return 0
    else
        print_error "✗ Sentinel is not providing master information"
        return 1
    fi
}

# Main execution
print_status "Starting Redis cluster functionality test..."
echo ""

# Test Redis operations on all masters
redis_test_passed=true
for i in \$(seq 1 \$NUM_MASTERS); do
    if ! test_redis_operations "\$i"; then
        redis_test_passed=false
    fi
    echo ""
done

# Test Sentinel functionality
sentinel_test_passed=true
if ! test_sentinel_failover; then
    sentinel_test_passed=false
fi

echo ""

# Summary
print_status "=== Test Summary ==="
if \$redis_test_passed && \$sentinel_test_passed; then
    print_status "✓ All Redis cluster functionality tests passed!"
    print_status "The cluster is ready for production use."
else
    print_error "✗ Some tests failed. Please check the cluster configuration."
    exit 1
fi
EOF

    print_status " 6. Making ${GREEN}scripts${NC} executable"
    chmod +x scripts/*.sh

    print_status "Finished generating setup scripts"
    echo -e ""
}

# Main execution
main() {
    echo -e ""
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${BLUE}                xCloud Redis Cluster Generator${NC}"
    echo -e "${BLUE}================================================================${NC}"
    echo -e "This script will generate a dynamic Redis cluster configuration."
    echo -e "The cluster will have:"
    echo -e "- ${GREEN}N${NC} Redis Masters (for data distribution)"
    echo -e "- ${GREEN}N×R${NC} Redis Replicas (for redundancy)"
    echo -e "- ${GREEN}N${NC} Sentinel Nodes (for failover detection)"
    echo -e "- ${GREEN}Automatic failover${NC} capabilities"
    echo -e "${BLUE}================================================================${NC}"

    get_user_input
    NUM_MASTERS=$num_masters
    NUM_REPLICAS=$num_replicas
    NUM_SENTINELS=$num_sentinels
    REDIS_PORT=$redis_port
    SENTINEL_PORT=$sentinel_port
    REDIS_PASSWORD=$redis_password

    generate_docker_compose "$NUM_MASTERS" "$NUM_REPLICAS" "$NUM_SENTINELS" "$REDIS_PORT" "$SENTINEL_PORT" "$REDIS_PASSWORD" "$redis_username"
    generate_sentinel_configs "$NUM_MASTERS" "$NUM_SENTINELS" "$REDIS_PASSWORD" "$redis_username"
    generate_redis_configs "$NUM_MASTERS" "$NUM_REPLICAS" "$REDIS_PASSWORD" "$redis_username" "$redis_maxmemory"
    generate_setup_scripts "$NUM_MASTERS" "$NUM_REPLICAS" "$NUM_SENTINELS" "$REDIS_PORT" "$SENTINEL_PORT" "$REDIS_PASSWORD" "$redis_username"

    echo -e "${GREEN}================================================================${NC}"
    echo -e "${GREEN}               Generation completed successfully!${NC}"
    echo -e "${GREEN}================================================================${NC}"

    print_status "Generation completed successfully!"
    print_status "Files created:"
    print_status "- docker-compose.yml"
    print_status "- scripts/sentinel-*.conf"
    print_status "- scripts/wait-for-redis.sh"
    print_status "- scripts/health-check.sh"
    print_status "- scripts/test-cluster.sh"
    echo ""
    print_status "To start the cluster, run: docker-compose up -d"
    print_status "To wait for services to be ready: ./scripts/wait-for-redis.sh $NUM_MASTERS $NUM_REPLICAS $NUM_SENTINELS $REDIS_PORT $SENTINEL_PORT \"$REDIS_PASSWORD\" ${redis_username:+\"$redis_username\"}"
    print_status "To check health: ./scripts/health-check.sh"
    print_status "To test functionality: ./scripts/test-cluster.sh"
    echo ""
    print_status "Thank you for using xCloud Redis Cluster Generator"
    echo ""
}

# Run main function
main "$@"
