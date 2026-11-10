#!/bin/bash
# add.sh - Add a new service to the server
# Usage: ./add.sh [--dry-run]
#
# Options:
#   --dry-run   Show what would be done without making any changes.
#               No directories are created, no secrets are fetched,
#               and no containers are started.

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Source helper scripts
source "./setup-scripts/common.sh"

# Parse flags
DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --dry-run)
            DRY_RUN=true
            ;;
        --help|-h)
            echo "Usage: ./add.sh [--dry-run]"
            echo ""
            echo "Options:"
            echo "  --dry-run   Show what would be done without making any changes"
            echo "  --help      Show this help message"
            exit 0
            ;;
        *)
            print_error "Unknown option: $arg"
            echo "Usage: ./add.sh [--dry-run]"
            exit 1
            ;;
    esac
done

# =============================================================================
# Main Add Flow
# =============================================================================

if [ "$DRY_RUN" = true ]; then
    print_header "Add New Service (DRY RUN)"
    print_warning "Dry-run mode: no changes will be made"
    echo ""
else
    print_header "Add New Service"
fi

echo "This script will add a new Docker service with:"
echo "  - Automatic SSL certificate via Let's Encrypt"
echo "  - Environment variables from Doppler"
echo "  - Traefik routing by hostname"
echo ""

# =============================================================================
# Step 1: Ensure Traefik is running
# =============================================================================
print_header "Step 1: Checking Traefik"

if [ "$DRY_RUN" = true ]; then
    if is_traefik_running; then
        print_info "Would verify Traefik is running [already running]"
    else
        print_info "Would install and start Traefik"
    fi
else
    if ! install_traefik; then
        print_error "Failed to set up Traefik. Cannot continue."
        exit 1
    fi
fi

# =============================================================================
# Step 2: Get service details
# =============================================================================
print_header "Step 2: Service Configuration"

# Service name
echo "Enter a name for this service (used for container name, e.g., 'shapeshyft_api'):"
read -p "Service name: " SERVICE_NAME

if [ -z "$SERVICE_NAME" ]; then
    print_error "Service name cannot be empty"
    exit 1
fi

# Validate service name (alphanumeric and underscores only)
if [[ ! "$SERVICE_NAME" =~ ^[a-zA-Z][a-zA-Z0-9_]*$ ]]; then
    print_error "Service name must start with a letter and contain only letters, numbers, and underscores"
    exit 1
fi

# Check if service already exists
if service_exists "$SERVICE_NAME"; then
    print_error "Service '$SERVICE_NAME' already exists. Use upgrade.sh to update it."
    exit 1
fi

# Hostname
echo ""
echo "Enter the public hostname for this service (e.g., 'api.example.com'):"
read -p "Hostname: " HOSTNAME

if [ -z "$HOSTNAME" ]; then
    print_error "Hostname cannot be empty"
    exit 1
fi

# Install method: pull a prebuilt image, or build from source.
#
# Build-from-source is the way to install services with private @sudobility/*
# deps WITHOUT baking a registry token into a published image: the build reads
# GH_PACKAGES_READ_TOKEN from this service's Doppler secrets and injects it as a
# BuildKit secret (see service_build / the generated compose `secrets` block).
echo ""
echo "How should this service's image be installed?"
echo "  1) Pull a prebuilt image (docker.io/username/image:latest)"
echo "  2) Build from source (private deps via GH_PACKAGES_READ_TOKEN from Doppler)"
read -p "Select [1-2]: " INSTALL_CHOICE

INSTALL_METHOD="pull"
DOCKER_IMAGE=""
BUILD_CONTEXT=""
if [ "$INSTALL_CHOICE" = "2" ]; then
    INSTALL_METHOD="build"
    echo ""
    echo "Enter the build context (path to the service source, relative to"
    echo "${SERVICES_DIR}/${SERVICE_NAME}/ or absolute). E.g. '../../../${SERVICE_NAME}':"
    read -p "Build context: " BUILD_CONTEXT
    if [ -z "$BUILD_CONTEXT" ]; then
        print_error "Build context cannot be empty"
        exit 1
    fi
    # Local tag for the built image; also what `up -d` runs.
    DOCKER_IMAGE="sudobility/${SERVICE_NAME}:local"
else
    echo ""
    echo "Enter the Docker image (e.g., 'docker.io/username/image:latest'):"
    read -p "Docker image: " DOCKER_IMAGE
    if [ -z "$DOCKER_IMAGE" ]; then
        print_error "Docker image cannot be empty"
        exit 1
    fi
