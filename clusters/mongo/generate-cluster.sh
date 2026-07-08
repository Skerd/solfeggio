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
    print_error ".env file not found. Please create .env file with APP_USERNAME, APP_PASSWORD, and COLLECTION_NAME"
    exit 1
fi

# Validate required environment variables
if [ -z "$APP_USERNAME" ] || [ -z "$APP_PASSWORD" ] || [ -z "$COLLECTION_NAME" ]; then
    print_error "Missing required environment variables in .env file: APP_USERNAME, APP_PASSWORD, COLLECTION_NAME"
    exit 1
fi

DOCKER_INTERNAL_NETWORK="${DOCKER_INTERNAL_NETWORK:-arpeggio_internal_network}"
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
    echo -e "Ready to configure the cluster, please provide the needed information:"
    echo -e ""

    while true; do
        read -p "Enter number of shards (1-10) [default: 3]: " num_shards
        num_shards=${num_shards:-3}
        if validate_number "$num_shards" 1 10; then
            break
        fi
    done

    while true; do
        read -p "Enter MongoDB Router port (0-65535) [default: 27117]: " router_port
        router_port=${router_port:-27117}
        echo "$router_port"
        if validate_number "$router_port" 0 65535; then
            break
        fi
    done

    echo -e ""
    print_status "Configuration Summary:"
    print_status "- Number of shards: ${GREEN}$num_shards${NC}"
    print_status "- Router port: ${GREEN}$router_port${NC}"
    print_status "- Config servers: ${GREEN}3${NC} (fixed)"
    print_status "- Nodes per shard: ${GREEN}3${NC} (PSS structure)"
    echo -e "${BLUE}================================================================${NC}"
    echo ""

    read -p "Proceed with this configuration? (Y/n): " confirm
    confirm=${confirm:-y}
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_warning "Operation cancelled by user. NO docker-compose was generated!"
        exit 0
    fi
}

# Function to generate TLS Certificates
generate_certs() {
    local num_shards=$1
    echo $num_shards

    echo -e ""
    print_status "Generating TLS Certificates..."

    mkdir -p certs

    print_status " 1. Generating Root CA..."
    openssl genrsa -out certs/ca.key.pem 4096
    openssl req -x509 -new -nodes -key certs/ca.key.pem -sha256 -days 3650 -out certs/ca.crt.pem -subj "/CN=MongoClusterRootCA"

    generate_server_cert() {
        local hostname=$1
        local padding=$2
        print_status "    ${padding}- Generating certificates for ${GREEN}$hostname${NC}"

        openssl genrsa -out certs/${hostname}.key.pem 2048
        openssl req -new -key certs/${hostname}.key.pem -out certs/${hostname}.csr.pem -subj "/CN=${hostname}"

        cat > certs/${hostname}-ext.cnf <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${hostname}
DNS.2 = localhost
IP.1 = 127.0.0.1
EOF

        openssl x509 -req -in certs/${hostname}.csr.pem -CA certs/ca.crt.pem -CAkey certs/ca.key.pem -CAcreateserial -out certs/${hostname}.crt.pem -days 365 -sha256 -extfile certs/${hostname}-ext.cnf > /dev/null 2>&1

        # Combine key and cert into .pem file
        cat certs/${hostname}.crt.pem certs/${hostname}.key.pem > certs/${hostname}.pem
        # Cleanup intermediate files
        rm certs/${hostname}.csr.pem certs/${hostname}-ext.cnf certs/${hostname}.crt.pem certs/${hostname}.key.pem
    }

    print_status " 2. Generating Server Certificates..."

    print_status "  2.1 Generating certificates for ${GREEN}router${NC}"
    generate_server_cert "router-01"

    print_status "  2.2 Generating certificates for ${GREEN}config servers${NC}"
    for i in {1..3}; do
        generate_server_cert "mongo-config-0${i}"
    done

    print_status "  2.3 Generating certificates for ${GREEN}${num_shards} shards${NC}"
    for shard in $(seq 1 $num_shards); do
        shard_padded=$(printf "%02d" $shard)
        print_status "   2.3.${shard} Generating certificates for ${GREEN}shard ${shard}${NC}"
        for node in a b c; do
            generate_server_cert "shard-${shard_padded}-node-${node}" "   "
        done
    done

    print_status "Finished generating TLS Certificates."
    echo ""
}


