#!/usr/bin/env bash

set -Eeuo pipefail

APP_ENV_EXPLICIT=0
if [[ -n "${APP_ENV:-}" ]]; then
    APP_ENV_EXPLICIT=1
fi
APP_ENV="${APP_ENV:-dev}"
PROJECT_DIR="${ERGONODE_DOCKER_DIR:-}"
APP_DIR="${ERGONODE_APP_DIR:-}"
COMPOSE_FILE=""
PHP_SERVICE="${PHP_SERVICE:-php}"
RUN_MIGRATIONS=0
EXECUTE=0
STOP_WORKERS=1
USE_DOCKER=0

WORKER_SERVICES="${WORKER_SERVICES:-crond php-messenger-import php-messenger-export php-messenger-segment php-messenger-completeness php-messenger-notification php-messenger-batch_action}"
LOCAL_WORKER_STOP_CMD="${LOCAL_WORKER_STOP_CMD:-supervisorctl stop all}"
LOCAL_WORKER_START_CMD="${LOCAL_WORKER_START_CMD:-supervisorctl start all}"

usage() {
    cat <<'USAGE'
Usage:
  renameattr.sh --project-dir /path/to/pim/docker OLD_CODE NEW_CODE
  renameattr.sh --project-dir /path/to/pim/docker OLD_CODE NEW_CODE --execute
  renameattr.sh --app-dir /path/to/backend OLD_CODE NEW_CODE --execute
  renameattr.sh --app-dir /path/to/backend OLD_CODE NEW_CODE --execute --env prod

Options:
  --project-dir DIR      Docker compose dir or app dir. Can also use ERGONODE_DOCKER_DIR.
  --app-dir DIR          Directory containing bin/console for non-Docker mode. Can also use ERGONODE_APP_DIR.
  --env ENV              Symfony env. Default: dev. Can also use APP_ENV.
  --compose-file FILE    Compose file path. Default: PROJECT_DIR/docker-compose.yml.
  --execute              Apply rename. Without it only dry-run report is shown.
  --migrate              Run ergonode:migrations:migrate before execute.
  --no-stop-workers      Do not stop/start workers around execute.
  -h, --help             Show this help.

Env overrides:
  ERGONODE_DOCKER_DIR    Default project dir.
  ERGONODE_APP_DIR       Default local app dir containing bin/console.
  APP_ENV                Default Symfony env. Defaults to dev; use --env prod or APP_ENV=prod on production.
  PHP_SERVICE            Compose PHP service name. Default: php.
  WORKER_SERVICES        Space-separated services stopped around execute.
  LOCAL_WORKER_STOP_CMD  Non-Docker stop command. Default: supervisorctl stop all.
  LOCAL_WORKER_START_CMD Non-Docker start command. Default: supervisorctl start all.

Production:
  Always pass --env prod or APP_ENV=prod. Otherwise the rename and aggregate cache clear run in dev env.
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
        --app-dir)
            [[ $# -ge 2 ]] || die "--app-dir requires a value"
            APP_DIR="$2"
            shift 2
            ;;
        --env)
            [[ $# -ge 2 ]] || die "--env requires a value"
            APP_ENV="$2"
            APP_ENV_EXPLICIT=1
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

if [[ -z "$PROJECT_DIR" ]]; then
    PROJECT_DIR="$(pwd)"
fi

[[ -d "$PROJECT_DIR" ]] || die "Project dir does not exist: $PROJECT_DIR"

if [[ -z "$COMPOSE_FILE" ]]; then
    COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
fi

if command -v docker >/dev/null 2>&1 && [[ -f "$COMPOSE_FILE" ]]; then
    USE_DOCKER=1
else
    USE_DOCKER=0
fi

if [[ "$USE_DOCKER" -eq 0 ]]; then
    if [[ -z "$APP_DIR" ]]; then
        if [[ -f "$PROJECT_DIR/bin/console" ]]; then
            APP_DIR="$PROJECT_DIR"
        elif [[ -f "$PROJECT_DIR/backend/bin/console" ]]; then
            APP_DIR="$PROJECT_DIR/backend"
        elif [[ -f "$(pwd)/bin/console" ]]; then
            APP_DIR="$(pwd)"
        else
            die "Non-Docker mode requires --app-dir, ERGONODE_APP_DIR, or a project dir containing bin/console"
        fi
    fi

    [[ -d "$APP_DIR" ]] || die "App dir does not exist: $APP_DIR"
    [[ -f "$APP_DIR/bin/console" ]] || die "bin/console not found in app dir: $APP_DIR"
fi

compose() {
    docker compose --project-directory "$PROJECT_DIR" -f "$COMPOSE_FILE" "$@"
}

console() {
    if [[ "$USE_DOCKER" -eq 1 ]]; then
        compose exec -T "$PHP_SERVICE" bin/console "$@" "--env=$APP_ENV"
    else
        (cd "$APP_DIR" && php bin/console "$@" "--env=$APP_ENV")
    fi
}

stop_workers() {
    if [[ "$USE_DOCKER" -eq 1 ]]; then
        # shellcheck disable=SC2086
        compose stop $WORKER_SERVICES
    else
        if [[ -n "$LOCAL_WORKER_STOP_CMD" ]]; then
            sh -c "$LOCAL_WORKER_STOP_CMD"
        fi
    fi
}

start_workers() {
    if [[ "$USE_DOCKER" -eq 1 ]]; then
        # shellcheck disable=SC2086
        compose up -d $WORKER_SERVICES
    else
        if [[ -n "$LOCAL_WORKER_START_CMD" ]]; then
            sh -c "$LOCAL_WORKER_START_CMD"
        fi
    fi
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
        start_workers || true
    fi

    exit "$exit_code"
}

if [[ "$EXECUTE" -eq 0 ]]; then
    log "Running dry-run for attribute rename: $OLD_CODE -> $NEW_CODE"
    log "Symfony env: $APP_ENV"
    console ergonode:attribute:rename-code "$OLD_CODE" "$NEW_CODE"
    exit 0
fi

if [[ "$APP_ENV_EXPLICIT" -eq 0 ]]; then
    die "Explicit env is required for --execute. Use --env dev, --env prod, or APP_ENV=..."
fi

trap cleanup EXIT

if [[ "$USE_DOCKER" -eq 1 ]]; then
    log "Mode: Docker compose ($COMPOSE_FILE)"
    log "Symfony env: $APP_ENV"
    log "Checking current containers"
    compose ps
else
    log "Mode: local PHP ($APP_DIR)"
    log "Symfony env: $APP_ENV"
fi

if [[ "$RUN_MIGRATIONS" -eq 1 ]]; then
    log "Running migrations"
    console ergonode:migrations:migrate
fi

if [[ "$STOP_WORKERS" -eq 1 ]]; then
    log "Stopping workers/scheduler"
    stop_workers
    workers_started=1
fi

log "Enabling attribute rename maintenance"
console ergonode:attribute:rename-maintenance enable --reason "attribute rename"
maintenance_enabled=1

log "Executing attribute rename: $OLD_CODE -> $NEW_CODE"
console ergonode:attribute:rename-code "$OLD_CODE" "$NEW_CODE" --execute

log "Clearing aggregate cache"
console cache:pool:clear aggregate.cache

log "Attribute rename completed"
