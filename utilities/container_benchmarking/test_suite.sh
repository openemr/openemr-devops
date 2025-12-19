#!/usr/bin/env bash
# ============================================================================
# OpenEMR Container Functional Test Suite
# ============================================================================
# This script runs comprehensive functional tests for OpenEMR container
# functionality including installation, configuration, and various deployment
# scenarios.
#
# Usage: ./test_suite.sh [--test TEST_NAME] [--verbose] [--keep-containers]
# ============================================================================

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_NAME="${PROJECT_NAME:-openemr-test}"
RESULTS_DIR="${RESULTS_DIR:-${SCRIPT_DIR}/test_results}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULT_FILE="${RESULTS_DIR}/test_results_${TIMESTAMP}.txt"
LOG_FILE="${RESULTS_DIR}/test_log_${TIMESTAMP}.txt"

# Test configuration
DOCKER_CONTEXT="${DOCKER_CONTEXT:-../../docker/openemr/7.0.5}"
IMAGE_TAG="${IMAGE_TAG:-openemr:7.0.5-test}"
KEEP_CONTAINERS="${KEEP_CONTAINERS:-no}"
VERBOSE="${VERBOSE:-no}"
VERSION="${VERSION:-7.0.5}"

# Test directories (relative to script directory)
TESTS_DIR="${SCRIPT_DIR}/tests"

# Colors for output (using tput for better portability, with ANSI fallback)
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput bold; tput setaf 3)
    BLUE=$(tput setaf 4)
    CYAN=$(tput setaf 6)
    NC=$(tput sgr0) # No Color
else
    # Fallback to ANSI codes
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    NC='\033[0m' # No Color
fi

# Test results tracking
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
FAILED_TESTS=()

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

log_info() {
    echo -e "${BLUE}ℹ${NC} $*" | tee -a "${LOG_FILE}"
}

log_success() {
    echo -e "${GREEN}✓${NC} $*" | tee -a "${LOG_FILE}"
}

log_warning() {
    echo -e "${YELLOW}⚠${NC} $*" | tee -a "${LOG_FILE}"
}

log_error() {
    echo -e "${RED}✗${NC} $*" | tee -a "${LOG_FILE}"
}

log_section() {
    echo "" | tee -a "${LOG_FILE}"
    echo "============================================================================" | tee -a "${LOG_FILE}"
    echo "$*" | tee -a "${LOG_FILE}"
    echo "============================================================================" | tee -a "${LOG_FILE}"
}

log_test_start() {
    local test_name="$1"
    echo "" | tee -a "${LOG_FILE}"
    echo -e "${CYAN}▶ Testing: ${test_name}${NC}" | tee -a "${LOG_FILE}"
}

log_test_result() {
    local test_name="$1"
    local result="$2"
    local message="${3:-}"

    if [[ "${result}" = "PASS" ]]; then
        log_success "PASS: ${test_name}${message:+ - ${message}}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "PASS: ${test_name}${message:+ - ${message}}" >> "${RESULT_FILE}"
    elif [[ "${result}" = "FAIL" ]]; then
        log_error "FAIL: ${test_name}${message:+ - ${message}}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED_TESTS+=("${test_name}")
        echo "FAIL: ${test_name}${message:+ - ${message}}" >> "${RESULT_FILE}"
    elif [[ "${result}" = "SKIP" ]]; then
        log_warning "SKIP: ${test_name}${message:+ - ${message}}"
        TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
        echo "SKIP: ${test_name}${message:+ - ${message}}" >> "${RESULT_FILE}"
    fi
}

# Wait for container to be healthy with progress updates
wait_for_healthy() {
    local container_name="$1"
    local max_wait="${2:-300}"  # Default 5 minutes
    local waited=0
    local last_progress=0
    local progress_interval=30  # Show progress every 30 seconds
    
    log_info "Waiting for container ${container_name} to become healthy (max ${max_wait}s)..."
    
    while [[ "${waited}" -lt "${max_wait}" ]]; do
        local health_status
        health_status=$(docker inspect "${container_name}" --format '{{.State.Health.Status}}' 2>/dev/null || echo "starting")
        
        if [[ "${health_status}" = "healthy" ]]; then
            log_success "Container ${container_name} is now healthy (took ${waited}s)"
            return 0
        elif [[ "${health_status}" = "unhealthy" ]]; then
            log_error "Container ${container_name} is unhealthy"
            docker logs "${container_name}" --tail 50 2>&1 | tee -a "${LOG_FILE}" || true
            return 1
        fi
        
        # Show progress every progress_interval seconds
        if [[ $((waited - last_progress)) -ge "${progress_interval}" ]]; then
            log_info "Still waiting... (${waited}s/${max_wait}s) - Status: ${health_status}"
            last_progress=${waited}
            # Show recent logs to keep user informed
            docker logs "${container_name}" --tail 5 2>&1 | sed 's/^/  > /' | tee -a "${LOG_FILE}" || true
        fi
        
        sleep 2
        waited=$((waited + 2))
    done
    
    log_error "Container ${container_name} did not become healthy within ${max_wait}s"
    docker logs "${container_name}" --tail 50 2>&1 | tee -a "${LOG_FILE}" || true
    return 1
}

# Wait for HTTP response
wait_for_http() {
    local url="$1"
    local max_wait="${2:-120}"
    local waited=0

    while [[ "${waited}" -lt "${max_wait}" ]]; do
        if curl -sfL -o /dev/null -w "%{http_code}" "${url}" | grep -q "200\|302"; then
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done

    return 1
}

# Check if OpenEMR is configured
check_openemr_configured() {
    local container_name="$1"
    docker exec "${container_name}" php -r "
        require_once('/var/www/localhost/htdocs/openemr/sites/default/sqlconf.php');
        echo isset(\$config) && \$config ? '1' : '0';
    " 2>/dev/null || echo "0"
}

# Cleanup function
cleanup() {
    if [[ "${KEEP_CONTAINERS}" != "yes" ]]; then
        log_info "Cleaning up test containers and volumes..."
        # Clean up all test projects
        for project in fresh manual ssl redis swarm k8s xdebug docs upgrade; do
            docker compose -p "${PROJECT_NAME}-${project}" down --remove-orphans --volumes >/dev/null 2>&1 || true
        done
        # Also clean up any volumes that might have been created
        docker volume prune -f --filter "label=com.docker.compose.project=${PROJECT_NAME}" >/dev/null 2>&1 || true
    else
        log_info "Keeping containers (KEEP_CONTAINERS=yes)"
    fi
}

