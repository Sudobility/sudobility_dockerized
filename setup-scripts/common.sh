#!/bin/bash
# common.sh - Shared utility functions for service management
# Compatible with bash 3.2+ (macOS) and bash 4+ (Linux)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Print functions
print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }
print_warning() { echo -e "${YELLOW}!${NC} $1"; }
print_info() { echo -e "${BLUE}→${NC} $1"; }

print_header() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo ""
}

# Check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Get the docker compose command (v2 or v1)
get_docker_compose_cmd() {
    if docker compose version >/dev/null 2>&1; then
        echo "docker compose"
    else
        echo "docker-compose"
    fi
}

# Configuration directories
CONFIG_DIR="config-generated"
SERVICES_DIR="${CONFIG_DIR}/services"
TRAEFIK_DIR="${CONFIG_DIR}/traefik"
TOKENS_DIR="${CONFIG_DIR}/.doppler-tokens"

# Ensure directories exist
ensure_dirs() {
    mkdir -p "$SERVICES_DIR"
    mkdir -p "$TRAEFIK_DIR"
    mkdir -p "$TOKENS_DIR"
    chmod 700 "$TOKENS_DIR"
}

# Secure file permissions
secure_file() {
    local file="$1"
    if [ -f "$file" ]; then
        chmod 600 "$file"
    fi
}

# Prompt for yes/no with default
prompt_yes_no() {
    local prompt="$1"
    local default="${2:-y}"

    if [ "$default" = "y" ]; then
        prompt="$prompt [Y/n]: "
    else
        prompt="$prompt [y/N]: "
    fi

    read -p "$prompt" response
    response="${response:-$default}"

    case "$response" in
        [yY][eE][sS]|[yY]) return 0 ;;
        *) return 1 ;;
    esac
}

# =============================================================================
# Traefik Management
# =============================================================================

# Ensure the shared Docker bridge network exists.
# All services and Traefik communicate over "sudobility_network".
# This function is idempotent: it creates the network only if missing.
# The network is also defined in Traefik's docker-compose.yml, but we
# pre-create it here so services can be started in any order.
ensure_network() {
    if ! docker network ls --format '{{.Name}}' 2>/dev/null | grep -q "^sudobility_network$"; then
        docker network create sudobility_network >/dev/null 2>&1 || true
    fi
}

# Check if Traefik is installed and running
is_traefik_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^traefik$"
}

# Install Traefik if not present
install_traefik() {
    if is_traefik_running; then
        print_success "Traefik is already running"
        return 0
    fi

    print_info "Installing Traefik..."

    ensure_dirs
    ensure_network

    # Create Traefik docker-compose.yml
    # This template configures Traefik as the single entry point for all services.
    # Traefik listens on ports 80 (HTTP) and 443 (HTTPS), automatically discovers
    # backend services via Docker labels, and provisions SSL certificates from
    # Let's Encrypt using the HTTP-01 ACME challenge.
    cat > "${TRAEFIK_DIR}/docker-compose.yml" << 'EOF'
# Traefik - Reverse Proxy & SSL Termination
# ==========================================================================
# This is the central reverse proxy for all services managed by sudobility.
# It handles:
#   1. SSL termination with auto-provisioned Let's Encrypt certificates
#   2. Host-based routing to backend containers (via Docker labels)
#   3. HTTP-to-HTTPS redirection for all traffic
#
# Services register themselves by adding Traefik Docker labels (see add.sh).
# Traefik discovers them automatically via the Docker socket.
# ==========================================================================
services:
  traefik:
    image: traefik:latest
    container_name: traefik
    restart: unless-stopped
    command:
      # --- API / Dashboard ---
      - "--api.dashboard=false"           # Dashboard disabled for security
      - "--api.insecure=false"            # No insecure API endpoint

      # --- Docker Provider ---
      # Traefik watches the Docker socket for container start/stop events.
      # Only containers with "traefik.enable=true" label are exposed.
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--providers.docker.network=sudobility_network"

      # --- Entrypoints ---
      # "web" listens on port 80 (HTTP) and redirects all traffic to "websecure".
      # "websecure" listens on port 443 (HTTPS) and terminates TLS.
      - "--entrypoints.web.address=:80"
      - "--entrypoints.websecure.address=:443"
      - "--entrypoints.web.http.redirections.entrypoint.to=websecure"
      - "--entrypoints.web.http.redirections.entrypoint.scheme=https"

      # --- Let's Encrypt (ACME) ---
      # Uses HTTP-01 challenge: Let's Encrypt sends a request to port 80,
      # Traefik responds with a token to prove domain ownership.
      # Requirements:
      #   - Port 80 must be accessible from the internet
      #   - DNS must point to this server BEFORE requesting a certificate
      # Certificates are stored in a Docker volume to survive restarts.
      - "--certificatesresolvers.letsencrypt.acme.httpchallenge=true"
      - "--certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=web"
      - "--certificatesresolvers.letsencrypt.acme.email=admin@sudobility.com"
      - "--certificatesresolvers.letsencrypt.acme.storage=/data/acme.json"

      - "--log.level=INFO"
    ports:
      - "80:80"     # HTTP  - used for ACME challenges + redirect to HTTPS
      - "443:443"   # HTTPS - all service traffic terminates here
    volumes:
      # Docker socket (read-only) lets Traefik discover running containers
      - /var/run/docker.sock:/var/run/docker.sock:ro
      # Named volume persists ACME certificates across container restarts
      - traefik_data:/data
    networks:
      - sudobility_network
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

# Persistent volume for ACME certificate storage
volumes:
  traefik_data:
    name: sudobility_traefik_data

# Shared network: all services and Traefik must be on this network
# so Traefik can forward traffic to service containers.
# Created as a bridge network by the first "docker compose up" (Traefik).
# Other services reference it as "external: true" in their own compose files.
networks:
  sudobility_network:
    name: sudobility_network
    driver: bridge
EOF

    # Start Traefik
    local DOCKER_COMPOSE
    DOCKER_COMPOSE=$(get_docker_compose_cmd)

    cd "$TRAEFIK_DIR"
    $DOCKER_COMPOSE up -d
    cd - > /dev/null

    if is_traefik_running; then
        print_success "Traefik installed and running"
        return 0
    else
        print_error "Failed to start Traefik"
        return 1
    fi
}

