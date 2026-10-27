#!/usr/bin/env bash
# purpose: batch-safe attribute delete wrapper
# env: all
# usage: deleteattrs.sh [--execute] [--file FILE] [ATTRIBUTE_CODE ...]

set -uo pipefail

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
ATTR_FILE=""
LOG_FILE="${DELETEATTR_LOG:-}"
DELETEATTR_SCRIPT="${DELETEATTR_SCRIPT:-}"

WORKER_SERVICES="${WORKER_SERVICES:-crond php-messenger-import php-messenger-export php-messenger-segment php-messenger-completeness php-messenger-notification php-messenger-batch_action}"
LOCAL_WORKER_STOP_CMD="${LOCAL_WORKER_STOP_CMD:-supervisorctl stop all}"
LOCAL_WORKER_START_CMD="${LOCAL_WORKER_START_CMD:-supervisorctl start all}"

usage() {
    cat <<'USAGE'
Usage:
  deleteattrs.sh ATTRIBUTE_CODE [ATTRIBUTE_CODE ...]
  deleteattrs.sh --execute ATTRIBUTE_CODE [ATTRIBUTE_CODE ...]
  deleteattrs.sh --file /path/to/attributes.txt
  deleteattrs.sh --execute --file /path/to/attributes.txt

Options:
  --project-dir DIR      Docker compose dir or app dir. Can also use ERGONODE_DOCKER_DIR.
  --app-dir DIR          Directory containing bin/console for non-Docker mode. Can also use ERGONODE_APP_DIR.
  --env ENV              Symfony env. Default: dev. Can also use APP_ENV.
  --compose-file FILE    Compose file path. Default: PROJECT_DIR/docker-compose.yml.
  --file FILE            File with one attribute code per line. Empty lines and # comments are ignored.
  --log-file FILE        Batch log file. Default: DELETEATTR_LOG or APP_DIR/var/log/deleteattr.log.
  --execute              Apply deletes. Without it only dry-run reports are shown.
  --migrate              Run ergonode:migrations:migrate before execute.
  --no-stop-workers      Do not stop/start workers around execute.
  -h, --help             Show this help.

Production:
  Always pass --env prod or APP_ENV=prod. Otherwise deletes and aggregate cache clear run in dev env.
USAGE
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

timestamp() {
    date '+%Y-%m-%dT%H:%M:%S%z'
}

log() {
    echo "==> [$(timestamp)] $*"
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
        die "APP_ENV check failed: $env_file must exist and contain APP_ENV before deleteattrs can run."
    fi

    if [[ "$APP_ENV" != "$env_local" ]]; then
        die "APP_ENV mismatch: runtime APP_ENV is \"$APP_ENV\", but $env_file contains APP_ENV=\"$env_local\". deleteattrs will not run."
    fi
}

resolve_default_log_file() {
    if [[ -n "$LOG_FILE" ]]; then
        printf '%s' "$LOG_FILE"
        return 0
    fi

    if [[ -n "$APP_DIR" ]]; then
        printf '%s/var/log/deleteattr.log' "$APP_DIR"
        return 0
    fi

    if [[ -f "$PROJECT_DIR/backend/bin/console" ]]; then
        printf '%s/backend/var/log/deleteattr.log' "$PROJECT_DIR"
        return 0
    fi

    printf '%s/var/log/deleteattr.log' "$PROJECT_DIR"
}

setup_logging() {
    local log_dir

    LOG_FILE="$(resolve_default_log_file)"
    log_dir="$(dirname "$LOG_FILE")"

    mkdir -p "$log_dir" || die "Cannot create log directory: $log_dir"
    touch "$LOG_FILE" || die "Cannot write log file: $LOG_FILE"

    exec > >(tee -a "$LOG_FILE") 2>&1
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

deleteattr_script() {
    if [[ -n "$DELETEATTR_SCRIPT" ]]; then
        printf '%s' "$DELETEATTR_SCRIPT"
        return 0
    fi

    printf '%s/deleteattr.sh' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
}

build_common_deleteattr_args() {
    DELETEATTR_COMMON_ARGS=()

    [[ -n "$PROJECT_DIR" ]] && DELETEATTR_COMMON_ARGS+=(--project-dir "$PROJECT_DIR")
    [[ -n "$APP_DIR" ]] && DELETEATTR_COMMON_ARGS+=(--app-dir "$APP_DIR")
    [[ -n "$COMPOSE_FILE" ]] && DELETEATTR_COMMON_ARGS+=(--compose-file "$COMPOSE_FILE")
    DELETEATTR_COMMON_ARGS+=(--env "$APP_ENV")
}

run_deleteattr_dry_run() {
    local code="$1"

    "$DELETEATTR_SH" "${DELETEATTR_COMMON_ARGS[@]}" "$code"
}

run_deleteattr_execute() {
    local code="$1"

    "$DELETEATTR_SH" "${DELETEATTR_COMMON_ARGS[@]}" "$code" \
        --execute \
        --maintenance-already-enabled \
        --skip-cache-clear
}

read_attribute_file() {
    local line
    local code
    local line_no=0

    [[ -f "$ATTR_FILE" ]] || die "Attribute file does not exist: $ATTR_FILE"

    while IFS= read -r line || [[ -n "$line" ]]; do
        line_no=$((line_no + 1))
        code="${line%%#*}"
        code="$(printf '%s' "$code" | trim_value)"

        [[ -n "$code" ]] || continue

        if [[ "$code" =~ [[:space:]] ]]; then
            die "Invalid attribute code in $ATTR_FILE:$line_no: $code"
        fi

        ATTRIBUTES+=("$code")
    done < "$ATTR_FILE"
}

attributes_label() {
    printf '%s' "${ATTRIBUTES[*]}"
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
        --file)
            [[ $# -ge 2 ]] || die "--file requires a value"
            ATTR_FILE="$2"
            shift 2
            ;;
        --log-file)
            [[ $# -ge 2 ]] || die "--log-file requires a value"
            LOG_FILE="$2"
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

ATTRIBUTES=()
if [[ -n "$ATTR_FILE" ]]; then
    read_attribute_file
fi

if [[ ${#args[@]} -gt 0 ]]; then
    for code in "${args[@]}"; do
        if [[ "$code" =~ [[:space:]] ]]; then
            die "Invalid attribute code argument: $code"
        fi
        ATTRIBUTES+=("$code")
    done
fi

[[ ${#ATTRIBUTES[@]} -gt 0 ]] || {
    usage >&2
    exit 1
}

if [[ -z "$PROJECT_DIR" ]]; then
    PROJECT_DIR="$(pwd)"
fi

[[ -d "$PROJECT_DIR" ]] || die "Project dir does not exist: $PROJECT_DIR"

check_env_local_matches_runtime_env

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

setup_logging

DELETEATTR_SH="$(deleteattr_script)"
[[ -x "$DELETEATTR_SH" ]] || die "deleteattr.sh is not executable: $DELETEATTR_SH"
build_common_deleteattr_args

if [[ "$EXECUTE" -eq 1 && "$APP_ENV_EXPLICIT" -eq 0 ]]; then
    die "Explicit env is required for --execute. Use --env dev, --env prod, or APP_ENV=..."
fi

workers_started=0
maintenance_enabled=0
success_count=0
failed_count=0
skipped_count=0
batch_status=0

cleanup() {
    local exit_code=$?

    if [[ "$maintenance_enabled" -eq 1 ]]; then
        log "Disabling attribute maintenance"
        console ergonode:attribute:rename-maintenance disable || exit_code=1
    fi

    if [[ "$workers_started" -eq 1 ]]; then
        log "Starting workers/scheduler"
        start_workers || exit_code=1
    fi

    exit "$exit_code"
}

log "Batch attribute delete started"
log "Symfony env: $APP_ENV"
log "Log file: $LOG_FILE"
log "Attributes: $(attributes_label)"

if [[ "$EXECUTE" -eq 0 ]]; then
    log "Mode: dry-run"
    for code in "${ATTRIBUTES[@]}"; do
        log "START dry-run: $code"
        if run_deleteattr_dry_run "$code"; then
            log "DRY-RUN OK: $code"
            success_count=$((success_count + 1))
        else
            log "DRY-RUN FAILED: $code"
            failed_count=$((failed_count + 1))
            batch_status=1
        fi
    done

    log "Batch attribute delete dry-run completed: ok=$success_count failed=$failed_count skipped=$skipped_count"
    exit "$batch_status"
fi

trap cleanup EXIT

if [[ "$USE_DOCKER" -eq 1 ]]; then
    log "Mode: Docker compose ($COMPOSE_FILE)"
    log "Checking current containers"
    if ! compose ps; then
        die "Cannot inspect Docker compose services"
    fi
else
    log "Mode: local PHP ($APP_DIR)"
fi

if [[ "$RUN_MIGRATIONS" -eq 1 ]]; then
    log "Running migrations"
    console ergonode:migrations:migrate || die "Migrations failed"
fi

if [[ "$STOP_WORKERS" -eq 1 ]]; then
    log "Stopping workers/scheduler"
    stop_workers || die "Cannot stop workers/scheduler"
    workers_started=1
fi

log "Enabling attribute maintenance"
console ergonode:attribute:rename-maintenance enable --reason "attribute delete batch" || die "Cannot enable attribute maintenance"
maintenance_enabled=1

for code in "${ATTRIBUTES[@]}"; do
    log "START attribute: $code"

    if run_deleteattr_dry_run "$code"; then
        log "DRY-RUN OK: $code"
    else
        log "DRY-RUN FAILED, skipping execute: $code"
        skipped_count=$((skipped_count + 1))
        batch_status=1
        continue
    fi

    if run_deleteattr_execute "$code"; then
        log "EXECUTE OK: $code"
        success_count=$((success_count + 1))
    else
        log "EXECUTE FAILED: $code"
        failed_count=$((failed_count + 1))
        batch_status=1
        continue
    fi
done

log "Clearing aggregate cache"
if ! console cache:pool:clear aggregate.cache; then
    log "AGGREGATE CACHE CLEAR FAILED"
    batch_status=1
fi

log "Batch attribute delete completed: ok=$success_count failed=$failed_count skipped=$skipped_count"

exit "$batch_status"
