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
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
    print_status "Loaded environment variables from .env file"
else
    print_error ".env file not found. Please create .env with KAFKA_USERNAME and KAFKA_PASSWORD"
    exit 1
fi

DOCKER_INTERNAL_NETWORK="${DOCKER_INTERNAL_NETWORK:-arpeggio_internal_network}"
# Comma-separated extra IPs to include in every cert SAN (e.g. public host IP for external TLS clients)
TLS_EXTRA_SAN_IPS="${TLS_EXTRA_SAN_IPS:-}"

append_extra_san_ips() {
    local conf_file="$1"
    local ip_index=2
    local ip

    if [ -z "$TLS_EXTRA_SAN_IPS" ]; then
        return 0
    fi

    IFS=',' read -r -a extra_ips <<< "$TLS_EXTRA_SAN_IPS"
    for ip in "${extra_ips[@]}"; do
        ip="$(echo "$ip" | xargs)"
        if [ -n "$ip" ]; then
            echo "IP.${ip_index} = ${ip}" >> "$conf_file"
            ip_index=$((ip_index + 1))
        fi
    done
}

# Validate required environment variables
if [ -z "$KAFKA_USERNAME" ] || [ -z "$KAFKA_PASSWORD" ]; then
    print_error "Missing required environment variables in .env file: KAFKA_USERNAME, KAFKA_PASSWORD"
    exit 1
fi

# Optional credentials with defaults
KAFKA_BROKER_USERNAME="${KAFKA_BROKER_USERNAME:-admin}"
KAFKA_BROKER_PASSWORD="${KAFKA_BROKER_PASSWORD:-${KAFKA_PASSWORD}}"
KAFKA_SSL_STORE_PASSWORD="${KAFKA_SSL_STORE_PASSWORD:-changeit}"

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
    echo -e "Ready to configure the Kafka cluster, please provide the needed information:"
    echo -e ""

    while true; do
        read -p "Enter number of Kafka brokers (3-10) [default: 3]: " num_brokers
        num_brokers=${num_brokers:-3}
        if validate_number "$num_brokers" 3 10; then
            break
        fi
    done

    while true; do
        read -p "Enter Kafka external port (0-65535) [default: 9092]: " kafka_port
        kafka_port=${kafka_port:-9092}
        if validate_number "$kafka_port" 0 65535; then
            break
        fi
    done

    while true; do
        read -p "Enter replication factor for topics (1-$num_brokers) [default: 3]: " replication_factor
        replication_factor=${replication_factor:-3}
        if validate_number "$replication_factor" 1 "$num_brokers"; then
            break
        fi
    done

    while true; do
        read -p "Enter number of partitions per topic (1-50) [default: 3]: " partitions_per_topic
        partitions_per_topic=${partitions_per_topic:-3}
        if validate_number "$partitions_per_topic" 1 50; then
            break
        fi
    done

    echo -e ""
    print_status "Configuration Summary:"
    print_status "- Number of Kafka brokers: ${GREEN}$num_brokers${NC}"
    print_status "- Kafka external port: ${GREEN}$kafka_port${NC}"
    print_status "- Replication factor: ${GREEN}$replication_factor${NC}"
    print_status "- Partitions per topic: ${GREEN}$partitions_per_topic${NC}"
    print_status "- Mode: ${GREEN}KRaft (no Zookeeper)${NC}"
    print_status "- Security: ${GREEN}SASL_SSL (TLS + username/password)${NC}"
    print_status "- Client username: ${GREEN}$KAFKA_USERNAME${NC}"
    print_status "- Inter-broker username: ${GREEN}$KAFKA_BROKER_USERNAME${NC}"
    echo -e "${BLUE}================================================================${NC}"
    echo ""

    read -p "Proceed with this configuration? (Y/n): " confirm
    confirm=${confirm:-y}
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_warning "Operation cancelled by user. NO docker-compose was generated!"
        exit 0
    fi
}