# Function to generate docker-compose.yml
generate_docker_compose() {
    local num_shards=$1
    local base_port=$2

    print_status "Generating docker-compose.yml..."
    print_status " 1. Adding ${GREEN}router${NC} service"

    cat > docker-compose.yml << EOF
services:
  ## Router
  router01:
    image: mongo:latest
    container_name: router-01
    ports:
      - "${base_port}:27017"
    restart: always
    env_file:
      - .env
    environment:
      - APP_USERNAME=${APP_USERNAME}
      - APP_PASSWORD=${APP_PASSWORD}
      - COLLECTION_NAME=${COLLECTION_NAME}
    volumes:
      - ./scripts:/scripts
      - ./certs:/certs
      - mongodb_cluster_router01_db:/data/db
      - mongodb_cluster_router01_config:/data/configdb
    entrypoint: ["/scripts/entrypoint-route.sh"]
    networks:
      - arpeggio-internal

EOF

    print_status " 2. Adding ${GREEN}3 config server${NC} services"

    for i in {1..3}; do
        cat >> docker-compose.yml << EOF
  ## Config Servers
  configsvr0${i}:
    image: mongo:latest
    container_name: mongo-config-0${i}
    volumes:
      - ./scripts:/scripts
      - ./certs:/certs
      - mongodb_cluster_configsvr0${i}_db:/data/db
      - mongodb_cluster_configsvr0${i}_config:/data/configdb
    restart: always
EOF
        if [ "$i" -eq 1 ]; then
            echo "    entrypoint: [\"/scripts/entrypoint-configserver.sh\"]" >> docker-compose.yml
        else
            echo "    command: mongod --port 27017 --configsvr --replSet rs-config-server --tlsMode requireTLS --tlsCertificateKeyFile /certs/mongo-config-0${i}.pem --tlsCAFile /certs/ca.crt.pem" >> docker-compose.yml
        fi
        echo "    networks:" >> docker-compose.yml
        echo "      - arpeggio-internal" >> docker-compose.yml
        echo "" >> docker-compose.yml
    done

    print_status " 3. Adding ${GREEN}shard${NC} services"
    # Generate Shards
    for shard in $(seq 1 $num_shards); do
        print_status "  3.${shard} Adding ${GREEN}shard${NC} ${BLUE}${shard}${NC}"
        shard_padded=$(printf "%02d" $shard)
        for node in a b c; do
            cat >> docker-compose.yml << EOF
  ## Shards
  shard${shard_padded}-${node}:
    image: mongo:latest
    container_name: shard-${shard_padded}-node-${node}
    volumes:
      - ./scripts:/scripts
      - ./certs:/certs
      - mongodb_cluster_shard${shard_padded}_${node}_db:/data/db
      - mongodb_cluster_shard${shard_padded}_${node}_config:/data/configdb
    restart: always
EOF
            if [ "$node" = "a" ]; then
                echo "    entrypoint: [\"/bin/sh\", \"/scripts/entrypoint-shard${shard_padded}.sh\"]" >> docker-compose.yml
            else
                echo "    command: mongod --port 27017 --shardsvr --replSet rs-shard-${shard_padded} --tlsMode requireTLS --tlsCertificateKeyFile /certs/shard-${shard_padded}-node-${node}.pem --tlsCAFile /certs/ca.crt.pem" >> docker-compose.yml
            fi
            echo "    networks:" >> docker-compose.yml
            echo "      - arpeggio-internal" >> docker-compose.yml
            echo "" >> docker-compose.yml
        done
    done

    print_status " 4. Adding ${GREEN}volumes${NC} section"

    print_status "  4.1 Adding ${GREEN}router${NC} volumes"

    cat >> docker-compose.yml << EOF
volumes:
  mongodb_cluster_router01_db:
  mongodb_cluster_router01_config:
EOF

    print_status "  4.1 Adding ${GREEN}config servers${NC} volumes"
    for i in {1..3}; do
        cat >> docker-compose.yml << EOF
  mongodb_cluster_configsvr0${i}_db:
  mongodb_cluster_configsvr0${i}_config:
EOF
    done

    print_status "  4.1 Adding ${GREEN}shards${NC} volumes"
    for shard in $(seq 1 $num_shards); do
        shard_padded=$(printf "%02d" $shard)
        for node in a b c; do
            cat >> docker-compose.yml << EOF
  mongodb_cluster_shard${shard_padded}_${node}_db:
  mongodb_cluster_shard${shard_padded}_${node}_config:
EOF
        done
    done

    print_status " 5. Adding ${GREEN}networks${NC} section"
    cat >> docker-compose.yml << EOF

networks:
  arpeggio-internal:
    external: true
    name: ${DOCKER_INTERNAL_NETWORK}
EOF

    print_status "Finished generating docker-compose.yml"
    echo -e ""
}