# =============================================================================
# Service Management
# =============================================================================

# Get list of managed services (directory names in services/)
# Uses while loop instead of mapfile for bash 3.x compatibility (macOS)
get_managed_services() {
    if [ -d "$SERVICES_DIR" ]; then
        find "$SERVICES_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort
    fi
}

# Read services into array (bash 3.x compatible)
# Usage: read_services_array
# Sets SERVICES array
read_services_array() {
    SERVICES=()
    while IFS= read -r line; do
        [ -n "$line" ] && SERVICES+=("$line")
    done < <(get_managed_services)
}

# Check if a service exists
service_exists() {
    local service_name="$1"
    [ -d "${SERVICES_DIR}/${service_name}" ]
}

# Get service config value
get_service_config() {
    local service_name="$1"
    local key="$2"
    local config_file="${SERVICES_DIR}/${service_name}/.service.conf"

    if [ -f "$config_file" ]; then
        grep "^${key}=" "$config_file" 2>/dev/null | cut -d'=' -f2-
    fi
}

# Get container status info
get_container_status() {
    local container_name="$1"

    if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${container_name}$"; then
        echo "not found"
        return
    fi

    local status
    status=$(docker inspect --format='{{.State.Status}}' "$container_name" 2>/dev/null)
    echo "$status"
}

# Get container health
get_container_health() {
    local container_name="$1"
    docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}no healthcheck{{end}}' "$container_name" 2>/dev/null || echo "N/A"
}

# Get container image version (tag)
get_container_version() {
    local container_name="$1"
    local image
    image=$(docker inspect --format='{{.Config.Image}}' "$container_name" 2>/dev/null)
    if [ -n "$image" ]; then
        # Extract tag from image (after last colon)
        if [[ "$image" == *":"* ]]; then
            echo "${image##*:}"
        else
            echo "latest"
        fi
    else
        echo "N/A"
    fi
}

# Get container uptime
get_container_uptime() {
    local container_name="$1"
    local started_at
    started_at=$(docker inspect --format='{{.State.StartedAt}}' "$container_name" 2>/dev/null)

    if [ -z "$started_at" ] || [ "$started_at" = "0001-01-01T00:00:00Z" ]; then
        echo "N/A"
        return
    fi

    # Calculate uptime
    local start_ts
    local now_ts
    local diff

    if [[ "$OSTYPE" == "darwin"* ]]; then
        start_ts=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${started_at%%.*}" "+%s" 2>/dev/null || echo "0")
    else
        start_ts=$(date -d "$started_at" "+%s" 2>/dev/null || echo "0")
    fi
    now_ts=$(date "+%s")
    diff=$((now_ts - start_ts))

    if [ "$diff" -lt 60 ]; then
        echo "${diff}s"
    elif [ "$diff" -lt 3600 ]; then
        echo "$((diff / 60))m"
    elif [ "$diff" -lt 86400 ]; then
        echo "$((diff / 3600))h $((diff % 3600 / 60))m"
    else
        echo "$((diff / 86400))d $((diff % 86400 / 3600))h"
    fi
}