# Function to generate TLS certificates and Java keystores
generate_certs() {
    local num_brokers=$1

    echo -e ""
    print_status "Generating TLS certificates and keystores..."

    if ! command -v openssl >/dev/null 2>&1; then
        print_error "openssl is required but not installed"
        exit 1
    fi

    if ! command -v keytool >/dev/null 2>&1; then
        print_error "keytool is required but not installed (install a JDK)"
        exit 1
    fi

    mkdir -p certs secrets

    print_status " 1. Generating Root CA..."
    openssl genrsa -out certs/ca.key.pem 4096 2>/dev/null
    openssl req -x509 -new -nodes -key certs/ca.key.pem -sha256 -days 3650 \
        -out certs/ca.crt.pem -subj "/CN=KafkaClusterRootCA"

    cp certs/ca.crt.pem secrets/ca.crt.pem

    generate_broker_cert() {
        local hostname=$1
        local broker_id=$2

        print_status "    - Generating certificate for ${GREEN}$hostname${NC}"

        openssl genrsa -out "certs/${hostname}.key.pem" 2048 2>/dev/null
        openssl req -new -key "certs/${hostname}.key.pem" \
            -out "certs/${hostname}.csr.pem" -subj "/CN=${hostname}"

        cat > "certs/${hostname}-ext.cnf" <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${hostname}
DNS.2 = localhost
IP.1 = 127.0.0.1
EOF
        append_extra_san_ips "certs/${hostname}-ext.cnf"

        openssl x509 -req -in "certs/${hostname}.csr.pem" \
            -CA certs/ca.crt.pem -CAkey certs/ca.key.pem -CAcreateserial \
            -out "certs/${hostname}.crt.pem" -days 365 -sha256 \
            -extfile "certs/${hostname}-ext.cnf" >/dev/null 2>&1

        openssl pkcs12 -export \
            -in "certs/${hostname}.crt.pem" \
            -inkey "certs/${hostname}.key.pem" \
            -out "secrets/kafka-${broker_id}.p12" \
            -name kafka \
            -password "pass:${KAFKA_SSL_STORE_PASSWORD}" >/dev/null 2>&1

        keytool -importkeystore -noprompt \
            -deststorepass "${KAFKA_SSL_STORE_PASSWORD}" \
            -destkeypass "${KAFKA_SSL_STORE_PASSWORD}" \
            -destkeystore "secrets/kafka-${broker_id}.keystore.jks" \
            -srckeystore "secrets/kafka-${broker_id}.p12" \
            -srcstoretype PKCS12 \
            -srcstorepass "${KAFKA_SSL_STORE_PASSWORD}" \
            -alias kafka >/dev/null 2>&1

        rm -f "certs/${hostname}.csr.pem" "certs/${hostname}-ext.cnf" "secrets/kafka-${broker_id}.p12"
    }

    print_status " 2. Generating broker certificates..."
    for i in $(seq 1 "$num_brokers"); do
        generate_broker_cert "kafka-${i}" "$i"
    done

    print_status " 3. Generating shared truststore..."
    rm -f secrets/kafka.truststore.jks
    keytool -import -trustcacerts -noprompt \
        -alias CARoot \
        -file certs/ca.crt.pem \
        -keystore secrets/kafka.truststore.jks \
        -storepass "${KAFKA_SSL_STORE_PASSWORD}" >/dev/null 2>&1

    print_status " 4. Writing keystore credential files..."
    printf '%s' "${KAFKA_SSL_STORE_PASSWORD}" > secrets/kafka_keystore_creds
    printf '%s' "${KAFKA_SSL_STORE_PASSWORD}" > secrets/kafka_ssl_key_creds
    printf '%s' "${KAFKA_SSL_STORE_PASSWORD}" > secrets/kafka_truststore_creds

    print_status "Finished generating TLS certificates and keystores."
    echo ""
}