# Function to generate dynamic entrypoint scripts
generate_entrypoint_scripts() {
    local num_shards=$1

    print_status "Generating entrypoint scripts..."

    print_status " 1. Creating ${GREEN}scripts${NC} directory"
    mkdir -p scripts

    print_status " 2. Creating ${GREEN}config server${NC} entrypoint"
    cat > scripts/entrypoint-configserver.sh << 'EOF'
#!/bin/bash
set -e

# Start MongoDB in the background
mongod --configsvr --replSet rs-config-server --port 27017 --bind_ip_all --tlsMode requireTLS --tlsCertificateKeyFile /certs/mongo-config-01.pem --tlsCAFile /certs/ca.crt.pem &

# Store the PID of MongoDB
MONGO_PID=$!

# Give MongoDB some time to start initially
sleep 5

# Function to check if MongoDB is ready locally
check_mongo_ready() {
  host=$1
  mongosh --host $host --tls --tlsCAFile /certs/ca.crt.pem --tlsCertificateKeyFile /certs/mongo-config-01.pem --eval "db.adminCommand('ping')" --quiet
  return $?
}

# Wait for all config servers to be ready
wait_for_mongo() {
  echo "Waiting for MongoDB instances to start..."
  
  # First wait for local instance
  until check_mongo_ready 127.0.0.1; do
    echo "Waiting for local MongoDB to start..."
    # Check if MongoDB process is still running
    if ! kill -0 $MONGO_PID 2>/dev/null; then
      echo "MongoDB process died unexpectedly. Check logs for errors."
      exit 1
    fi
    sleep 2
  done
  echo "Local MongoDB is ready!"
  
  # Then wait for other instances with timeout
  for host in mongo-config-02 mongo-config-03; do
    attempt=0
    max_attempts=30
    until check_mongo_ready $host || [ $attempt -ge $max_attempts ]; do
      echo "Waiting for $host to be ready... (attempt $attempt/$max_attempts)"
      attempt=$((attempt+1))
      sleep 2
    done
    
    if [ $attempt -ge $max_attempts ]; then
      echo "Timed out waiting for $host. Continuing anyway..."
    else
      echo "$host is ready!"
    fi
  done
  
  echo "All MongoDB instances are ready or timed out!"
}

# Initialize replica set
init_config_server() {
  echo "Initializing config server replica set..."

  # Adding more diagnostic output
  echo "Current MongoDB status:"
  mongosh --tls --tlsCAFile /certs/ca.crt.pem --tlsCertificateKeyFile /certs/mongo-config-01.pem --eval "db.adminCommand('ping')" || echo "Failed to ping MongoDB"
  
  # Try to initialize replica set
  mongosh --tls --tlsCAFile /certs/ca.crt.pem --tlsCertificateKeyFile /certs/mongo-config-01.pem --eval "
    rs.initiate({
      _id: \"rs-config-server\", 
      configsvr: true, 
      version: 1, 
      members: [ 
        { _id: 0, host : 'mongo-config-01:27017' }, 
        { _id: 1, host : 'mongo-config-02:27017' }, 
        { _id: 2, host : 'mongo-config-03:27017' } 
      ] 
    })
  " || echo "Failed to initialize replica set"
  
  echo "Config server replica set initialization attempted."
}

# Main execution
echo "Starting MongoDB config server entrypoint script..."
wait_for_mongo
init_config_server

# Keep the script running to maintain the container
echo "Initialization completed, keeping container running with MongoDB process..."
wait $MONGO_PID
EOF

    print_status " 3. Creating ${GREEN}shards${NC} entrypoint"
    for shard in $(seq 1 $num_shards); do
      print_status "  3.${shard} Creating ${GREEN}shard ${BLUE}${shard}${NC} entrypoint"
        shard_padded=$(printf "%02d" $shard)
        shard_name="shard${shard_padded}"
        
        cat > "scripts/entrypoint-${shard_name}.sh" << EOF
#!/bin/bash
set -e

# Start MongoDB in the background
mongod --shardsvr --replSet rs-shard-${shard_padded} --port 27017 --bind_ip_all --tlsMode requireTLS --tlsCertificateKeyFile /certs/shard-${shard_padded}-node-a.pem --tlsCAFile /certs/ca.crt.pem &

# Store the PID of MongoDB
MONGO_PID=\$!

# Give MongoDB some time to start initially
sleep 5

# Function to check if MongoDB is ready locally
check_mongo_ready() {
  host=\$1
  mongosh --host \$host --tls --tlsCAFile /certs/ca.crt.pem --tlsCertificateKeyFile /certs/shard-${shard_padded}-node-a.pem --eval "db.adminCommand('ping')" --quiet
  return \$?
}

# Wait for all shard servers to be ready
wait_for_mongo() {
  echo "Waiting for MongoDB instances to start..."
  
  # First wait for local instance
  until check_mongo_ready 127.0.0.1; do
    echo "Waiting for local MongoDB to start..."
    # Check if MongoDB process is still running
    if ! kill -0 \$MONGO_PID 2>/dev/null; then
      echo "MongoDB process died unexpectedly. Check logs for errors."
      exit 1
    fi
    sleep 2
  done
  echo "Local MongoDB is ready!"
  
  # Then wait for other instances with timeout
  for host in shard-${shard_padded}-node-b shard-${shard_padded}-node-c; do
    attempt=0
    max_attempts=30
    until check_mongo_ready \$host || [ \$attempt -ge \$max_attempts ]; do
      echo "Waiting for \$host to be ready... (attempt \$attempt/\$max_attempts)"
      attempt=\$((attempt+1))
      sleep 2
    done
    
    if [ \$attempt -ge \$max_attempts ]; then
      echo "Timed out waiting for \$host. Continuing anyway..."
    else
      echo "\$host is ready!"
    fi
  done
  
  echo "All MongoDB instances are ready or timed out!"
}

# Initialize replica set
init_shard() {
  echo "Initializing shard replica set..."
    
  # Adding more diagnostic output
  echo "Current MongoDB status:"
  mongosh --tls --tlsCAFile /certs/ca.crt.pem --tlsCertificateKeyFile /certs/shard-${shard_padded}-node-a.pem --eval "db.adminCommand('ping')" || echo "Failed to ping MongoDB"
  
  # Try to initialize replica set
  mongosh --tls --tlsCAFile /certs/ca.crt.pem --tlsCertificateKeyFile /certs/shard-${shard_padded}-node-a.pem --eval "
    rs.initiate({
      _id: \"rs-shard-${shard_padded}\", 
      version: 1, 
      members: [ 
        { _id: 0, host : \"shard-${shard_padded}-node-a:27017\" }, 
        { _id: 1, host : \"shard-${shard_padded}-node-b:27017\" }, 
        { _id: 2, host : \"shard-${shard_padded}-node-c:27017\" } 
      ] 
    })
  " || echo "Failed to initialize replica set"

  echo "Shard replica set initialization attempted."
}

# Main execution
echo "Starting MongoDB Shard entrypoint script..."
wait_for_mongo
init_shard

# Keep the script running to maintain the container
echo "Initialization completed, keeping container running with MongoDB process..."
wait \$MONGO_PID
EOF
    done

    print_status " 4. Creating ${GREEN}router${NC} entrypoint"
    cat > scripts/entrypoint-route.sh << 'ROUTER_EOF'
#!/bin/bash

# Wait for the config server replica set to elect a primary
echo "Waiting for config server replica set to elect a primary..."
until mongosh "mongodb://mongo-config-01:27017,mongo-config-02:27017,mongo-config-03:27017/?tls=true&tlsCAFile=/certs/ca.crt.pem&tlsCertificateKeyFile=/certs/router-01.pem" \
  --eval 'rs.status().members.some(m => m.stateStr === "PRIMARY")' --quiet | grep -q 'true'; do
  echo "Config Server PRIMARY not ready yet. Retrying in 5 seconds..."
  sleep 5
done
echo "Config Server PRIMARY is ready!"

# Wait for each shard's replica set to elect a primary
ROUTER_EOF

    for shard in $(seq 1 $num_shards); do
        shard_padded=$(printf "%02d" $shard)
        shard_name="shard${shard_padded}"
        cat >> scripts/entrypoint-route.sh << EOF
replica_set="rs-shard-${shard_padded}"
host_prefix="${shard_name}"
echo "Waiting for \${replica_set} to elect a primary..."
until mongosh "mongodb://shard-${shard_padded}-node-a:27017,shard-${shard_padded}-node-b:27017,shard-${shard_padded}-node-c:27017/?tls=true&tlsCAFile=/certs/ca.crt.pem&tlsCertificateKeyFile=/certs/router-01.pem" \
  --eval 'rs.status().members.some(m => m.stateStr === "PRIMARY")' --quiet | grep -q 'true'; do
  echo "\${replica_set} PRIMARY not ready yet. Retrying in 5 seconds..."
  sleep 5
done
echo "\${replica_set} PRIMARY is ready!"
EOF
    done

    cat >> scripts/entrypoint-route.sh << 'ROUTER_END_EOF'

# Start mongos in the background
echo "Starting mongos..."
mongos --port 27017 --configdb rs-config-server/mongo-config-01:27017,mongo-config-02:27017,mongo-config-03:27017 --bind_ip_all --tlsMode requireTLS --tlsCertificateKeyFile /certs/router-01.pem --tlsCAFile /certs/ca.crt.pem &

# Wait for mongos to become available
echo "Waiting for mongos to start..."
until mongosh "mongodb://localhost:27017/?tls=true&tlsCAFile=/certs/ca.crt.pem&tlsCertificateKeyFile=/certs/router-01.pem" --eval 'db.adminCommand({ping: 1})' --quiet &> /dev/null; do
  echo "mongos not available yet. Retrying in 5 seconds..."
  sleep 5
done
echo "mongos is up and running!"

# Add the shards using the provided commands
echo "Adding shards..."
mongosh "mongodb://localhost:27017/?tls=true&tlsCAFile=/certs/ca.crt.pem&tlsCertificateKeyFile=/certs/router-01.pem" << 'SHARD_ADD_EOF'
ROUTER_END_EOF

    for shard in $(seq 1 $num_shards); do
        shard_padded=$(printf "%02d" $shard)
        shard_name="shard${shard_padded}"
        cat >> scripts/entrypoint-route.sh << EOF
sh.addShard("rs-shard-${shard_padded}/shard-${shard_padded}-node-a:27017,shard-${shard_padded}-node-b:27017,shard-${shard_padded}-node-c:27017")
EOF
    done

    cat >> scripts/entrypoint-route.sh << EOF
SHARD_ADD_EOF

# Create user and database
echo "Creating application user and database..."
if [ -n "\$APP_USERNAME" ] && [ -n "\$APP_PASSWORD" ] && [ -n "\$COLLECTION_NAME" ]; then
  # Use COLLECTION_NAME as the database name
  DB_NAME="\$COLLECTION_NAME"
  
  echo "Creating database: \$DB_NAME"
  echo "Creating user: \$APP_USERNAME"
  
  mongosh "mongodb://localhost:27017/?tls=true&tlsCAFile=/certs/ca.crt.pem&tlsCertificateKeyFile=/certs/router-01.pem" << USER_CREATE_EOF
use \$DB_NAME

// Create the user with readWrite permissions on the database
try {
  db.createUser({
    user: "\$APP_USERNAME",
    pwd: "\$APP_PASSWORD",
    roles: [
      { role: "readWrite", db: "\$DB_NAME" }
    ]
  })
  print("User \$APP_USERNAME created successfully")
} catch(e) {
  if (e.code === 51003) {
    print("User \$APP_USERNAME already exists, skipping creation")
  } else {
    print("Error creating user: " + e)
  }
}

// Enable sharding on the database
try {
  sh.enableSharding("\$DB_NAME")
  print("Sharding enabled on database \$DB_NAME")
} catch(e) {
  print("Error enabling sharding (may already be enabled): " + e)
}
USER_CREATE_EOF
else
  echo "Environment variables not set, skipping user and database creation"
fi

# Keep the mongos process running in the foreground
wait
EOF

    print_status " 5. Making ${GREEN}scripts${NC} executable"
    chmod +x scripts/*.sh

    print_status "Finished generating entrypoint scripts"
    echo -e ""
}

# Main execution
main() {

    echo -e ""
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${BLUE}                xCloud MongoDB Cluster Generator${NC}"
    echo -e "${BLUE}================================================================${NC}"
    echo -e "This script will generate a dynamic MongoDB cluster configuration."
    echo -e "Each MongoDB shard will use the PSS (primary-secondary-secondary) structure"
    echo -e "The cluster will have:"
    echo -e "- ${GREEN}1${NC} Router (mongos)"
    echo -e "- ${GREEN}3${NC} Config Servers (fixed)"
    echo -e "- ${GREEN}N${NC} Shards (each with ${GREEN}3${NC} nodes - PSS structure)"
    echo -e "${BLUE}================================================================${NC}"

    get_user_input
    NUM_SHARDS=$num_shards
    BASE_PORT=$router_port

    echo $NUM_SHARDS
    echo $BASE_PORT

    generate_certs "$NUM_SHARDS"
    generate_docker_compose "$NUM_SHARDS" "$BASE_PORT"
    generate_entrypoint_scripts "$NUM_SHARDS"

    echo -e "${GREEN}================================================================${NC}"
    echo -e "${GREEN}               Generation completed successfully!${NC}"
    echo -e "${GREEN}================================================================${NC}"

    print_status "Generation completed successfully!"
    print_status "Files created:"
    print_status "- docker-compose.yml"
    print_status "- scripts/entrypoint-configserver.sh"
    print_status "- scripts/entrypoint-route.sh"
    for shard in $(seq 1 $num_shards); do
      shard_padded=$(printf "%02d" $shard)
      print_status "- scripts/entrypoint-shard${shard_padded}.sh"
    done
    print_status "- certs/ca.crt.pem"
    print_status "- certs/ca.crt.srl"
    print_status "- certs/ca.key.pem"
    print_status "- certs/mongo-config-01.pem"
    print_status "- certs/mongo-config-02.pem"
    print_status "- certs/mongo-config-03.pem"
    print_status "- certs/router-01.pem"
    for shard in $(seq 1 $num_shards); do
      shard_padded=$(printf "%02d" $shard)
      for node in a b c; do
        print_status "- certs/shard-${shard_padded}-node-${node}.pem"
      done
    done
    echo ""
    print_status "To start the cluster, run: docker-compose up -d"
    print_status "Thank you for using xCloud MongoDB Cluster Generator"
    echo ""
    echo -e "${GREEN}================================================================${NC}"
    echo -e ""

}

# Run main function
main "$@" 