# Display services in a table format
display_services_table() {
    local services=("$@")

    if [ ${#services[@]} -eq 0 ]; then
        print_warning "No services found"
        return 1
    fi

    echo ""
    printf "${CYAN}%-4s %-20s %-12s %-12s %-10s %-12s %s${NC}\n" "#" "SERVICE" "STATUS" "HEALTH" "VERSION" "UPTIME" "HOSTNAME"
    echo "───────────────────────────────────────────────────────────────────────────────────────────────"

    local i=1
    for service in "${services[@]}"; do
        local status health version uptime hostname
        status=$(get_container_status "$service")
        health=$(get_container_health "$service")
        version=$(get_container_version "$service")
        uptime=$(get_container_uptime "$service")
        hostname=$(get_service_config "$service" "HOSTNAME")

        # Truncate version if too long
        if [ ${#version} -gt 10 ]; then
            version="${version:0:9}…"
        fi

        # Color code status
        local status_color
        case "$status" in
            running) status_color="${GREEN}${status}${NC}" ;;
            exited|dead) status_color="${RED}${status}${NC}" ;;
            *) status_color="${YELLOW}${status}${NC}" ;;
        esac

        # Color code health
        local health_color
        case "$health" in
            healthy) health_color="${GREEN}${health}${NC}" ;;
            unhealthy) health_color="${RED}${health}${NC}" ;;
            *) health_color="${YELLOW}${health}${NC}" ;;
        esac

        printf "%-4s %-20s %-23s %-23s %-10s %-12s %s\n" "$i" "$service" "$status_color" "$health_color" "$version" "$uptime" "$hostname"
        ((i++))
    done
    echo ""
}

# Prompt user to select a service
select_service() {
    local prompt="$1"
    shift
    local services=("$@")

    display_services_table "${services[@]}"

    local selection
    while true; do
        read -p "$prompt (1-${#services[@]}, or 'q' to quit): " selection

        if [ "$selection" = "q" ] || [ "$selection" = "Q" ]; then
            return 1
        fi

        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le ${#services[@]} ]; then
            SELECTED_SERVICE="${services[$((selection-1))]}"
            return 0
        fi

        print_error "Invalid selection. Please enter a number between 1 and ${#services[@]}"
    done
}

# =============================================================================
# Service Operations (Docker Compose Wrappers)
# =============================================================================

# Get service directory path
get_service_dir() {
    local service_name="$1"
    echo "${SERVICES_DIR}/${service_name}"
}

# Display service info in a consistent format
# Usage: display_service_info <service_name> [fields...]
# Fields: name, hostname, image, version, port, status, health, uptime
# If no fields specified, shows all
display_service_info() {
    local service_name="$1"
    shift
    local fields=("$@")

    # Default to all fields if none specified
    if [ ${#fields[@]} -eq 0 ]; then
        fields=(name hostname image version port status health uptime)
    fi

    local service_dir
    service_dir=$(get_service_dir "$service_name")

    echo ""
    echo "Service Details:"

    for field in "${fields[@]}"; do
        case "$field" in
            name)
                echo "  Name:     ${service_name}"
                ;;
            hostname)
                local hostname
                hostname=$(get_service_config "$service_name" "HOSTNAME")
                echo "  Hostname: ${hostname}"
                ;;
            image)
                local image
                image=$(get_service_config "$service_name" "DOCKER_IMAGE")
                echo "  Image:    ${image}"
                ;;
            version)
                local version
                version=$(get_container_version "$service_name")
                echo "  Version:  ${version}"
                ;;
            port)
                local port
                port=$(get_service_config "$service_name" "PORT")
                echo "  Port:     ${port}"
                ;;
            status)
                local status
                status=$(get_container_status "$service_name")
                echo "  Status:   ${status}"
                ;;
            health)
                local health
                health=$(get_container_health "$service_name")
                echo "  Health:   ${health}"
                ;;
            uptime)
                local uptime
                uptime=$(get_container_uptime "$service_name")
                echo "  Uptime:   ${uptime}"
                ;;
        esac
    done
    echo ""
}

# Run docker compose command in service directory
# Usage: service_compose <service_name> <command...>
service_compose() {
    local service_name="$1"
    shift
    local service_dir
    service_dir=$(get_service_dir "$service_name")

    local docker_compose
    docker_compose=$(get_docker_compose_cmd)

    (cd "$service_dir" && $docker_compose "$@")
}

