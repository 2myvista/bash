#!/bin/bash

git_sync() {
    local branch

    branch=$(git rev-parse --abbrev-ref HEAD) || return 1

    if [ "$branch" = "HEAD" ]; then
        echo "❌ Detached HEAD — неопределенная ветка in $(pwd)"
        return 1
    fi

    echo "[git] syncing $branch in $(pwd)"

    git fetch origin || return 1

    if ! git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
        echo "❌ Remote branch origin/$branch does not exist"
        return 1
    fi

    git checkout "$branch" || return 1
    git reset --hard "origin/$branch" || return 1
    echo "[git] synced $branch"
}

# deploy changes
deploy() {
    local process_name="$1"

    if [ -z "$process_name" ]; then
        echo "Для запуска используйте deploy <process_name>"
        return 1
    fi

    # check process id
    local process_id=$(pm2 ls | grep "│ $process_name " | awk '{print $2}')
    if [ -z "$process_id" ]; then
        pm2 ls
        echo -e "\n"
        echo "❌❌ Process '$process_name' not found"
        return 1
    fi

    cd ~/pim/backend || return 1
    git_sync || return 1

    cd ~/pim/frontend || return 1
    git_sync || return 1

    echo "Clearing cache at backend"
     ~/pim/backend/bin/console cache:clear
    echo "Deploying process: $process_name (ID: $process_id)"

    #pm2 stop "$process_id" && npm run build && pm2 start "$process_id"
    if ! pm2 stop "$process_id"; then
        echo "Warning: Failed to stop process (might already be stopped)"
    fi

    if npm run build; then
        echo "Build successful, starting...."
        pm2 start "$process_id"
    else
        echo "❌❌ Build failed! "
        echo "❌❌ Service is DOWN. Manual intervention required"
        return 1
    fi
}

deploy "$@"