#!/bin/bash
# Script to run the OpenEMR container with kcov coverage reporting enabled

# Set required environment variables
export DOCKER_CONTEXT_PATH=flex-edge
export COMPOSE_PROFILES=kcov

# Remove any previous container and volumes
docker compose down --remove-orphans --volumes

# Build and run with coverage enabled
docker compose build
docker compose up -d

echo "OpenEMR is starting with kcov coverage enabled..."
echo "Coverage reports will be available in docker/openemr/coverage-reports/"
echo "Container logs can be viewed with: docker compose logs -f openemr-kcov"
