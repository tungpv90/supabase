#!/bin/sh

set -eu

APP_DIR="${APP_DIR:-/opt/supabase}"
DOMAIN="${DOMAIN:?DOMAIN is required}"
GATEWAY_PORT="${GATEWAY_PORT:-18000}"
STUDIO_IMAGE="${STUDIO_IMAGE:-}"
GHCR_USER="${GHCR_USER:-}"

log() {
    printf '[deploy] %s\n' "$*"
}

die() {
    printf '[deploy] ERROR: %s\n' "$*" >&2
    exit 1
}

read_env() {
    grep "^$1=" .env 2>/dev/null | head -n1 | cut -d= -f2- || true
}

set_env() {
    key="$1"
    value=$(printf '%s' "$2" | sed -e 's/[|&\\]/\\&/g')
    if grep -q "^$key=" .env; then
        sed -i -e "s|^$key=.*$|$key=$value|" .env
    else
        printf '%s=%s\n' "$key" "$2" >> .env
    fi
}

command -v docker >/dev/null 2>&1 || die "docker is not installed on this server"
docker compose version >/dev/null 2>&1 || die "docker compose plugin is not installed on this server"

cd "$APP_DIR"
[ -f docker-compose.yml ] || die "docker-compose.yml not found in $APP_DIR"

if [ ! -f .env ]; then
    log "First deploy: creating .env with fresh secrets"
    cp .env.example .env
    chmod 600 .env
    sh utils/generate-keys.sh --update-env >/dev/null
    sh utils/add-new-auth-keys.sh --update-env >/dev/null
    rm -f .env.old
    set_env SUPABASE_PUBLIC_URL "https://$DOMAIN"
    set_env API_EXTERNAL_URL "https://$DOMAIN/auth/v1"
    set_env SITE_URL "https://$DOMAIN"
    set_env POOLER_TENANT_ID "$(openssl rand -hex 8)"
    log "Secrets written to $APP_DIR/.env (view them with: sh run.sh secrets)"
fi

set_env API_GW_HTTP_PORT "127.0.0.1:${GATEWAY_PORT}"
set_env KONG_HTTP_PORT "127.0.0.1:${GATEWAY_PORT}"
sh run.sh config remove caddy >/dev/null 2>&1 || true

if [ -n "$STUDIO_IMAGE" ]; then
    log "Using Studio image $STUDIO_IMAGE"
    set_env STUDIO_IMAGE "$STUDIO_IMAGE"
    sh run.sh config add studio-image >/dev/null
fi

if [ -n "$GHCR_USER" ]; then
    DOCKER_CONFIG=$(mktemp -d)
    export DOCKER_CONFIG
    trap 'rm -rf "$DOCKER_CONFIG"' EXIT
    docker login ghcr.io -u "$GHCR_USER" --password-stdin >/dev/null || die "registry login failed"
fi

log "Active compose files: $(read_env COMPOSE_FILE)"

log "Pulling images"
docker compose pull --quiet

log "Starting stack"
docker compose up -d --remove-orphans --wait --wait-timeout 600

log "Pruning dangling images"
docker image prune -f >/dev/null

docker compose ps --format 'table {{.Service}}\t{{.Status}}'
log "Done"