# Function to generate SASL JAAS and client property files
generate_security_configs() {
    print_status "Generating SASL and client configuration files..."

    cat > secrets/broker_jaas.conf <<EOF
KafkaServer {
    org.apache.kafka.common.security.plain.PlainLoginModule required
    username="${KAFKA_BROKER_USERNAME}"
    password="${KAFKA_BROKER_PASSWORD}"
    user_${KAFKA_BROKER_USERNAME}="${KAFKA_BROKER_PASSWORD}"
    user_${KAFKA_USERNAME}="${KAFKA_PASSWORD}";
};
EOF

    cat > secrets/client.properties <<EOF
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="${KAFKA_USERNAME}" password="${KAFKA_PASSWORD}";
ssl.truststore.location=/etc/kafka/secrets/kafka.truststore.jks
ssl.truststore.password=${KAFKA_SSL_STORE_PASSWORD}
ssl.endpoint.identification.algorithm=
EOF

    mkdir -p scripts
    cat > scripts/client.properties <<EOF
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="${KAFKA_USERNAME}" password="${KAFKA_PASSWORD}";
ssl.truststore.location=../secrets/kafka.truststore.jks
ssl.truststore.password=${KAFKA_SSL_STORE_PASSWORD}
ssl.endpoint.identification.algorithm=
EOF

    print_status "Finished generating SASL and client configuration files."
    echo ""
}

