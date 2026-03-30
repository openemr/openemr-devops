# BATS: 8.1.1 ssl.sh — SSL/TLS configuration

load '../helpers'

setup() {
    SCRIPT_DIR="$(get_script_dir 8.1.1)"
    [[ -n "$SCRIPT_DIR" ]] && [[ -d "$SCRIPT_DIR" ]]
}

@test "8.1.1 ssl.sh: uses set -e" {
    assert_script_contains "${SCRIPT_DIR}/ssl.sh" 'set -e'
}

@test "8.1.1 ssl.sh: creates self-signed cert if missing" {
    assert_script_contains "${SCRIPT_DIR}/ssl.sh" 'selfsigned.key.pem'
    assert_script_contains "${SCRIPT_DIR}/ssl.sh" 'selfsigned.cert.pem'
    assert_script_contains "${SCRIPT_DIR}/ssl.sh" 'openssl req'
}

@test "8.1.1 ssl.sh: configures webserver.cert.pem and webserver.key.pem" {
    assert_script_contains "${SCRIPT_DIR}/ssl.sh" 'webserver.cert.pem'
    assert_script_contains "${SCRIPT_DIR}/ssl.sh" 'webserver.key.pem'
}

@test "8.1.1 ssl.sh: uses docker-selfsigned-configured marker" {
    assert_script_contains "${SCRIPT_DIR}/ssl.sh" 'docker-selfsigned-configured'
}

@test "8.1.1 ssl.sh: Let's Encrypt when DOMAIN set" {
    assert_script_contains "${SCRIPT_DIR}/ssl.sh" 'DOMAIN'
    assert_script_contains "${SCRIPT_DIR}/ssl.sh" 'letsencrypt'
}

@test "8.1.1 ssl.sh: certbot for Let's Encrypt" {
    assert_script_contains "${SCRIPT_DIR}/ssl.sh" 'certbot'
}

@test "8.1.1 ssl.sh: docker-letsencrypt-configured marker" {
    assert_script_contains "${SCRIPT_DIR}/ssl.sh" 'docker-letsencrypt-configured'
}

@test "8.1.1 ssl.sh: cron for renewal when OPERATOR=yes" {
    assert_script_contains "${SCRIPT_DIR}/ssl.sh" 'OPERATOR'
    assert_script_contains "${SCRIPT_DIR}/ssl.sh" 'crond'
}

@test "8.1.1 ssl.sh: httpd for webroot validation" {
    assert_script_contains "${SCRIPT_DIR}/ssl.sh" 'httpd'
}