fi

# Health endpoint (optional)
echo ""
echo "Health check configuration:"
echo "  1) Use /health endpoint"
echo "  2) Skip health check"
read -p "Select [1-2]: " HEALTH_CHOICE

case "$HEALTH_CHOICE" in
    1) HEALTH_ENDPOINT="/health" ;;
    *) HEALTH_ENDPOINT="" ;;
esac

# =============================================================================
# Step 3: Configure Doppler
# =============================================================================
print_header "Step 3: Doppler Configuration"

echo "Enter the Doppler service token for this service."
echo "Create one at: Doppler Dashboard → Project → Config → Access → Service Tokens"
echo ""

DOPPLER_TOKEN=""
while true; do
    read -sp "Doppler service token: " DOPPLER_TOKEN
    echo ""

    if [ -z "$DOPPLER_TOKEN" ]; then
        print_error "Token cannot be empty"
        continue
    fi

    print_info "Validating token..."
    if validate_doppler_token "$DOPPLER_TOKEN"; then
        print_success "Token validated successfully"
        break
    else
        print_error "Invalid token. Please check and try again."
    fi
done

# =============================================================================
# Step 4: Fetch and validate environment
# =============================================================================
print_header "Step 4: Fetching Environment Variables"

if [ "$DRY_RUN" = true ]; then
    print_info "Would create directories under ${SERVICES_DIR}/${SERVICE_NAME}/"
    print_info "Would fetch secrets from Doppler and save to .env"
    print_info "Would validate that PORT variable exists in Doppler secrets"
    PORT="<from-doppler>"
else
    ensure_dirs

    SERVICE_DIR="${SERVICES_DIR}/${SERVICE_NAME}"
    mkdir -p "$SERVICE_DIR"

    ENV_FILE="${SERVICE_DIR}/.env"
    print_info "Fetching secrets from Doppler..."

    HTTP_CODE=$(fetch_doppler_secrets "$DOPPLER_TOKEN" "$ENV_FILE")

    if [ "$HTTP_CODE" != "200" ]; then
        print_error "Failed to fetch secrets from Doppler (HTTP $HTTP_CODE)"
        rm -rf "$SERVICE_DIR"
        exit 1
    fi

    secure_file "$ENV_FILE"
    print_success "Environment variables saved"

    # Check for PORT variable
    PORT=$(grep "^PORT=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'")

    if [ -z "$PORT" ]; then
        print_error "PORT environment variable not found in Doppler secrets"
        print_info "Please add a PORT variable to your Doppler configuration"
        rm -rf "$SERVICE_DIR"
        exit 1
    fi

    print_success "Found PORT=$PORT"
fi

# =============================================================================
# Step 5: Create service configuration
# =============================================================================
print_header "Step 5: Creating Service"

if [ "$DRY_RUN" = true ]; then
    print_info "Would create service config at ${SERVICES_DIR}/${SERVICE_NAME}/.service.conf"
    print_info "Would save Doppler token to ${TOKENS_DIR}/${SERVICE_NAME}"
    print_info "Would generate docker-compose.yml at ${SERVICES_DIR}/${SERVICE_NAME}/docker-compose.yml"
    if [ -n "$HEALTH_ENDPOINT" ]; then
        print_info "Would include healthcheck for endpoint: ${HEALTH_ENDPOINT}"
    else
        print_info "Would skip healthcheck (none configured)"
    fi
    print_info "Would configure Traefik labels:"
    print_info "  - Router rule: Host(\`${HOSTNAME}\`)"
    print_info "  - Entrypoint: websecure"
    print_info "  - TLS certresolver: letsencrypt"
    print_info "  - Load balancer port: ${PORT}"
else
    # Save service config
    cat > "${SERVICE_DIR}/.service.conf" << EOF