# Function to generate docker-compose.yml
generate_docker_compose() {
    local num_brokers=$1
    local kafka_port=$2
    local replication_factor=$3

    print_status "Generating docker-compose.yml..."

    cat > docker-compose.yml << EOF
services:
EOF

    # Use a fixed cluster ID for KRaft (consistent across script runs)
    # If you get cluster ID mismatch errors, clear volumes: docker-compose down -v
    local cluster_id="ACB0B0AF073F1C9FE7CEAEA73F5B1029"
    local kafka_ui_jaas="org.apache.kafka.common.security.plain.PlainLoginModule required username=\\\"${KAFKA_USERNAME}\\\" password=\\\"${KAFKA_PASSWORD}\\\";"

    print_status " 1. Adding ${GREEN}Kafka${NC} services (KRaft mode, SASL_SSL)"
    for i in $(seq 1 $num_brokers); do
        cat >> docker-compose.yml << EOF
  kafka-${i}:
    image: apache/kafka:latest
    container_name: kafka-${i}
    hostname: kafka-${i}
    ports:
      - "$((kafka_port + i - 1)):9092"
      - "$((kafka_port + i - 1 + 20000)):29092"
      - "$((kafka_port + i - 1 + 30000)):39092"
    environment:
      CLUSTER_ID: ${cluster_id}
      KAFKA_NODE_ID: ${i}
      KAFKA_PROCESS_ROLES: broker,controller
      KAFKA_CONTROLLER_QUORUM_VOTERS: $(for j in $(seq 1 $num_brokers); do echo -n "${j}@kafka-${j}:39092"; if [ $j -lt $num_brokers ]; then echo -n ","; fi; done)
      KAFKA_LISTENERS: SASL_SSL://:29092,CONTROLLER://:39092,SASL_SSL_HOST://:9092
      KAFKA_ADVERTISED_LISTENERS: SASL_SSL://kafka-${i}:29092,SASL_SSL_HOST://localhost:$((kafka_port + i - 1))
      KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: CONTROLLER:PLAINTEXT,SASL_SSL:SASL_SSL,SASL_SSL_HOST:SASL_SSL
      KAFKA_INTER_BROKER_LISTENER_NAME: SASL_SSL
      KAFKA_CONTROLLER_LISTENER_NAMES: CONTROLLER
      KAFKA_SASL_ENABLED_MECHANISMS: PLAIN
      KAFKA_SASL_MECHANISM_INTER_BROKER_PROTOCOL: PLAIN
      KAFKA_OPTS: -Djava.security.auth.login.config=/etc/kafka/secrets/broker_jaas.conf
      KAFKA_SSL_KEYSTORE_FILENAME: kafka-${i}.keystore.jks
      KAFKA_SSL_KEYSTORE_CREDENTIALS: kafka_keystore_creds
      KAFKA_SSL_KEY_CREDENTIALS: kafka_ssl_key_creds
      KAFKA_SSL_TRUSTSTORE_FILENAME: kafka.truststore.jks
      KAFKA_SSL_TRUSTSTORE_CREDENTIALS: kafka_truststore_creds
      KAFKA_SSL_CLIENT_AUTH: requested
      KAFKA_SSL_ENDPOINT_IDENTIFICATION_ALGORITHM: ""
      KAFKA_AUTO_CREATE_TOPICS_ENABLE: 'true'
      KAFKA_DELETE_TOPIC_ENABLE: 'true'
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: $replication_factor
      KAFKA_TRANSACTION_STATE_LOG_MIN_ISR: 2
      KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR: $replication_factor
      KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS: 0
      KAFKA_LOG_RETENTION_HOURS: 168
      KAFKA_LOG_RETENTION_BYTES: 1073741824
      KAFKA_LOG_SEGMENT_BYTES: 1073741824
      KAFKA_LOG_RETENTION_CHECK_INTERVAL_MS: 300000
      KAFKA_LOG_DIRS: /var/lib/kafka/data
    volumes:
      - kafka-${i}-data:/var/lib/kafka/data
      - ./secrets:/etc/kafka/secrets:ro
    restart: always
    networks:
      - arpeggio-internal
EOF
        echo "" >> docker-compose.yml
    done

    print_status " 2. Adding ${GREEN}Kafka UI${NC} service"
    cat >> docker-compose.yml << EOF
  kafka-ui:
    image: provectuslabs/kafka-ui:latest
    container_name: kafka-ui
    ports:
      - "8080:8080"
    environment:
      KAFKA_CLUSTERS_0_NAME: local
      KAFKA_CLUSTERS_0_BOOTSTRAPSERVERS: $(for i in $(seq 1 $num_brokers); do echo -n "kafka-${i}:29092"; if [ $i -lt $num_brokers ]; then echo -n ","; fi; done)
      KAFKA_CLUSTERS_0_PROPERTIES_SECURITY_PROTOCOL: SASL_SSL
      KAFKA_CLUSTERS_0_PROPERTIES_SASL_MECHANISM: PLAIN
      KAFKA_CLUSTERS_0_PROPERTIES_SASL_JAAS_CONFIG: "${kafka_ui_jaas}"
      KAFKA_CLUSTERS_0_PROPERTIES_SSL_TRUSTSTORE_LOCATION: /etc/kafka/secrets/kafka.truststore.jks
      KAFKA_CLUSTERS_0_PROPERTIES_SSL_TRUSTSTORE_PASSWORD: ${KAFKA_SSL_STORE_PASSWORD}
      KAFKA_CLUSTERS_0_PROPERTIES_SSL_ENDPOINT_IDENTIFICATION_ALGORITHM: ""
    volumes:
      - ./secrets:/etc/kafka/secrets:ro
    restart: always
    depends_on:
EOF
    for i in $(seq 1 $num_brokers); do
        echo "      - kafka-${i}" >> docker-compose.yml
    done
    echo "    networks:" >> docker-compose.yml
    echo "      - arpeggio-internal" >> docker-compose.yml
    echo "" >> docker-compose.yml

    print_status " 3. Adding ${GREEN}volumes${NC} section"
    cat >> docker-compose.yml << EOF
volumes:
EOF
    for i in $(seq 1 $num_brokers); do
        cat >> docker-compose.yml << EOF
  kafka-${i}-data:
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

# Function to generate setup scripts
generate_setup_scripts() {
    local num_brokers=$1
    local replication_factor=$2
    local partitions_per_topic=$3
    local kafka_port=$4

    print_status "Generating setup scripts..."

    print_status " 1. Creating ${GREEN}scripts${NC} directory"
    mkdir -p scripts

    print_status " 2. Creating ${GREEN}wait-for-kafka.sh${NC} script"
    cat > scripts/wait-for-kafka.sh << 'EOF'
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

# Function to check if Kafka broker is ready
check_kafka_broker() {
    local broker=$1
    local port=$2

    echo "Checking if $broker is ready on port $port..."

    # Try to connect to the broker
    timeout 10 bash -c "</dev/tcp/localhost/$port" 2>/dev/null
    if [ $? -eq 0 ]; then
        print_status "$broker is ready!"
        return 0
    else
        print_warning "$broker is not ready yet..."
        return 1
    fi
}

# Wait for all Kafka brokers to be ready
wait_for_kafka_brokers() {
    local num_brokers=$1
    local base_port=$2

    print_status "Waiting for all Kafka brokers to be ready..."

    for i in $(seq 1 $num_brokers); do
        local port=$((base_port + i - 1))
        local broker="kafka-$i"

        while ! check_kafka_broker "$broker" "$port"; do
            sleep 5
        done
    done

    print_status "All Kafka brokers are ready!"
}

# Main execution
if [ $# -ne 2 ]; then
    print_error "Usage: $0 <num_brokers> <base_port>"
    exit 1
fi

NUM_BROKERS=$1
BASE_PORT=$2

wait_for_kafka_brokers "$NUM_BROKERS" "$BASE_PORT"
EOF

    print_status " 3. Creating ${GREEN}create-topics.sh${NC} script"
    cat > scripts/create-topics.sh << EOF
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
REPLICATION_FACTOR=$replication_factor
PARTITIONS_PER_TOPIC=$partitions_per_topic
KAFKA_BROKERS="$(for i in $(seq 1 $num_brokers); do echo -n "kafka-${i}:29092"; if [ $i -lt $num_brokers ]; then echo -n ","; fi; done)"
CLIENT_CONFIG="/etc/kafka/secrets/client.properties"

# Function to create a topic
create_topic() {
    local topic_name=\$1
    local partitions=\$2
    local replication=\$3

    print_status "Creating topic: \$topic_name with \$partitions partitions and replication factor \$replication"

    docker exec kafka-1 kafka-topics --create \
        --bootstrap-server \$KAFKA_BROKERS \
        --command-config \$CLIENT_CONFIG \
        --topic \$topic_name \
        --partitions \$partitions \
        --replication-factor \$replication \
        --if-not-exists

    if [ \$? -eq 0 ]; then
        print_status "Topic \$topic_name created successfully!"
    else
        print_error "Failed to create topic \$topic_name"
    fi
}

# Function to list all topics
list_topics() {
    print_status "Listing all topics:"
    docker exec kafka-1 kafka-topics --list \
        --bootstrap-server \$KAFKA_BROKERS \
        --command-config \$CLIENT_CONFIG
}

# Function to describe a topic
describe_topic() {
    local topic_name=\$1
    print_status "Describing topic: \$topic_name"
    docker exec kafka-1 kafka-topics --describe \
        --bootstrap-server \$KAFKA_BROKERS \
        --command-config \$CLIENT_CONFIG \
        --topic \$topic_name
}

# Main execution
print_status "Starting topic creation script..."

# Wait a bit for Kafka to be fully ready
sleep 10

# Create common topics for microservices
print_status "Creating common topics for microservices..."

# User service topics
create_topic "user-events" \$PARTITIONS_PER_TOPIC \$REPLICATION_FACTOR
create_topic "user-commands" \$PARTITIONS_PER_TOPIC \$REPLICATION_FACTOR
create_topic "user-responses" \$PARTITIONS_PER_TOPIC \$REPLICATION_FACTOR

# Order service topics
create_topic "order-events" \$PARTITIONS_PER_TOPIC \$REPLICATION_FACTOR
create_topic "order-commands" \$PARTITIONS_PER_TOPIC \$REPLICATION_FACTOR
create_topic "order-responses" \$PARTITIONS_PER_TOPIC \$REPLICATION_FACTOR

# Payment service topics
create_topic "payment-events" \$PARTITIONS_PER_TOPIC \$REPLICATION_FACTOR
create_topic "payment-commands" \$PARTITIONS_PER_TOPIC \$REPLICATION_FACTOR
create_topic "payment-responses" \$PARTITIONS_PER_TOPIC \$REPLICATION_FACTOR

# Inventory service topics
create_topic "inventory-events" \$PARTITIONS_PER_TOPIC \$REPLICATION_FACTOR
create_topic "inventory-commands" \$PARTITIONS_PER_TOPIC \$REPLICATION_FACTOR
create_topic "inventory-responses" \$PARTITIONS_PER_TOPIC \$REPLICATION_FACTOR

# Notification service topics
create_topic "notification-events" \$PARTITIONS_PER_TOPIC \$REPLICATION_FACTOR
create_topic "notification-commands" \$PARTITIONS_PER_TOPIC \$REPLICATION_FACTOR

# Audit and logging topics
create_topic "audit-logs" \$PARTITIONS_PER_TOPIC \$REPLICATION_FACTOR
create_topic "system-logs" \$PARTITIONS_PER_TOPIC \$REPLICATION_FACTOR

# Dead letter queue topic
create_topic "dead-letter-queue" \$PARTITIONS_PER_TOPIC \$REPLICATION_FACTOR

print_status "Topic creation completed!"
echo ""
list_topics
echo ""
print_status "You can now use these topics in your microservices."
print_status "Kafka UI is available at: http://localhost:8080"
EOF

    print_status " 4. Creating ${GREEN}health-check.sh${NC} script"
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
KAFKA_BROKERS="$(for i in $(seq 1 $num_brokers); do echo -n "kafka-${i}:29092"; if [ $i -lt $num_brokers ]; then echo -n ","; fi; done)"
CLIENT_CONFIG="/etc/kafka/secrets/client.properties"

# Function to check Kafka broker health
check_kafka_broker() {
    local broker_id=\$1
    local port=\$2

    print_status "Checking Kafka broker \$broker_id on port \$port..."

    # Check if port is listening
    if timeout 5 bash -c "</dev/tcp/localhost/\$port" 2>/dev/null; then
        print_status "✓ Kafka broker \$broker_id is healthy"
        return 0
    else
        print_error "✗ Kafka broker \$broker_id is not responding"
        return 1
    fi
}

# Function to check Kafka cluster metadata
check_kafka_metadata() {
    print_status "Checking Kafka cluster metadata..."

    docker exec kafka-1 kafka-broker-api-versions \
        --bootstrap-server \$KAFKA_BROKERS \
        --command-config \$CLIENT_CONFIG > /dev/null 2>&1

    if [ \$? -eq 0 ]; then
        print_status "✓ Kafka cluster metadata is accessible"
        return 0
    else
        print_error "✗ Kafka cluster metadata is not accessible"
        return 1
    fi
}

# Function to check topic list
check_topics() {
    print_status "Checking available topics..."

    local topic_count=\$(docker exec kafka-1 kafka-topics --list \
        --bootstrap-server \$KAFKA_BROKERS \
        --command-config \$CLIENT_CONFIG 2>/dev/null | wc -l)

    if [ \$topic_count -gt 0 ]; then
        print_status "✓ Found \$topic_count topics"
        return 0
    else
        print_warning "⚠ No topics found (this might be normal for a fresh cluster)"
        return 0
    fi
}

# Main execution
print_status "Starting Kafka cluster health check..."
echo ""

# Check Kafka brokers
print_status "=== Kafka Brokers Health Check ==="
kafka_healthy=true
for i in $(seq 1 $num_brokers); do
    if ! check_kafka_broker "\$i" "\$((kafka_port + i - 1))"; then
        kafka_healthy=false
    fi
done

echo ""

# Check Kafka cluster functionality
print_status "=== Kafka Cluster Functionality Check ==="
if \$kafka_healthy; then
    check_kafka_metadata
    check_topics
else
    print_error "Skipping cluster functionality check due to broker issues"
fi

echo ""

# Summary
print_status "=== Health Check Summary ==="
if \$kafka_healthy; then
    print_status "✓ Kafka cluster is healthy and operational! (KRaft mode, SASL_SSL)"
    print_status "Kafka UI: http://localhost:8080"
    print_status "Kafka brokers (internal): \$KAFKA_BROKERS"
else
    print_error "✗ Kafka cluster has issues that need attention"
    exit 1
fi
EOF

    print_status " 5. Creating ${GREEN}README.md${NC}"
    cat > README.md << EOF
# Kafka Cluster Setup

This directory contains a high-availability Kafka cluster configuration generated by the \`generate-cluster.sh\` script.

## Configuration

- **Kafka Brokers**: $num_brokers
- **Kafka External Port**: $kafka_port
- **Replication Factor**: $replication_factor
- **Partitions per Topic**: $partitions_per_topic
- **Mode**: KRaft (no Zookeeper)
- **Security**: SASL_SSL (TLS encryption + PLAIN username/password)

## Services

### Kafka Brokers
- **kafka-1**: localhost:$kafka_port
- **kafka-2**: localhost:$((kafka_port + 1))
- **kafka-3**: localhost:$((kafka_port + 2))
$(if [ $num_brokers -gt 3 ]; then
    for i in $(seq 4 $num_brokers); do
        echo "- **kafka-$i**: localhost:$((kafka_port + i - 1))"
    done
fi)

### Kafka UI
- **Web Interface**: http://localhost:8080

## Quick Start

1. **Start the cluster**:
   \`\`\`bash
   docker-compose up -d
   \`\`\`

2. **Wait for services to be ready**:
   \`\`\`bash
   ./scripts/wait-for-kafka.sh $num_brokers $kafka_port
   \`\`\`

3. **Create topics** (optional):
   \`\`\`bash
   ./scripts/create-topics.sh
   \`\`\`

4. **Check cluster health**:
   \`\`\`bash
   ./scripts/health-check.sh
   \`\`\`

## Usage

### Connecting to Kafka

**From outside Docker** (use \`scripts/client.properties\` as reference):
\`\`\`
Bootstrap servers: localhost:$kafka_port,localhost:$((kafka_port + 1)),localhost:$((kafka_port + 2))
Security protocol: SASL_SSL
SASL mechanism: PLAIN
Username: (from .env KAFKA_USERNAME)
Password: (from .env KAFKA_PASSWORD)
Truststore: secrets/kafka.truststore.jks
Truststore password: (from .env KAFKA_SSL_STORE_PASSWORD, default: changeit)
\`\`\`

**From inside Docker**:
\`\`\`
Bootstrap servers: kafka-1:29092,kafka-2:29092,kafka-3:29092
Command config: /etc/kafka/secrets/client.properties
\`\`\`

**CA certificate (PEM)** for clients that prefer PEM over JKS:
\`\`\`
secrets/ca.crt.pem
\`\`\`

## Pre-configured Topics

The cluster comes with pre-configured topics for common microservices:

### User Service
- \`user-events\`
- \`user-commands\`
- \`user-responses\`

### Order Service
- \`order-events\`
- \`order-commands\`
- \`order-responses\`

### Payment Service
- \`payment-events\`
- \`payment-commands\`
- \`payment-responses\`

### Inventory Service
- \`inventory-events\`
- \`inventory-commands\`
- \`inventory-responses\`

### Notification Service
- \`notification-events\`
- \`notification-commands\`

### System Topics
- \`audit-logs\`
- \`system-logs\`
- \`dead-letter-queue\`

## Management

### View Logs
\`\`\`bash
# All services
docker-compose logs -f

# Specific service
docker-compose logs -f kafka-1
\`\`\`

### Stop the cluster
\`\`\`bash
docker-compose down
\`\`\`

### Stop and remove volumes
\`\`\`bash
docker-compose down -v
\`\`\`

**Note**: If you get cluster ID mismatch errors, you need to clear the volumes to reset the cluster:
\`\`\`bash
docker-compose down -v
docker-compose up -d
\`\`\`

## Troubleshooting

### Check service status
\`\`\`bash
docker-compose ps
\`\`\`

### Restart a specific service
\`\`\`bash
docker-compose restart kafka-1
\`\`\`

### Access Kafka console producer
\`\`\`bash
docker exec -it kafka-1 kafka-console-producer \\
  --bootstrap-server kafka-1:29092 \\
  --command-config /etc/kafka/secrets/client.properties \\
  --topic test-topic
\`\`\`

### Monitor cluster health
\`\`\`bash
./scripts/health-check.sh
\`\`\`

## High Availability Features

- **Multiple Kafka brokers** for redundancy
- **KRaft mode** for metadata management (no Zookeeper required)
- **Replicated topics** across multiple brokers
- **Automatic failover** when brokers go down
- **Load balancing** across available brokers

## Security

This cluster uses **SASL_SSL**:
- **TLS encryption** for all client and inter-broker traffic (controller channel uses PLAINTEXT on the internal Docker network)
- **SASL/PLAIN** username/password authentication
- **Per-broker TLS certificates** signed by a local CA
- **Client credentials** configured in \`.env\` (\`KAFKA_USERNAME\`, \`KAFKA_PASSWORD\`)
- **Inter-broker credentials** in \`.env\` (\`KAFKA_BROKER_USERNAME\`, \`KAFKA_BROKER_PASSWORD\`)

Generated secrets live in \`secrets/\` and \`certs/\`. Do not commit these to version control in production.

**For production use, also consider**:
- Replacing self-signed certificates with CA-signed certificates
- Using SCRAM-SHA-512 instead of PLAIN
- Implementing ACLs (Access Control Lists)
- Rotating credentials and certificates regularly
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
    echo -e "${BLUE}                xCloud Kafka Cluster Generator${NC}"
    echo -e "${BLUE}================================================================${NC}"
    echo -e "This script will generate a dynamic Kafka cluster configuration."
    echo -e "The cluster will have:"
    echo -e "- ${GREEN}N${NC} Kafka Brokers (for high availability)"
    echo -e "- ${GREEN}KRaft mode${NC} (no Zookeeper required)"
    echo -e "- ${GREEN}SASL_SSL${NC} security (TLS + username/password)"
    echo -e "- ${GREEN}1${NC} Kafka UI (for management)"
    echo -e "- ${GREEN}Pre-configured topics${NC} for microservices"
    echo -e "${BLUE}================================================================${NC}"

    get_user_input
    NUM_BROKERS=$num_brokers
    KAFKA_PORT=$kafka_port
    REPLICATION_FACTOR=$replication_factor
    PARTITIONS_PER_TOPIC=$partitions_per_topic

    generate_certs "$NUM_BROKERS"
    generate_security_configs
    generate_docker_compose "$NUM_BROKERS" "$KAFKA_PORT" "$REPLICATION_FACTOR"
    generate_setup_scripts "$NUM_BROKERS" "$REPLICATION_FACTOR" "$PARTITIONS_PER_TOPIC" "$KAFKA_PORT"

    echo -e "${GREEN}================================================================${NC}"
    echo -e "${GREEN}               Generation completed successfully!${NC}"
    echo -e "${GREEN}================================================================${NC}"

    print_status "Generation completed successfully!"
    print_status "Files created:"
    print_status "- docker-compose.yml"
    print_status "- secrets/ (TLS keystores, JAAS config, client.properties)"
    print_status "- certs/ (CA and broker PEM certificates)"
    print_status "- scripts/wait-for-kafka.sh"
    print_status "- scripts/create-topics.sh"
    print_status "- scripts/health-check.sh"
    print_status "- scripts/client.properties"
    print_status "- README.md"
    echo ""
    print_status "Kafka cluster configured with ${GREEN}SASL_SSL${NC} (TLS + username/password)"
    print_status "Client username: ${GREEN}${KAFKA_USERNAME}${NC}"
    echo ""
    print_status "To start the cluster, run: docker-compose up -d"
    print_status "To wait for services to be ready: ./scripts/wait-for-kafka.sh $NUM_BROKERS $KAFKA_PORT"
    print_status "To create topics: ./scripts/create-topics.sh"
    print_status "To check health: ./scripts/health-check.sh"
    print_status "Kafka UI will be available at: http://localhost:8080"
    echo ""
    print_status "Thank you for using xCloud Kafka Cluster Generator"
    echo ""
    echo -e "${GREEN}================================================================${NC}"
    echo -e ""
}

# Run main function
main "$@"
