#!/usr/bin/env bash
# purpose: safe attribute delete wrapper
# env: all
# usage: deleteattr.sh ATTRIBUTE_CODE [--execute] [--env dev|prod]

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
ATTRIBUTE_ID=""

WORKER_SERVICES="${WORKER_SERVICES:-crond php-messenger-import php-messenger-export php-messenger-segment php-messenger-completeness php-messenger-notification php-messenger-batch_action}"
LOCAL_WORKER_STOP_CMD="${LOCAL_WORKER_STOP_CMD:-supervisorctl stop all}"
LOCAL_WORKER_START_CMD="${LOCAL_WORKER_START_CMD:-supervisorctl start all}"

usage() {
    cat <<'USAGE'
Usage:
  deleteattr.sh --project-dir /path/to/pim/docker ATTRIBUTE_CODE
  deleteattr.sh --project-dir /path/to/pim/docker ATTRIBUTE_CODE --execute
  deleteattr.sh --app-dir /path/to/backend ATTRIBUTE_CODE --execute
  deleteattr.sh --app-dir /path/to/backend ATTRIBUTE_CODE --execute --env prod

Options:
  --project-dir DIR      Docker compose dir or app dir. Can also use ERGONODE_DOCKER_DIR.
  --app-dir DIR          Directory containing bin/console for non-Docker mode. Can also use ERGONODE_APP_DIR.
  --env ENV              Symfony env. Default: dev. Can also use APP_ENV.
  --attribute-id UUID    Expected attribute id passed to delete command.
  --compose-file FILE    Compose file path. Default: PROJECT_DIR/docker-compose.yml.
  --execute              Apply delete. Without it only dry-run report is shown.
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
  Always pass --env prod or APP_ENV=prod. Otherwise delete and aggregate cache clear run in dev env.
USAGE
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

blocked() {
    echo "WARNING: Attribute \"$CODE\" is protected: $*" >&2
    echo "WARNING: deleteattr will not run, even in dry-run mode." >&2
    echo "WARNING: PHP command protection remains active for direct bin/console runs." >&2
    exit 1
}

log() {
    echo "==> $*"
}

trim_value() {
    sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

strip_quotes() {
    local value="$1"

    if [[ "$value" == \"*\" && "$value" == *\" ]]; then
        value="${value:1:${#value}-2}"
    elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
        value="${value:1:${#value}-2}"
    fi

    printf '%s' "$value"
}

read_env_local_app_env() {
    local env_file="$1"
    local line
    local value

    [[ -f "$env_file" ]] || return 1

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^[[:space:]]*APP_ENV[[:space:]]*=(.*)$ ]]; then
            value="${BASH_REMATCH[1]}"
            value="${value%%#*}"
            value="$(printf '%s' "$value" | trim_value)"
            value="$(strip_quotes "$value")"

            [[ -n "$value" ]] || return 1
            printf '%s' "$value"
            return 0
        fi
    done < "$env_file"

    return 1
}

resolve_env_local_path() {
    if [[ -n "$APP_DIR" ]]; then
        printf '%s/.env.local' "$APP_DIR"
        return 0
    fi

    if [[ -f "$PROJECT_DIR/bin/console" ]]; then
        printf '%s/.env.local' "$PROJECT_DIR"
        return 0
    fi

    if [[ -f "$PROJECT_DIR/backend/bin/console" || -f "$PROJECT_DIR/backend/.env.local" ]]; then
        printf '%s/backend/.env.local' "$PROJECT_DIR"
        return 0
    fi

    printf '%s/.env.local' "$PROJECT_DIR"
}

check_env_local_matches_runtime_env() {
    local env_file
    local env_local

    env_file="$(resolve_env_local_path)"
    env_local="$(read_env_local_app_env "$env_file" || true)"

    if [[ -z "$env_local" ]]; then
        die "APP_ENV check failed: $env_file must exist and contain APP_ENV before deleteattr can run."
    fi

    if [[ "$APP_ENV" != "$env_local" ]]; then
        die "APP_ENV mismatch: runtime APP_ENV is \"$APP_ENV\", but $env_file contains APP_ENV=\"$env_local\". deleteattr will not run."
    fi
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
        --attribute-id)
            [[ $# -ge 2 ]] || die "--attribute-id requires a value"
            ATTRIBUTE_ID="$2"
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

[[ ${#args[@]} -eq 1 ]] || {
    usage >&2
    exit 1
}

CODE="${args[0]}"

if [[ -z "$PROJECT_DIR" ]]; then
    PROJECT_DIR="$(pwd)"
fi

[[ -d "$PROJECT_DIR" ]] || die "Project dir does not exist: $PROJECT_DIR"

check_env_local_matches_runtime_env

case "$CODE" in
    esa_*)
        blocked 'code uses protected prefix "esa_"'
        ;;
    bsa_*)
        blocked 'code uses protected prefix "bsa_"'
        ;;
esac

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

add_scan_root() {
    local root="$1"

    [[ -d "$root" ]] || return 0

    for existing in "${SCAN_ROOTS[@]:-}"; do
        [[ "$existing" == "$root" ]] && return 0
    done

    SCAN_ROOTS+=("$root")
}

check_hardcoded_usage() {
    local base_dir
    local parent_dir
    local matches

    SCAN_ROOTS=()

    if [[ -n "$APP_DIR" ]]; then
        add_scan_root "$APP_DIR/config"
        add_scan_root "$APP_DIR/module"
        add_scan_root "$APP_DIR/src"
        add_scan_root "$(dirname "$APP_DIR")/frontend"
    fi

    base_dir="$PROJECT_DIR"
    parent_dir="$(dirname "$base_dir")"
    add_scan_root "$base_dir/config"
    add_scan_root "$base_dir/module"
    add_scan_root "$base_dir/src"
    add_scan_root "$base_dir/backend/config"
    add_scan_root "$base_dir/backend/module"
    add_scan_root "$base_dir/backend/src"
    add_scan_root "$base_dir/frontend"
    add_scan_root "$parent_dir/frontend"

    [[ ${#SCAN_ROOTS[@]} -gt 0 ]] || return 0

    if command -v rg >/dev/null 2>&1; then
        matches="$(
            rg --fixed-strings --line-number "$CODE" "${SCAN_ROOTS[@]}" \
                -g '*.php' -g '*.yaml' -g '*.yml' -g '*.xml' -g '*.json' -g '*.twig' -g '*.js' -g '*.ts' -g '*.vue' \
                -g '!vendor/**' -g '!var/**' -g '!node_modules/**' -g '!.nuxt/**' -g '!dist/**' \
                -g '!**/tests/**' -g '!**/features/**' -g '!**/migrations/**' -g '!**/fixtures/**' \
                2>/dev/null || true
        )"
    else
        matches="$(
            grep -RIn --include='*.php' --include='*.yaml' --include='*.yml' --include='*.xml' --include='*.json' \
                --include='*.twig' --include='*.js' --include='*.ts' --include='*.vue' \
                --exclude-dir='vendor' --exclude-dir='var' --exclude-dir='node_modules' --exclude-dir='.nuxt' \
                --exclude-dir='dist' --exclude-dir='tests' --exclude-dir='features' --exclude-dir='migrations' \
                --exclude-dir='fixtures' -- "$CODE" "${SCAN_ROOTS[@]}" 2>/dev/null || true
        )"
    fi

    if [[ -n "$matches" ]]; then
        echo "WARNING: Attribute \"$CODE\" is protected: code appears in backend/frontend source." >&2
        echo "WARNING: Samples:" >&2
        echo "$matches" | sed -n '1,20p' >&2
        echo "WARNING: deleteattr will not run, even in dry-run mode." >&2
        echo "WARNING: PHP command protection remains active for direct bin/console runs." >&2
        exit 1
    fi
}

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

delete_command() {
    if [[ -n "$ATTRIBUTE_ID" ]]; then
        console ergonode:attribute:delete-code "$CODE" "--attribute-id=$ATTRIBUTE_ID" "$@"
    else
        console ergonode:attribute:delete-code "$CODE" "$@"
    fi
}

check_system_attribute() {
    local app_db
    local postgres_user
    local escaped_code
    local system_flag

    [[ "$USE_DOCKER" -eq 1 ]] || return 0

    app_db="${APP_DB:-ergonode}"
    postgres_user="${POSTGRES_USER:-postgres}"
    escaped_code="${CODE//\'/\'\'}"

    system_flag="$(
        compose exec -T postgres psql -U "$postgres_user" -d "$app_db" -Atc \
            "SELECT COALESCE((SELECT system::text FROM attribute WHERE code = '$escaped_code' LIMIT 1), '')" \
            2>/dev/null || true
    )"

    case "$system_flag" in
        t|true|1)
            blocked 'attribute is marked as system'
            ;;
    esac
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
        log "Disabling attribute maintenance"
        console ergonode:attribute:rename-maintenance disable || true
    fi

    if [[ "$workers_started" -eq 1 ]]; then
        log "Starting workers/scheduler"
        start_workers || true
    fi

    exit "$exit_code"
}

check_hardcoded_usage

if [[ "$EXECUTE" -eq 1 && "$APP_ENV_EXPLICIT" -eq 0 ]]; then
    die "Explicit env is required for --execute. Use --env dev, --env prod, or APP_ENV=..."
fi

check_system_attribute

if [[ "$EXECUTE" -eq 0 ]]; then
    log "Running dry-run for attribute delete: $CODE"
    log "Symfony env: $APP_ENV"
    delete_command
    exit 0
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

log "Enabling attribute maintenance"
console ergonode:attribute:rename-maintenance enable --reason "attribute delete"
maintenance_enabled=1

log "Executing attribute delete: $CODE"
delete_command --execute

log "Clearing aggregate cache"
console cache:pool:clear aggregate.cache

log "Attribute delete completed"
