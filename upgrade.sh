#!/bin/bash
# upgrade.sh - Upgrade an existing service
# Usage: ./upgrade.sh [--dry-run]
#
# Options:
#   --dry-run   Show what would be done without making any changes.
#               No secrets are fetched, no images are pulled,
#               and no containers are restarted.

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
            echo "Usage: ./upgrade.sh [--dry-run]"
            echo ""
            echo "Options:"
            echo "  --dry-run   Show what would be done without making any changes"
            echo "  --help      Show this help message"
            exit 0
            ;;
        *)
            print_error "Unknown option: $arg"
            echo "Usage: ./upgrade.sh [--dry-run]"
            exit 1
            ;;
    esac
done

# =============================================================================
# Main Upgrade Flow
# =============================================================================

if [ "$DRY_RUN" = true ]; then
    print_header "Upgrade Service (DRY RUN)"
    print_warning "Dry-run mode: no changes will be made"
    echo ""
else
    print_header "Upgrade Service"
fi

# Get list of services (bash 3.x compatible)
read_services_array

if [ ${#SERVICES[@]} -eq 0 ]; then
    print_warning "No services found. Use add.sh to add a service first."
    exit 0
fi

echo "Select a service to upgrade:"

if ! select_service "Select service" "${SERVICES[@]}"; then
    print_info "Upgrade cancelled."
    exit 0
fi

SERVICE_NAME="$SELECTED_SERVICE"
SERVICE_DIR="${SERVICES_DIR}/${SERVICE_NAME}"

print_info "Selected: $SERVICE_NAME"

# =============================================================================
# Confirm upgrade
# =============================================================================

echo ""
if ! prompt_yes_no "Upgrade $SERVICE_NAME?" "y"; then
    print_info "Upgrade cancelled."
    exit 0
fi

# =============================================================================
# Step 1: Update environment from Doppler
# =============================================================================
print_header "Step 1: Updating Environment Variables"

if [ "$DRY_RUN" = true ]; then
    DOPPLER_TOKEN=$(get_doppler_token "$SERVICE_NAME")
    if [ -n "$DOPPLER_TOKEN" ]; then
        print_info "Would fetch latest secrets from Doppler"
        print_info "Would backup current .env to .env.backup"
        print_info "Would update PORT in config if changed"
    else
        print_info "No Doppler token found, would skip environment update"
    fi
else
    DOPPLER_TOKEN=$(get_doppler_token "$SERVICE_NAME")

    if [ -n "$DOPPLER_TOKEN" ]; then
        print_info "Fetching latest secrets from Doppler..."

        ENV_FILE="${SERVICE_DIR}/.env"
        ENV_BACKUP="${SERVICE_DIR}/.env.backup"

        # Backup current env
        if [ -f "$ENV_FILE" ]; then
            cp "$ENV_FILE" "$ENV_BACKUP"
        fi

        HTTP_CODE=$(fetch_doppler_secrets "$DOPPLER_TOKEN" "$ENV_FILE")

        if [ "$HTTP_CODE" = "200" ]; then
            secure_file "$ENV_FILE"
            print_success "Environment variables updated"

            # Update PORT in service config if changed
            NEW_PORT=$(grep "^PORT=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'")
            OLD_PORT=$(get_service_config "$SERVICE_NAME" "PORT")

            if [ -n "$NEW_PORT" ] && [ "$NEW_PORT" != "$OLD_PORT" ]; then
                print_warning "PORT changed: $OLD_PORT → $NEW_PORT"
                # Update docker-compose.yml with new port
                sed -i.bak "s/server.port=${OLD_PORT}/server.port=${NEW_PORT}/g" "${SERVICE_DIR}/docker-compose.yml"
                sed -i.bak "s/localhost:${OLD_PORT}/localhost:${NEW_PORT}/g" "${SERVICE_DIR}/docker-compose.yml"
                rm -f "${SERVICE_DIR}/docker-compose.yml.bak"

                # Update service config
                sed -i.bak "s/^PORT=.*/PORT=${NEW_PORT}/" "${SERVICE_DIR}/.service.conf"
                rm -f "${SERVICE_DIR}/.service.conf.bak"
            fi
        else
            print_warning "Failed to fetch secrets (HTTP $HTTP_CODE), using existing environment"
            if [ -f "$ENV_BACKUP" ]; then
                mv "$ENV_BACKUP" "$ENV_FILE"
            fi
        fi
    else
        print_warning "No Doppler token found, skipping environment update"
    fi
fi

# =============================================================================
# Step 2: Refresh the image (rebuild from source, or pull a prebuilt image)
# =============================================================================
INSTALL_METHOD=$(get_service_config "$SERVICE_NAME" "INSTALL_METHOD")
[ -z "$INSTALL_METHOD" ] && INSTALL_METHOD="pull"  # back-compat: older services

if [ "$INSTALL_METHOD" = "build" ]; then
    print_header "Step 2: Rebuilding Image From Source"
    if [ "$DRY_RUN" = true ]; then
        BUILD_CONTEXT=$(get_service_config "$SERVICE_NAME" "BUILD_CONTEXT")
        print_info "Would rebuild from: ${BUILD_CONTEXT} (GH_PACKAGES_READ_TOKEN from Doppler, as a BuildKit secret)"
    else
        service_build "$SERVICE_NAME" || { print_error "Build failed"; exit 1; }
    fi
else
    print_header "Step 2: Pulling Latest Image"
    if [ "$DRY_RUN" = true ]; then
        DOCKER_IMAGE=$(get_service_config "$SERVICE_NAME" "DOCKER_IMAGE")
        print_info "Would pull latest image: ${DOCKER_IMAGE}"
    else
        service_pull "$SERVICE_NAME"
    fi
fi

print_header "Step 3: Restarting Service"

if [ "$DRY_RUN" = true ]; then
    print_info "Would stop container: ${SERVICE_NAME}"
    print_info "Would start container: ${SERVICE_NAME}"
else
    service_stop "$SERVICE_NAME"
    service_start "$SERVICE_NAME"
fi

# =============================================================================
# Verify
# =============================================================================
print_header "Verification"

if [ "$DRY_RUN" = true ]; then
    print_info "Would verify container is running"
    display_service_info "$SERVICE_NAME" name status health version hostname
    echo ""
    print_success "Dry run complete. No changes were made."
else
    if service_wait_and_verify "$SERVICE_NAME"; then
        display_service_info "$SERVICE_NAME" name status health version hostname
        print_success "Service '$SERVICE_NAME' upgraded successfully!"
    else
        display_service_info "$SERVICE_NAME" name status health version hostname
        print_warning "Service may not have started correctly. Check logs:"
        echo "  cd ${SERVICE_DIR} && docker compose logs"
    fi
fi