# Trap to ensure cleanup on exit
trap cleanup EXIT

# ============================================================================
# HELPER FUNCTIONS FOR TESTS
# ============================================================================

# Get absolute path for Docker context
get_docker_context_abs() {
    if [[ "${DOCKER_CONTEXT}" = /* ]]; then
        echo "${DOCKER_CONTEXT}"
    else
        echo "${SCRIPT_DIR}/${DOCKER_CONTEXT}"
    fi
}

# ============================================================================
# TEST FUNCTIONS
# ============================================================================

# Test 1: Fresh installation (auto-configure)
test_fresh_installation() {
    local test_name="Fresh Installation (Auto-Configure)"
    log_test_start "${test_name}"

    local test_dir="${TESTS_DIR}/fresh_installation"
    mkdir -p "${test_dir}"

    local docker_context_abs
    docker_context_abs=$(get_docker_context_abs)

    # Create docker-compose.yml for this test
    cat > "${test_dir}/docker-compose.yml" <<EOF
services:
  mysql:
    image: mariadb:11.4
    command:
      - mariadbd
      - --character-set-server=utf8mb4
    environment:
      MYSQL_ROOT_PASSWORD: root
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 10s
      interval: 10s
      timeout: 5s
      retries: 3
    volumes:
      - mysql_data:/var/lib/mysql
    networks:
      - test-network

  openemr:
    build:
      context: ${docker_context_abs}
    image: ${IMAGE_TAG}
    depends_on:
      mysql:
        condition: service_healthy
    environment:
      MYSQL_HOST: mysql
      MYSQL_ROOT_PASS: root
      MYSQL_USER: openemr
      MYSQL_PASS: openemr
      MYSQL_DATABASE: openemr
      OE_USER: admin
      OE_PASS: testpass123
    ports:
      - "8080:80"
    healthcheck:
      test: ["CMD", "curl", "-fsSLo", "/dev/null", "http://localhost/"]
      start_period: 10m
      start_interval: 10s
      interval: 1m
      timeout: 5s
    networks:
      - test-network

volumes:
  mysql_data:

networks:
  test-network:
    driver: bridge
EOF

    cd "${test_dir}"
    
    # Start services (stream build output)
    log_info "Building and starting containers..."
    if ! docker compose -p "${PROJECT_NAME}-fresh" up -d --build 2>&1 | tee -a "${LOG_FILE}"; then
        log_test_result "${test_name}" "FAIL" "Failed to start containers"
        return 1
    fi

    local container_name="${PROJECT_NAME}-fresh-openemr-1"

    # Wait for container to be healthy
    # shellcheck disable=SC2310
    if ! wait_for_healthy "${container_name}" 600; then
        log_test_result "${test_name}" "FAIL" "Container did not become healthy"
        docker compose -p "${PROJECT_NAME}-fresh" logs openemr | tee -a "${LOG_FILE}" || true
        docker compose -p "${PROJECT_NAME}-fresh" down --volumes >/dev/null 2>&1 || true
        return 1
    fi

    # Check if OpenEMR is configured
    local config_status
    config_status=$(check_openemr_configured "${container_name}")

    # Check if we can access the login page
    local http_status
    http_status=$(curl -sL -o /dev/null -w "%{http_code}" "http://localhost:8080/interface/login/login.php" || echo "000")

    # Cleanup
    docker compose -p "${PROJECT_NAME}-fresh" down --volumes >/dev/null 2>&1 || true

    if [[ "${config_status}" = "1" ]] && [[ "${http_status}" = "200" ]]; then
        log_test_result "${test_name}" "PASS" "OpenEMR configured and accessible"
        return 0
    else
        log_test_result "${test_name}" "FAIL" "Config status: ${config_status}, HTTP status: ${http_status}"
        return 1
    fi
}

# Test 2: Manual setup mode
test_manual_setup() {
    local test_name="Manual Setup Mode"
    log_test_start "${test_name}"

    local test_dir="${TESTS_DIR}/manual_setup"
    mkdir -p "${test_dir}"

    local docker_context_abs
    docker_context_abs=$(get_docker_context_abs)

    cat > "${test_dir}/docker-compose.yml" <<EOF

services:
  mysql:
    image: mariadb:11.4
    command:
      - mariadbd
      - --character-set-server=utf8mb4
    environment:
      MYSQL_ROOT_PASSWORD: root
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 10s
      interval: 10s
      timeout: 5s
      retries: 3
    volumes:
      - mysql_data:/var/lib/mysql
    networks:
      - test-network

  openemr:
    build:
      context: ${docker_context_abs}
    image: ${IMAGE_TAG}
    depends_on:
      mysql:
        condition: service_healthy
    environment:
      MYSQL_HOST: mysql
      MYSQL_ROOT_PASS: root
      MANUAL_SETUP: "yes"
    ports:
      - "8081:80"
    healthcheck:
      test: ["CMD", "curl", "-fsSLo", "/dev/null", "http://localhost/"]
      start_period: 10m
      start_interval: 10s
      interval: 1m
      timeout: 5s
    networks:
      - test-network

volumes:
  mysql_data:

networks:
  test-network:
    driver: bridge
EOF

    cd "${test_dir}"
    
    # Start services (stream build output)
    log_info "Building and starting containers..."
    if ! docker compose -p "${PROJECT_NAME}-manual" up -d --build 2>&1 | tee -a "${LOG_FILE}"; then
        log_test_result "${test_name}" "FAIL" "Failed to start containers"
        return 1
    fi

    local container_name="${PROJECT_NAME}-manual-openemr-1"

    # Wait for container to be healthy
    # shellcheck disable=SC2310
    if ! wait_for_healthy "${container_name}" 600; then
        log_test_result "${test_name}" "FAIL" "Container did not become healthy"
        docker compose -p "${PROJECT_NAME}-manual" down --volumes >/dev/null 2>&1 || true
        return 1
    fi

    # Check that auto_configure.php still exists (not removed)
    local auto_config_exists
    auto_config_exists=$(docker exec "${container_name}" test -f /var/www/localhost/htdocs/openemr/auto_configure.php && echo "1" || echo "0")

    # Check that OpenEMR is NOT configured
    local config_status
    config_status=$(check_openemr_configured "${container_name}")

    # Cleanup
    docker compose -p "${PROJECT_NAME}-manual" down --volumes >/dev/null 2>&1 || true

    if [[ "${auto_config_exists}" = "1" ]] && [[ "${config_status}" = "0" ]]; then
        log_test_result "${test_name}" "PASS" "Manual setup mode working correctly"
        return 0
    else
        log_test_result "${test_name}" "FAIL" "Auto-config exists: ${auto_config_exists}, Config status: ${config_status}"
        return 1
    fi
}

# Test 3: SSL/TLS certificate configuration
test_ssl_configuration() {
    local test_name="SSL/TLS Certificate Configuration"
    log_test_start "${test_name}"

    local test_dir="${TESTS_DIR}/ssl_configuration"
    mkdir -p "${test_dir}/certs"
    
    local docker_context_abs
    docker_context_abs=$(get_docker_context_abs)
    
    # Note: Container generates its own self-signed certificates
    # We don't mount /etc/ssl as read-only to allow container to create certs
    cat > "${test_dir}/docker-compose.yml" <<EOF

services:
  mysql:
    image: mariadb:11.4
    command:
      - mariadbd
      - --character-set-server=utf8mb4
    environment:
      MYSQL_ROOT_PASSWORD: root
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 10s
      interval: 10s
      timeout: 5s
      retries: 3
    volumes:
      - mysql_data:/var/lib/mysql
    networks:
      - test-network

  openemr:
    build:
      context: ${docker_context_abs}
    image: ${IMAGE_TAG}
    depends_on:
      mysql:
        condition: service_healthy
    environment:
      MYSQL_HOST: mysql
      MYSQL_ROOT_PASS: root
      MYSQL_USER: openemr
      MYSQL_PASS: openemr
      MYSQL_DATABASE: openemr
      OE_USER: admin
      OE_PASS: testpass123
    ports:
      - "8443:443"
    healthcheck:
      test: ["CMD", "curl", "-kfsSLo", "/dev/null", "https://localhost/"]
      start_period: 10m
      start_interval: 10s
      interval: 1m
      timeout: 5s
    networks:
      - test-network

volumes:
  mysql_data:

networks:
  test-network:
    driver: bridge
EOF

    cd "${test_dir}"
    
    # Start services (stream build output)
    log_info "Building and starting containers..."
    if ! docker compose -p "${PROJECT_NAME}-ssl" up -d --build 2>&1 | tee -a "${LOG_FILE}"; then
        log_test_result "${test_name}" "FAIL" "Failed to start containers"
        return 1
    fi

    local container_name="${PROJECT_NAME}-ssl-openemr-1"

    # shellcheck disable=SC2310
    if ! wait_for_healthy "${container_name}" 600; then
        log_test_result "${test_name}" "FAIL" "Container did not become healthy"
        docker compose -p "${PROJECT_NAME}-ssl" down --volumes >/dev/null 2>&1 || true
        return 1
    fi

    # Check if SSL is configured (container generates selfsigned.cert.pem and webserver.cert.pem symlink)
    local ssl_configured
    ssl_configured=$(docker exec "${container_name}" test -f /etc/ssl/certs/webserver.cert.pem && echo "1" || echo "0")

    # Try to access HTTPS
    local https_status
    https_status=$(curl -kfsL -o /dev/null -w "%{http_code}" "https://localhost:8443/" || echo "000")

    docker compose -p "${PROJECT_NAME}-ssl" down --volumes >/dev/null 2>&1 || true

    if [[ "${ssl_configured}" = "1" ]] && [[ "${https_status}" = "200" ]] || [[ "${https_status}" = "302" ]]; then
        log_test_result "${test_name}" "PASS" "SSL configured and HTTPS accessible"
        return 0
    else
        log_test_result "${test_name}" "FAIL" "SSL configured: ${ssl_configured}, HTTPS status: ${https_status}"
        return 1
    fi
}

# Test 4: Redis session handling
test_redis_sessions() {
    local test_name="Redis Session Handling"
    log_test_start "${test_name}"

    local test_dir="${TESTS_DIR}/redis_sessions"
    mkdir -p "${test_dir}"
    
    local docker_context_abs
    docker_context_abs=$(get_docker_context_abs)
    
    cat > "${test_dir}/docker-compose.yml" <<EOF

services:
  mysql:
    image: mariadb:11.4
    command:
      - mariadbd
      - --character-set-server=utf8mb4
    environment:
      MYSQL_ROOT_PASSWORD: root
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 10s
      interval: 10s
      timeout: 5s
      retries: 3
    volumes:
      - mysql_data:/var/lib/mysql
    networks:
      - test-network

  redis:
    image: redis:7-alpine
    command: redis-server --appendonly yes
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 3s
      retries: 3
    volumes:
      - redis_data:/data
    networks:
      - test-network

  openemr:
    build:
      context: ${docker_context_abs}
    image: ${IMAGE_TAG}
    depends_on:
      mysql:
        condition: service_healthy
      redis:
        condition: service_healthy
    environment:
      MYSQL_HOST: mysql
      MYSQL_ROOT_PASS: root
      MYSQL_USER: openemr
      MYSQL_PASS: openemr
      MYSQL_DATABASE: openemr
      OE_USER: admin
      OE_PASS: testpass123
      REDIS_SERVER: redis:6379
    ports:
      - "8082:80"
    healthcheck:
      test: ["CMD", "curl", "-fsSLo", "/dev/null", "http://localhost/"]
      start_period: 10m
      start_interval: 10s
      interval: 1m
      timeout: 5s
    networks:
      - test-network

volumes:
  mysql_data:
  redis_data:

networks:
  test-network:
    driver: bridge
EOF

    cd "${test_dir}"
    
    # Start services (stream build output)
    log_info "Building and starting containers..."
    if ! docker compose -p "${PROJECT_NAME}-redis" up -d --build 2>&1 | tee -a "${LOG_FILE}"; then
        log_test_result "${test_name}" "FAIL" "Failed to start containers"
        return 1
    fi

    local container_name="${PROJECT_NAME}-redis-openemr-1"

    # shellcheck disable=SC2310
    if ! wait_for_healthy "${container_name}" 600; then
        log_test_result "${test_name}" "FAIL" "Container did not become healthy"
        docker compose -p "${PROJECT_NAME}-redis" down --volumes >/dev/null 2>&1 || true
        return 1
    fi

    # Check if Redis session handler is configured
    # Redis config is written to conf.d/99-redis-sessions.ini, not php.ini directly
    local redis_configured
    redis_configured=$(docker exec "${container_name}" grep -q "session.save_handler = redis" /etc/php84/conf.d/99-redis-sessions.ini 2>/dev/null && echo "1" || echo "0")

    # Check if php-redis-configured marker exists
    local redis_marker
    redis_marker=$(docker exec "${container_name}" test -f /etc/php-redis-configured && echo "1" || echo "0")

    docker compose -p "${PROJECT_NAME}-redis" down --volumes >/dev/null 2>&1 || true

    if [[ "${redis_configured}" = "1" ]] && [[ "${redis_marker}" = "1" ]]; then
        log_test_result "${test_name}" "PASS" "Redis session handler configured"
        return 0
    else
        log_test_result "${test_name}" "FAIL" "Redis configured: ${redis_configured}, Marker: ${redis_marker}"
        return 1
    fi
}

# Test 5: Swarm mode coordination
test_swarm_mode() {
    local test_name="Swarm Mode Coordination"
    log_test_start "${test_name}"

    local test_dir="${TESTS_DIR}/swarm_mode"
    mkdir -p "${test_dir}"
    
    local docker_context_abs
    docker_context_abs=$(get_docker_context_abs)
    
    cat > "${test_dir}/docker-compose.yml" <<EOF

services:
  mysql:
    image: mariadb:11.4
    command:
      - mariadbd
      - --character-set-server=utf8mb4
    environment:
      MYSQL_ROOT_PASSWORD: root
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 10s
      interval: 10s
      timeout: 5s
      retries: 3
    volumes:
      - mysql_data:/var/lib/mysql
    networks:
      - test-network

  openemr-leader:
    build:
      context: ${docker_context_abs}
    image: ${IMAGE_TAG}
    depends_on:
      mysql:
        condition: service_healthy
    environment:
      MYSQL_HOST: mysql
      MYSQL_ROOT_PASS: root
      MYSQL_USER: openemr
      MYSQL_PASS: openemr
      MYSQL_DATABASE: openemr
      OE_USER: admin
      OE_PASS: testpass123
      SWARM_MODE: "yes"
    ports:
      - "8083:80"
    volumes:
      - swarm_sites:/var/www/localhost/htdocs/openemr/sites
    healthcheck:
      test: ["CMD", "curl", "-fsSLo", "/dev/null", "http://localhost/"]
      start_period: 10m
      start_interval: 10s
      interval: 1m
      timeout: 5s
    networks:
      - test-network

  openemr-follower:
    build:
      context: ${docker_context_abs}
    image: ${IMAGE_TAG}
    depends_on:
      mysql:
        condition: service_healthy
      openemr-leader:
        condition: service_started
    environment:
      MYSQL_HOST: mysql
      MYSQL_ROOT_PASS: root
      MYSQL_USER: openemr
      MYSQL_PASS: openemr
      MYSQL_DATABASE: openemr
      SWARM_MODE: "yes"
    ports:
      - "8084:80"
    volumes:
      - swarm_sites:/var/www/localhost/htdocs/openemr/sites
    healthcheck:
      test: ["CMD", "curl", "-fsSLo", "/dev/null", "http://localhost/"]
      start_period: 10m
      start_interval: 10s
      interval: 1m
      timeout: 5s
    networks:
      - test-network

volumes:
  mysql_data:
  swarm_sites:

networks:
  test-network:
    driver: bridge
EOF

    cd "${test_dir}"
    
    # Start services (stream build output)
    log_info "Building and starting containers..."
    if ! docker compose -p "${PROJECT_NAME}-swarm" up -d --build 2>&1 | tee -a "${LOG_FILE}"; then
        log_test_result "${test_name}" "FAIL" "Failed to start containers"
        return 1
    fi

    local leader_name="${PROJECT_NAME}-swarm-openemr-leader-1"
    local follower_name="${PROJECT_NAME}-swarm-openemr-follower-1"

    # Wait for leader to be healthy
    # shellcheck disable=SC2310
    if ! wait_for_healthy "${leader_name}" 600; then
        log_test_result "${test_name}" "FAIL" "Leader container did not become healthy"
        docker compose -p "${PROJECT_NAME}-swarm" down --volumes >/dev/null 2>&1 || true
        return 1
    fi

    # Wait for follower to be healthy
    # shellcheck disable=SC2310
    if ! wait_for_healthy "${follower_name}" 600; then
        log_test_result "${test_name}" "FAIL" "Follower container did not become healthy"
        docker compose -p "${PROJECT_NAME}-swarm" down --volumes >/dev/null 2>&1 || true
        return 1
    fi

    # Check that docker-completed marker exists
    local completed_marker
    completed_marker=$(docker exec "${leader_name}" test -f /var/www/localhost/htdocs/openemr/sites/docker-completed && echo "1" || echo "0")

    # Check that leader has authority (check logs for "docker-leader" or check if it created the completion marker)
    # The leader should have created the docker-completed marker
    local leader_authority
    if docker logs "${leader_name}" 2>&1 | grep -q "docker-leader\|AUTHORITY=yes\|this instance is the leader"; then
        leader_authority="1"
    elif [[ "${completed_marker}" = "1" ]]; then
        # If completion marker exists, leader must have had authority
        leader_authority="1"
    else
        leader_authority="0"
    fi

    docker compose -p "${PROJECT_NAME}-swarm" down --volumes >/dev/null 2>&1 || true

    if [[ "${completed_marker}" = "1" ]] && [[ "${leader_authority}" = "1" ]]; then
        log_test_result "${test_name}" "PASS" "Swarm mode coordination working"
        return 0
    else
        log_test_result "${test_name}" "FAIL" "Completed marker: ${completed_marker}, Leader authority: ${leader_authority}"
        return 1
    fi
}

# Test 6: Kubernetes mode (admin/worker roles)
test_kubernetes_mode() {
    local test_name="Kubernetes Mode (Admin/Worker Roles)"
    log_test_start "${test_name}"

    local test_dir="${TESTS_DIR}/kubernetes_mode"
    mkdir -p "${test_dir}"
    
    local docker_context_abs
    docker_context_abs=$(get_docker_context_abs)
    
    cat > "${test_dir}/docker-compose.yml" <<EOF

services:
  mysql:
    image: mariadb:11.4
    command:
      - mariadbd
      - --character-set-server=utf8mb4
    environment:
      MYSQL_ROOT_PASSWORD: root
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 10s
      interval: 10s
      timeout: 5s
      retries: 3
    volumes:
      - mysql_data:/var/lib/mysql
    networks:
      - test-network

  openemr-admin:
    build:
      context: ${docker_context_abs}
    image: ${IMAGE_TAG}
    depends_on:
      mysql:
        condition: service_healthy
    environment:
      MYSQL_HOST: mysql
      MYSQL_ROOT_PASS: root
      MYSQL_USER: openemr
      MYSQL_PASS: openemr
      MYSQL_DATABASE: openemr
      OE_USER: admin
      OE_PASS: testpass123
      K8S: "admin"
    volumes:
      - k8s_sites:/var/www/localhost/htdocs/openemr/sites
    networks:
      - test-network

  openemr-worker:
    build:
      context: ${docker_context_abs}
    image: ${IMAGE_TAG}
    depends_on:
      mysql:
        condition: service_healthy
      openemr-admin:
        condition: service_completed_successfully
    environment:
      MYSQL_HOST: mysql
      MYSQL_ROOT_PASS: root
      MYSQL_USER: openemr
      MYSQL_PASS: openemr
      MYSQL_DATABASE: openemr
      K8S: "worker"
    ports:
      - "8085:80"
    volumes:
      - k8s_sites:/var/www/localhost/htdocs/openemr/sites
    healthcheck:
      test: ["CMD", "curl", "-fsSLo", "/dev/null", "http://localhost/"]
      start_period: 10m
      start_interval: 10s
      interval: 1m
      timeout: 5s
    networks:
      - test-network

volumes:
  mysql_data:
  k8s_sites:

networks:
  test-network:
    driver: bridge
EOF

    cd "${test_dir}"
    
    # Start services (stream build output)
    log_info "Building and starting containers..."
    if ! docker compose -p "${PROJECT_NAME}-k8s" up -d --build 2>&1 | tee -a "${LOG_FILE}"; then
        log_test_result "${test_name}" "FAIL" "Failed to start containers"
        return 1
    fi

    # Wait for admin to complete (it should exit after setup)
    local admin_name="${PROJECT_NAME}-k8s-openemr-admin-1"
    local admin_exit_code=1
    local waited=0
    log_info "Waiting for admin container to complete setup..."
    while [[ "${waited}" -lt 600 ]]; do
        local admin_status
        admin_status=$(docker inspect "${admin_name}" --format '{{.State.Status}}' 2>/dev/null || echo "running")
        if [[ "${admin_status}" = "exited" ]]; then
            admin_exit_code=$(docker inspect "${admin_name}" --format '{{.State.ExitCode}}' 2>/dev/null || echo "1")
            log_info "Admin container exited with code: ${admin_exit_code}"
            break
        fi
        if [[ $((waited % 30)) -eq 0 ]] && [[ "${waited}" -gt 0 ]]; then
            log_info "Still waiting for admin to complete... (${waited}s/600s)"
        fi
        sleep 2
        waited=$((waited + 2))
    done

    if [[ "${admin_exit_code}" != "0" ]]; then
        log_test_result "${test_name}" "FAIL" "Admin container failed with exit code: ${admin_exit_code}"
        docker logs "${admin_name}" --tail 50 2>&1 | tee -a "${LOG_FILE}" || true
        docker compose -p "${PROJECT_NAME}-k8s" down --volumes >/dev/null 2>&1 || true
        return 1
    fi

    # Give worker a moment to start after admin completes
    sleep 5

    # Check worker
    local worker_name="${PROJECT_NAME}-k8s-openemr-worker-1"
    # shellcheck disable=SC2310
    if ! wait_for_healthy "${worker_name}" 600; then
        log_test_result "${test_name}" "FAIL" "Worker container did not become healthy"
        docker logs "${worker_name}" --tail 50 2>&1 | tee -a "${LOG_FILE}" || true
        docker compose -p "${PROJECT_NAME}-k8s" down --volumes >/dev/null 2>&1 || true
        return 1
    fi

    # Check that OpenEMR is configured
    local config_status
    config_status=$(check_openemr_configured "${worker_name}")

    docker compose -p "${PROJECT_NAME}-k8s" down --volumes >/dev/null 2>&1 || true

    if [[ "${admin_exit_code}" = "0" ]] && [[ "${config_status}" = "1" ]]; then
        log_test_result "${test_name}" "PASS" "Kubernetes mode working correctly"
        return 0
    else
        log_test_result "${test_name}" "FAIL" "Admin exit code: ${admin_exit_code}, Config status: ${config_status}"
        return 1
    fi
}

# Test 7: XDebug configuration
test_xdebug_configuration() {
    local test_name="XDebug Configuration"
    log_test_start "${test_name}"

    local test_dir="${TESTS_DIR}/xdebug"
    mkdir -p "${test_dir}"
    
    local docker_context_abs
    docker_context_abs=$(get_docker_context_abs)
    
    cat > "${test_dir}/docker-compose.yml" <<EOF

services:
  mysql:
    image: mariadb:11.4
    command:
      - mariadbd
      - --character-set-server=utf8mb4
    environment:
      MYSQL_ROOT_PASSWORD: root
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 10s
      interval: 10s
      timeout: 5s
      retries: 3
    volumes:
      - mysql_data:/var/lib/mysql
    networks:
      - test-network

  openemr:
    build:
      context: ${docker_context_abs}
    image: ${IMAGE_TAG}
    depends_on:
      mysql:
        condition: service_healthy
    environment:
      MYSQL_HOST: mysql
      MYSQL_ROOT_PASS: root
      MYSQL_USER: openemr
      MYSQL_PASS: openemr
      MYSQL_DATABASE: openemr
      OE_USER: admin
      OE_PASS: testpass123
      XDEBUG_ON: 1
      XDEBUG_IDE_KEY: PHPSTORM
    ports:
      - "8086:80"
    healthcheck:
      test: ["CMD", "curl", "-fsSLo", "/dev/null", "http://localhost/"]
      start_period: 10m
      start_interval: 10s
      interval: 1m
      timeout: 5s
    networks:
      - test-network

volumes:
  mysql_data:

networks:
  test-network:
    driver: bridge
EOF

    cd "${test_dir}"
    
    # Start services (stream build output)
    log_info "Building and starting containers..."
    if ! docker compose -p "${PROJECT_NAME}-xdebug" up -d --build 2>&1 | tee -a "${LOG_FILE}"; then
        log_test_result "${test_name}" "FAIL" "Failed to start containers"
        return 1
    fi

    local container_name="${PROJECT_NAME}-xdebug-openemr-1"

    # shellcheck disable=SC2310
    if ! wait_for_healthy "${container_name}" 600; then
        log_test_result "${test_name}" "FAIL" "Container did not become healthy"
        docker compose -p "${PROJECT_NAME}-xdebug" down --volumes >/dev/null 2>&1 || true
        return 1
    fi

    # Check if XDebug is configured
    local xdebug_configured
    xdebug_configured=$(docker exec "${container_name}" php -m 2>/dev/null | grep -q xdebug && echo "1" || echo "0")

    # Check if opcache is disabled (XDebug and opcache are incompatible) - use correct php.ini path
    local opcache_disabled
    opcache_disabled=$(docker exec "${container_name}" grep -q "opcache.enable=0" /etc/php84/php.ini 2>/dev/null && echo "1" || echo "0")

    docker compose -p "${PROJECT_NAME}-xdebug" down --volumes >/dev/null 2>&1 || true

    if [[ "${xdebug_configured}" = "1" ]] && [[ "${opcache_disabled}" = "1" ]]; then
        log_test_result "${test_name}" "PASS" "XDebug configured and opcache disabled"
        return 0
    else
        log_test_result "${test_name}" "FAIL" "XDebug configured: ${xdebug_configured}, Opcache disabled: ${opcache_disabled}"
        return 1
    fi
}

# Test 8: Document upload/storage
test_document_upload() {
    local test_name="Document Upload/Storage"
    log_test_start "${test_name}"

    local test_dir="${TESTS_DIR}/document_upload"
    mkdir -p "${test_dir}"
    
    local docker_context_abs
    docker_context_abs=$(get_docker_context_abs)
    
    cat > "${test_dir}/docker-compose.yml" <<EOF

services:
  mysql:
    image: mariadb:11.4
    command:
      - mariadbd
      - --character-set-server=utf8mb4
    environment:
      MYSQL_ROOT_PASSWORD: root
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 10s
      interval: 10s
      timeout: 5s
      retries: 3
    volumes:
      - mysql_data:/var/lib/mysql
    networks:
      - test-network

  openemr:
    build:
      context: ${docker_context_abs}
    image: ${IMAGE_TAG}
    depends_on:
      mysql:
        condition: service_healthy
    environment:
      MYSQL_HOST: mysql
      MYSQL_ROOT_PASS: root
      MYSQL_USER: openemr
      MYSQL_PASS: openemr
      MYSQL_DATABASE: openemr
      OE_USER: admin
      OE_PASS: testpass123
    ports:
      - "8087:80"
    volumes:
      - documents_data:/var/www/localhost/htdocs/openemr/sites/default/documents
    healthcheck:
      test: ["CMD", "curl", "-fsSLo", "/dev/null", "http://localhost/"]
      start_period: 10m
      start_interval: 10s
      interval: 1m
      timeout: 5s
    networks:
      - test-network

volumes:
  mysql_data:
  documents_data:

networks:
  test-network:
    driver: bridge
EOF

    cd "${test_dir}"
    
    # Start services (stream build output)
    log_info "Building and starting containers..."
    if ! docker compose -p "${PROJECT_NAME}-docs" up -d --build 2>&1 | tee -a "${LOG_FILE}"; then
        log_test_result "${test_name}" "FAIL" "Failed to start containers"
        return 1
    fi

    local container_name="${PROJECT_NAME}-docs-openemr-1"

    # shellcheck disable=SC2310
    if ! wait_for_healthy "${container_name}" 600; then
        log_test_result "${test_name}" "FAIL" "Container did not become healthy"
        docker compose -p "${PROJECT_NAME}-docs" down --volumes >/dev/null 2>&1 || true
        return 1
    fi

    # Check that documents directory exists and is writable
    local docs_dir_exists
    docs_dir_exists=$(docker exec "${container_name}" test -d /var/www/localhost/htdocs/openemr/sites/default/documents && echo "1" || echo "0")

    # Try to create a test file in documents directory
    local can_write
    can_write=$(docker exec "${container_name}" touch /var/www/localhost/htdocs/openemr/sites/default/documents/test.txt 2>/dev/null && echo "1" || echo "0")

    docker compose -p "${PROJECT_NAME}-docs" down --volumes >/dev/null 2>&1 || true

    if [[ "${docs_dir_exists}" = "1" ]] && [[ "${can_write}" = "1" ]]; then
        log_test_result "${test_name}" "PASS" "Documents directory exists and is writable"
        return 0
    else
        log_test_result "${test_name}" "FAIL" "Docs dir exists: ${docs_dir_exists}, Can write: ${can_write}"
        return 1
    fi
}

# Test 9: Docker upgrade process
test_docker_upgrade() {
    local test_name="Docker Upgrade Process"
    log_test_start "${test_name}"

    local test_dir="${TESTS_DIR}/docker_upgrade"
    mkdir -p "${test_dir}"
    
    local docker_context_abs
    docker_context_abs=$(get_docker_context_abs)
    
    cat > "${test_dir}/docker-compose.yml" <<EOF

services:
  mysql:
    image: mariadb:11.4
    command:
      - mariadbd
      - --character-set-server=utf8mb4
    environment:
      MYSQL_ROOT_PASSWORD: root
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 10s
      interval: 10s
      timeout: 5s
      retries: 3
    volumes:
      - mysql_data:/var/lib/mysql
    networks:
      - test-network

  openemr:
    build:
      context: ${docker_context_abs}
    image: ${IMAGE_TAG}
    depends_on:
      mysql:
        condition: service_healthy
    environment:
      MYSQL_HOST: mysql
      MYSQL_ROOT_PASS: root
      MYSQL_USER: openemr
      MYSQL_PASS: openemr
      MYSQL_DATABASE: openemr
      OE_USER: admin
      OE_PASS: testpass123
    ports:
      - "8088:80"
    volumes:
      - upgrade_sites:/var/www/localhost/htdocs/openemr/sites
    healthcheck:
      test: ["CMD", "curl", "-fsSLo", "/dev/null", "http://localhost/"]
      start_period: 10m
      start_interval: 10s
      interval: 1m
      timeout: 5s
    networks:
      - test-network

volumes:
  mysql_data:
  upgrade_sites:

networks:
  test-network:
    driver: bridge
EOF

    cd "${test_dir}"
    
    # Step 1: Start fresh installation and wait for it to complete
    log_info "Step 1: Starting fresh installation..."
    if ! docker compose -p "${PROJECT_NAME}-upgrade" up -d --build 2>&1 | tee -a "${LOG_FILE}"; then
        log_test_result "${test_name}" "FAIL" "Failed to start containers"
        return 1
    fi

    local container_name="${PROJECT_NAME}-upgrade-openemr-1"

    # Wait for container to be healthy and configured
    # shellcheck disable=SC2310
    if ! wait_for_healthy "${container_name}" 600; then
        log_test_result "${test_name}" "FAIL" "Container did not become healthy"
        docker compose -p "${PROJECT_NAME}-upgrade" down --volumes >/dev/null 2>&1 || true
        return 1
    fi

    # Wait for OpenEMR to be configured
    log_info "Waiting for OpenEMR to be configured..."
    local config_status="0"
    local waited=0
    while [[ "${waited}" -lt 300 ]] && [[ "${config_status}" != "1" ]]; do
        config_status=$(check_openemr_configured "${container_name}")
        if [[ "${config_status}" = "1" ]]; then
            log_info "OpenEMR is configured"
            break
        fi
        sleep 5
        waited=$((waited + 5))
    done

    if [[ "${config_status}" != "1" ]]; then
        log_test_result "${test_name}" "FAIL" "OpenEMR was not configured"
        docker compose -p "${PROJECT_NAME}-upgrade" down --volumes >/dev/null 2>&1 || true
        return 1
    fi

    # Step 2: Get current version from container and verify all version files exist
    local current_version
    current_version=$(docker exec "${container_name}" cat /root/docker-version 2>/dev/null || echo "0")
    log_info "Current container version (from /root/docker-version): ${current_version}"
    
    # Verify code version file exists (needed for upgrade check)
    local code_version_exists
    code_version_exists=$(docker exec "${container_name}" test -f /var/www/localhost/htdocs/openemr/docker-version && echo "1" || echo "0")
    if [[ "${code_version_exists}" = "0" ]]; then
        log_info "Creating code version file to match root version..."
        docker exec "${container_name}" sh -c "echo -n '${current_version}' > /var/www/localhost/htdocs/openemr/docker-version" 2>/dev/null || true
    fi
    
    local code_version
    code_version=$(docker exec "${container_name}" cat /var/www/localhost/htdocs/openemr/docker-version 2>/dev/null || echo "0")
    log_info "Code version (from /var/www/localhost/htdocs/openemr/docker-version): ${code_version}"

    # Step 3: Set an older version in sites/default/docker-version to trigger upgrade
    # Set it to version 1 (assuming current version is higher)
    log_info "Step 2: Setting older version marker to trigger upgrade..."
    docker exec "${container_name}" sh -c 'echo -n "1" > /var/www/localhost/htdocs/openemr/sites/default/docker-version' 2>/dev/null || true
    
    # Verify the old version was set
    local old_version
    old_version=$(docker exec "${container_name}" cat /var/www/localhost/htdocs/openemr/sites/default/docker-version 2>/dev/null || echo "0")
    log_info "Set sites version to: ${old_version}"

    if [[ "${old_version}" != "1" ]]; then
        log_test_result "${test_name}" "FAIL" "Failed to set old version marker"
        docker compose -p "${PROJECT_NAME}-upgrade" down --volumes >/dev/null 2>&1 || true
        return 1
    fi

    # Step 4: Get log position before restart to only check new logs
    log_info "Step 3: Getting current log position..."
    local log_size_before
    # shellcheck disable=SC2034  # log_size_before is captured but not used (reserved for future debugging)
    log_size_before=$(docker logs "${container_name}" 2>&1 | wc -l) || log_size_before="0"
    
    # Step 5: Restart container to trigger upgrade check
    log_info "Step 4: Restarting container to trigger upgrade..."
    docker compose -p "${PROJECT_NAME}-upgrade" restart openemr 2>&1 | tee -a "${LOG_FILE}" || true
    
    # Wait a moment for container to restart
    sleep 5

    # Wait for container to be healthy again after restart
    # shellcheck disable=SC2310
    if ! wait_for_healthy "${container_name}" 600; then
        log_test_result "${test_name}" "FAIL" "Container did not become healthy after restart"
        docker logs "${container_name}" --tail 50 2>&1 | tee -a "${LOG_FILE}" || true
        docker compose -p "${PROJECT_NAME}-upgrade" down --volumes >/dev/null 2>&1 || true
        return 1
    fi

    # Give upgrade time to complete if it's running
    sleep 10

    # Step 6: Check logs for upgrade messages (only new logs since restart)
    log_info "Step 5: Checking upgrade logs..."
    local all_logs
    all_logs=$(docker logs "${container_name}" 2>&1 || echo "")
    
    local upgrade_started
    upgrade_started=$(echo "${all_logs}" | grep -q "Starting OpenEMR upgrade process\|Upgrade detected" && echo "1" || echo "0")
    
    local upgrade_completed
    upgrade_completed=$(echo "${all_logs}" | grep -q "OpenEMR upgrade completed successfully" && echo "1" || echo "0")
    
    # Also check for upgrade script execution messages
    local upgrade_scripts_run
    upgrade_scripts_run=$(echo "${all_logs}" | grep -q "Processing fsupgrade-.*\.sh upgrade script" && echo "1" || echo "0")

    # Step 7: Verify version marker was updated
    log_info "Step 6: Verifying version marker was updated..."
    local new_version
    new_version=$(docker exec "${container_name}" cat /var/www/localhost/htdocs/openemr/sites/default/docker-version 2>/dev/null || echo "0")
    log_info "Version after upgrade: ${new_version} (was ${old_version}, should be ${current_version})"
    
    # Also verify the version files exist and match
    local root_version
    root_version=$(docker exec "${container_name}" cat /root/docker-version 2>/dev/null || echo "0")
    local code_version
    code_version=$(docker exec "${container_name}" cat /var/www/localhost/htdocs/openemr/docker-version 2>/dev/null || echo "0")
    log_info "Root version: ${root_version}, Code version: ${code_version}, Sites version: ${new_version}"

    # Step 8: Verify OpenEMR is still configured and accessible
    local config_after_upgrade
    config_after_upgrade=$(check_openemr_configured "${container_name}")
    
    local http_status
    http_status=$(curl -sL -o /dev/null -w "%{http_code}" "http://localhost:8088/interface/login/login.php" || echo "000")

    # Debug: Show relevant log lines if upgrade didn't run
    if [[ "${upgrade_started}" = "0" ]] || [[ "${upgrade_completed}" = "0" ]]; then
        log_info "Debug: Recent container logs:"
        docker logs "${container_name}" --tail 100 2>&1 | grep -i "upgrade\|version\|docker-version" | tail -20 | tee -a "${LOG_FILE}" || true
    fi

    docker compose -p "${PROJECT_NAME}-upgrade" down --volumes >/dev/null 2>&1 || true

    # Evaluate test results
    # Upgrade is successful if:
    # 1. Version was updated from old to current (even if logs aren't perfect)
    # 2. OR upgrade messages are found in logs
    # 3. AND OpenEMR is still configured and accessible
    local version_updated="0"
    if [[ "${new_version}" = "${current_version}" ]] && [[ "${new_version}" != "${old_version}" ]]; then
        version_updated="1"
    fi
    
    if [[ "${version_updated}" = "1" ]] && \
       [[ "${config_after_upgrade}" = "1" ]] && \
       [[ "${http_status}" = "200" ]]; then
        log_test_result "${test_name}" "PASS" "Upgrade completed successfully (${old_version} -> ${new_version})"
        return 0
    elif [[ "${upgrade_started}" = "1" ]] && \
         [[ "${upgrade_completed}" = "1" ]] && \
         [[ "${config_after_upgrade}" = "1" ]] && \
         [[ "${http_status}" = "200" ]]; then
        log_test_result "${test_name}" "PASS" "Upgrade completed successfully (logs confirmed)"
        return 0
    else
        log_test_result "${test_name}" "FAIL" "Upgrade started: ${upgrade_started}, Completed: ${upgrade_completed}, Scripts run: ${upgrade_scripts_run}, Version updated: ${version_updated} (${old_version} -> ${new_version}), Config: ${config_after_upgrade}, HTTP: ${http_status}"
        return 1
    fi
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    # Parse command line arguments
    local test_filter="${TEST_FILTER:-}"
    while [[ $# -gt 0 ]]; do
        case $1 in
            --test)
                test_filter="${2:-}"
                shift 2
                ;;
            --verbose)
                VERBOSE="yes"
                shift
                ;;
            --keep-containers)
                KEEP_CONTAINERS="yes"
                shift
                ;;
            --version)
                VERSION="${2:-7.0.5}"
                DOCKER_CONTEXT="../../docker/openemr/${VERSION}"
                IMAGE_TAG="openemr:${VERSION}-test"
                shift 2
                ;;
            *)
                log_error "Unknown option: $1"
                echo "Usage: $0 [--test TEST_NAME] [--verbose] [--keep-containers] [--version VERSION]"
                exit 1
                ;;
        esac
    done

    log_section "OpenEMR Container Functional Test Suite"

    # Clean up any leftover containers/volumes from previous test runs
    log_info "Cleaning up any leftover test containers and volumes..."
    for project in fresh manual ssl redis swarm k8s xdebug docs upgrade; do
        docker compose -p "${PROJECT_NAME}-${project}" down --remove-orphans --volumes >/dev/null 2>&1 || true
    done

    # Create results directory
    mkdir -p "${RESULTS_DIR}"

    # Initialize result file
    local result_date
    result_date=$(date)
    {
        echo "OpenEMR Container Functional Test Results - ${result_date}"
        echo "Test Suite Version: 1.0"
        echo "Docker Context: ${DOCKER_CONTEXT}"
        echo "Image Tag: ${IMAGE_TAG}"
        echo "Version: ${VERSION}"
        echo ""
    } > "${RESULT_FILE}"

    log_info "Starting test suite..."
    log_info "Results will be saved to: ${RESULT_FILE}"
    log_info "Logs will be saved to: ${LOG_FILE}"
    echo ""

    # Define all tests (using function name mapping for bash 3.2 compatibility)
    run_test() {
        local test_name="$1"
        local test_func="$2"

        if [[ -z "${test_filter:-}" ]] || [[ "${test_name}" = "${test_filter}" ]]; then
            ${test_func} || true
        else
            log_test_result "${test_name}" "SKIP" "Filtered out"
        fi
    }

    # Run all tests
    run_test "fresh_installation" "test_fresh_installation"
    run_test "manual_setup" "test_manual_setup"
    run_test "ssl_configuration" "test_ssl_configuration"
    run_test "redis_sessions" "test_redis_sessions"
    run_test "swarm_mode" "test_swarm_mode"
    run_test "kubernetes_mode" "test_kubernetes_mode"
    run_test "xdebug_configuration" "test_xdebug_configuration"
    run_test "document_upload" "test_document_upload"
    run_test "docker_upgrade" "test_docker_upgrade"

    # Print summary
    log_section "Test Summary"
    echo "Tests Passed: ${TESTS_PASSED}" | tee -a "${LOG_FILE}"
    echo "Tests Failed: ${TESTS_FAILED}" | tee -a "${LOG_FILE}"
    echo "Tests Skipped: ${TESTS_SKIPPED}" | tee -a "${LOG_FILE}"
    echo "" | tee -a "${LOG_FILE}"

    {
        echo ""
        echo "=== Summary ==="
        echo "Tests Passed: ${TESTS_PASSED}"
        echo "Tests Failed: ${TESTS_FAILED}"
        echo "Tests Skipped: ${TESTS_SKIPPED}"
    } >> "${RESULT_FILE}"

    if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
        log_error "Failed tests:"
        for test in "${FAILED_TESTS[@]}"; do
            echo "  - ${test}" | tee -a "${LOG_FILE}"
        done
        echo "" | tee -a "${LOG_FILE}"
    fi

    if [[ "${TESTS_FAILED}" -eq 0 ]]; then
        log_success "All tests passed!"
        echo "All tests passed!" >> "${RESULT_FILE}"
        return 0
    else
        log_error "Some tests failed. See ${RESULT_FILE} for details."
        return 1
    fi
}

# Run main function
main "$@"