# Pull latest image for a service
service_pull() {
    local service_name="$1"
    print_info "Pulling latest image..."
    service_compose "$service_name" pull
}

# Build a service image from source.
#
# The private @sudobility registry token (GH_PACKAGES_READ_TOKEN) is read from
# the service's Doppler-fetched .env and handed to the build as a BuildKit
# *secret* (compose `secrets.environment`), so it is mounted only for the
# install step and never written into an image layer or `docker history`. The
# service Dockerfile must consume it via `RUN --mount=type=secret,id=gh_packages_token`.
service_build() {
    local service_name="$1"
    local service_dir
    service_dir=$(get_service_dir "$service_name")

    local docker_compose
    docker_compose=$(get_docker_compose_cmd)

    # Pull the token out of the Doppler-fetched env (never echo it).
    local gh_token
    gh_token=$(grep -E '^GH_PACKAGES_READ_TOKEN=' "${service_dir}/.env" 2>/dev/null \
        | head -1 | cut -d= -f2- | sed -E 's/^["'"'"']//; s/["'"'"']$//')

    if [ -z "$gh_token" ]; then
        print_error "GH_PACKAGES_READ_TOKEN not found in this service's Doppler secrets"
        print_info "Add GH_PACKAGES_READ_TOKEN (a GitHub token with read:packages) to the"
        print_info "service's Doppler config so the build can install @sudobility/* deps."
        return 1
    fi

    print_info "Building image (token injected as a BuildKit secret, never baked in)..."
    # BuildKit is required for secret mounts. The token is exported only for
    # this one command; compose reads it via the `gh_packages_token` secret's
    # `environment` source.
    (cd "$service_dir" && \
        DOCKER_BUILDKIT=1 COMPOSE_DOCKER_CLI_BUILD=1 \
        GH_PACKAGES_READ_TOKEN="$gh_token" \
        $docker_compose build)
}

# Start a service
service_start() {
    local service_name="$1"
    print_info "Starting container..."
    service_compose "$service_name" up -d
}

# Stop a service
service_stop() {
    local service_name="$1"
    print_info "Stopping container..."
    service_compose "$service_name" down
}

# Stop and remove a service with volumes
service_remove() {
    local service_name="$1"
    print_info "Stopping and removing container..."
    service_compose "$service_name" down --volumes --remove-orphans 2>/dev/null || true
}

# Wait for service to start and verify
# Returns 0 if running, 1 otherwise
service_wait_and_verify() {
    local service_name="$1"
    local wait_seconds="${2:-5}"

    print_info "Waiting for service to start..."
    sleep "$wait_seconds"

    local status
    status=$(get_container_status "$service_name")

    if [ "$status" = "running" ]; then
        print_success "Service is running"
        return 0
    else
        print_warning "Service status: $status"
        return 1
    fi
}

# Remove service configuration files (tokens, config directory)
service_cleanup_config() {
    local service_name="$1"
    local service_dir
    service_dir=$(get_service_dir "$service_name")

    # Remove Doppler token
    local token_file="${TOKENS_DIR}/${service_name}"
    if [ -f "$token_file" ]; then
        rm -f "$token_file"
        print_success "Doppler token removed"
    fi

    # Remove service directory
    if [ -d "$service_dir" ]; then
        rm -rf "$service_dir"
        print_success "Service configuration removed"
    fi
}

# =============================================================================
# Doppler Integration
# =============================================================================

DOPPLER_API_URL="https://api.doppler.com/v3/configs/config/secrets/download"

# Validate a Doppler token
validate_doppler_token() {
    local token="$1"

    if [ -z "$token" ]; then
        return 1
    fi

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -u "${token}:" \
        "${DOPPLER_API_URL}?format=env")

    [ "$http_code" -eq 200 ]
}

# Fetch secrets from Doppler
fetch_doppler_secrets() {
    local token="$1"
    local output_file="$2"

    curl -s -w "%{http_code}" \
        -u "${token}:" \
        -o "$output_file" \
        "${DOPPLER_API_URL}?format=env"
}

# Get Doppler token for a service
get_doppler_token() {
    local service_name="$1"
    local token_file="${TOKENS_DIR}/${service_name}"

    if [ -f "$token_file" ]; then
        cat "$token_file"
    fi
}

# Save Doppler token for a service
save_doppler_token() {
    local service_name="$1"
    local token="$2"
    local token_file="${TOKENS_DIR}/${service_name}"

    echo "$token" > "$token_file"
    secure_file "$token_file"
}