# Service configuration - created by add.sh
SERVICE_NAME=${SERVICE_NAME}
HOSTNAME=${HOSTNAME}
INSTALL_METHOD=${INSTALL_METHOD}
DOCKER_IMAGE=${DOCKER_IMAGE}
BUILD_CONTEXT=${BUILD_CONTEXT}
PORT=${PORT}
HEALTH_ENDPOINT=${HEALTH_ENDPOINT}
CREATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF

    secure_file "${SERVICE_DIR}/.service.conf"

    # Save Doppler token
    save_doppler_token "$SERVICE_NAME" "$DOPPLER_TOKEN"

    # Create docker-compose.yml for the service
    # Build healthcheck section conditionally
    HEALTHCHECK_SECTION=""
    if [ -n "$HEALTH_ENDPOINT" ]; then
        HEALTHCHECK_SECTION="    healthcheck:
      test: [\"CMD\", \"curl\", \"-f\", \"http://localhost:${PORT}${HEALTH_ENDPOINT}\"]
      interval: 30s
      timeout: 15s
      retries: 3
      start_period: 30s"
    fi

    # Image source: a `build:` block (with a BuildKit secret for the private
    # registry token) when building from source, or a plain `image:` when
    # pulling a prebuilt image. The token is never baked into the image — it is
    # mounted only during the build via the `gh_packages_token` secret below.
    IMAGE_SECTION=""
    SECRETS_SECTION=""
    if [ "$INSTALL_METHOD" = "build" ]; then
        IMAGE_SECTION="    build:
      context: ${BUILD_CONTEXT}
      secrets:
        - gh_packages_token
    image: ${DOCKER_IMAGE}"
        SECRETS_SECTION="
secrets:
  # Sourced from this service's environment at build time (service_build sets
  # GH_PACKAGES_READ_TOKEN from the Doppler-fetched .env). BuildKit mounts it
  # only for the install step, so it never reaches an image layer.
  gh_packages_token:
    environment: GH_PACKAGES_READ_TOKEN
"
    else
        IMAGE_SECTION="    image: ${DOCKER_IMAGE}"
    fi

    cat > "${SERVICE_DIR}/docker-compose.yml" << EOF
# ${SERVICE_NAME} - Generated by add.sh
services:
  ${SERVICE_NAME}:
${IMAGE_SECTION}
    container_name: ${SERVICE_NAME}
    restart: unless-stopped
    env_file:
      - .env
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${SERVICE_NAME}.rule=Host(\`${HOSTNAME}\`)"
      - "traefik.http.routers.${SERVICE_NAME}.entrypoints=websecure"
      - "traefik.http.routers.${SERVICE_NAME}.tls.certresolver=letsencrypt"
      - "traefik.http.services.${SERVICE_NAME}.loadbalancer.server.port=${PORT}"
${HEALTHCHECK_SECTION}
    networks:
      - sudobility_network
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
${SECRETS_SECTION}
networks:
  sudobility_network:
    external: true
EOF

    print_success "Service configuration created"
fi

# =============================================================================
# Step 6: Start the service
# =============================================================================
print_header "Step 6: Starting Service"

if [ "$DRY_RUN" = true ]; then
    if [ "$INSTALL_METHOD" = "build" ]; then
        print_info "Would build image from: ${BUILD_CONTEXT} (GH_PACKAGES_READ_TOKEN from Doppler, as a BuildKit secret)"
    else
        print_info "Would pull Docker image: ${DOCKER_IMAGE}"
    fi
    print_info "Would start container: ${SERVICE_NAME}"
else
    if [ "$INSTALL_METHOD" = "build" ]; then
        service_build "$SERVICE_NAME" || { print_error "Build failed"; exit 1; }
    else
        service_pull "$SERVICE_NAME"
    fi
    service_start "$SERVICE_NAME"
fi

# =============================================================================
# Step 7: Verify
# =============================================================================
print_header "Step 7: Verification"

if [ "$DRY_RUN" = true ]; then
    print_info "Would verify container is running"
    print_info "Would display service info"
    echo ""
    echo "Summary of what would be created:"
    echo "  Service name:    ${SERVICE_NAME}"
    echo "  Hostname:        ${HOSTNAME}"
    echo "  Docker image:    ${DOCKER_IMAGE}"
    echo "  Health endpoint: ${HEALTH_ENDPOINT:-none}"
    echo "  Config dir:      ${SERVICES_DIR}/${SERVICE_NAME}/"
    echo ""
    print_success "Dry run complete. No changes were made."
else
    service_wait_and_verify "$SERVICE_NAME"
    display_service_info "$SERVICE_NAME" name hostname image version port

    echo "Access your service at:"
    echo "  https://${HOSTNAME}/"
    echo ""
    echo "Note: SSL certificate may take a minute to be issued."
    echo ""
    echo "Useful commands:"
    echo "  View logs:    cd ${SERVICE_DIR} && docker compose logs -f"
    echo "  Restart:      cd ${SERVICE_DIR} && docker compose restart"
    echo "  Stop:         cd ${SERVICE_DIR} && docker compose down"
    echo ""

    print_success "Service '$SERVICE_NAME' added successfully!"
fi
