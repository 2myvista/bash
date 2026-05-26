#!/usr/bin/env bash

set -Eeuo pipefail

APP_ENV="${APP_ENV:-dev}"
PROJECT_DIR="${ERGONODE_DOCKER_DIR:-}"
COMPOSE_FILE=""
PHP_SERVICE="${PHP_SERVICE:-php}"
RUN_MIGRATIONS=0
EXECUTE=0
STOP_WORKERS=1

WORKER_SERVICES="${WORKER_SERVICES:-crond php-messenger-import php-messenger-export php-messenger-segment php-messenger-completeness php-messenger-notification php-messenger-batch_action}"

usage() {
    cat <<'USAGE'
Usage:
  ergonode-rename-attribute.sh --project-dir /path/to/pim/docker OLD_CODE NEW_CODE
  ergonode-rename-attribute.sh --project-dir /path/to/pim/docker OLD_CODE NEW_CODE --execute

Options:
  --project-dir DIR      Directory containing docker-compose.yml. Can also use ERGONODE_DOCKER_DIR.
  --env ENV              Symfony env. Default: dev. Can also use APP_ENV.
  --compose-file FILE    Compose file path. Default: PROJECT_DIR/docker-compose.yml.
  --execute              Apply rename. Without it only dry-run report is shown.
  --migrate              Run ergonode:migrations:migrate before execute.
  --no-stop-workers      Do not stop/start workers around execute.
  -h, --help             Show this help.

Env overrides:
  ERGONODE_DOCKER_DIR    Default project dir.
  APP_ENV                Default Symfony env.
  PHP_SERVICE            Compose PHP service name. Default: php.
  WORKER_SERVICES        Space-separated services stopped around execute.
USAGE
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

log() {
    echo "==> $*"
}

args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --project-dir)
            [[ $# -ge 2 ]] || die "--project-dir requires a value"
            PROJECT_DIR="$2"
            shift 2
            ;;
        --env)
            [[ $# -ge 2 ]] || die "--env requires a value"
            APP_ENV="$2"
            shift 2
            ;;
        --compose-file)
            [[ $# -ge 2 ]] || die "--compose-file requires a value"
            COMPOSE_FILE="$2"
            shift 2
            ;;
        --execute)
            EXECUTE=1
            shift
            ;;
        --migrate)
            RUN_MIGRATIONS=1
            shift
            ;;
        --no-stop-workers)
            STOP_WORKERS=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            while [[ $# -gt 0 ]]; do
                args+=("$1")
                shift
            done
            ;;
        -*)
            die "Unknown option: $1"
            ;;
        *)
            args+=("$1")
            shift
            ;;
    esac
done

[[ ${#args[@]} -eq 2 ]] || {
    usage >&2
    exit 1
}

OLD_CODE="${args[0]}"
NEW_CODE="${args[1]}"

[[ -n "$PROJECT_DIR" ]] || die "Set --project-dir or ERGONODE_DOCKER_DIR"
[[ -d "$PROJECT_DIR" ]] || die "Project dir does not exist: $PROJECT_DIR"

if [[ -z "$COMPOSE_FILE" ]]; then
    COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
fi

[[ -f "$COMPOSE_FILE" ]] || die "Compose file does not exist: $COMPOSE_FILE"

compose() {
    docker compose --project-directory "$PROJECT_DIR" -f "$COMPOSE_FILE" "$@"
}

console() {
    compose exec -T "$PHP_SERVICE" bin/console "$@" "--env=$APP_ENV"
}

workers_started=0
maintenance_enabled=0

cleanup() {
    local exit_code=$?

    if [[ "$maintenance_enabled" -eq 1 ]]; then
        log "Disabling attribute rename maintenance"
        console ergonode:attribute:rename-maintenance disable || true
    fi

    if [[ "$workers_started" -eq 1 ]]; then
        log "Starting workers/scheduler"
        # shellcheck disable=SC2086
        compose up -d $WORKER_SERVICES || true
    fi

    exit "$exit_code"
}

if [[ "$EXECUTE" -eq 0 ]]; then
    log "Running dry-run for attribute rename: $OLD_CODE -> $NEW_CODE"
    console ergonode:attribute:rename-code "$OLD_CODE" "$NEW_CODE"
    exit 0
fi

trap cleanup EXIT

log "Checking current containers"
compose ps

if [[ "$RUN_MIGRATIONS" -eq 1 ]]; then
    log "Running migrations"
    console ergonode:migrations:migrate
fi

if [[ "$STOP_WORKERS" -eq 1 ]]; then
    log "Stopping workers/scheduler"
    # shellcheck disable=SC2086
    compose stop $WORKER_SERVICES
    workers_started=1
fi

log "Enabling attribute rename maintenance"
console ergonode:attribute:rename-maintenance enable
maintenance_enabled=1

log "Executing attribute rename: $OLD_CODE -> $NEW_CODE"
console ergonode:attribute:rename-code "$OLD_CODE" "$NEW_CODE" --execute

log "Attribute rename completed"
