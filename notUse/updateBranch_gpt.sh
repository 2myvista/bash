#!/bin/bash
set -u

REPOS=("backend" "frontend" "sync_to_ergonode")
PROTECTED_BRANCHES=("master" "master_dev" "master_com")

print_repo_list() {
    local joined
    joined=$(IFS=' | '; echo "${REPOS[*]}")
    echo "$joined"
}

is_valid_repo() {
    local repo="$1"
    for allowed in "${REPOS[@]}"; do
        if [ "$repo" = "$allowed" ]; then
            return 0
        fi
    done
    return 1
}

select_repo() {
    echo "Выберите репозиторий:"
    select repo in "${REPOS[@]}"; do
        if [ -n "${repo:-}" ]; then
            PATH_NAME="$repo"
            break
        fi
        echo "❌ Неверный выбор. Введите номер из списка."
    done
}

resolve_repo_path() {
    local repo="$1"
    if [ "$repo" = "sync_to_ergonode" ]; then
        echo "$HOME/$repo"
    else
        echo "$HOME/pim/$repo"
    fi
}

check_updates() {
    local branch="$1"
    local local_commit=""
    local remote_commit=""

    if git show-ref --verify --quiet "refs/heads/$branch"; then
        local_commit=$(git rev-parse "$branch" 2>/dev/null)
    fi

    remote_commit=$(git ls-remote origin "refs/heads/$branch" 2>/dev/null | cut -f1)

    if [ -z "$remote_commit" ]; then
        echo "  - $branch: удаленная ветка не найдена"
        return 1
    fi

    if [ -n "$local_commit" ] && [ "$local_commit" = "$remote_commit" ]; then
        echo "  - $branch: нет обновлений (актуальна)"
        return 1
    fi

    if [ -z "$local_commit" ]; then
        echo "  - $branch: локальная ветка отсутствует, будет создана/обновлена"
    else
        echo "  - $branch: есть обновления"
        echo "    Локальный:  $(echo "$local_commit" | cut -c1-7)"
        echo "    Удаленный:  $(echo "$remote_commit" | cut -c1-7)"
    fi
    return 0
}

PATH_NAME="${1:-}"

if [ -z "$PATH_NAME" ]; then
    select_repo
elif ! is_valid_repo "$PATH_NAME"; then
    echo "❌ Укажите корректный репозиторий: $(print_repo_list)"
    exit 1
fi

REPO_PATH=$(resolve_repo_path "$PATH_NAME")

echo "Обновляем $PATH_NAME"

if [ ! -d "$REPO_PATH/.git" ]; then
    echo "❌ Каталог репозитория не найден: $REPO_PATH"
    exit 1
fi

cd "$REPO_PATH" || {
    echo "❌ Не удалось перейти в каталог: $REPO_PATH"
    exit 1
}

current_branch=$(git symbolic-ref --short HEAD 2>/dev/null || true)

if [ -z "$current_branch" ]; then
    echo "❌ Не удалось определить текущую ветку"
    exit 1
fi

for protected in "${PROTECTED_BRANCHES[@]}"; do
    if [ "$current_branch" = "$protected" ]; then
        echo "Ошибка: Вы находитесь в защищенной ветке $current_branch"
        echo "Пожалуйста, переключитесь на другую ветку перед обновлением защищенных веток"
        exit 1
    fi
done

echo "Проверка наличия обновлений в ветках..."
updates_available=false

for branch in "${PROTECTED_BRANCHES[@]}"; do
    if check_updates "$branch"; then
        updates_available=true
    fi
done

if [ "$updates_available" = false ]; then
    echo "Нет обновлений ни в одной из веток"
    exit 0
fi

echo "Обновление веток ${PROTECTED_BRANCHES[*]}..."
fetch_specs=()
for branch in "${PROTECTED_BRANCHES[@]}"; do
    fetch_specs+=("$branch:$branch")
done

if git fetch origin "${fetch_specs[@]}"; then
    echo "Ветки успешно обновлены"
    echo ""
    echo "Текущее состояние:"
    for branch in "${PROTECTED_BRANCHES[@]}"; do
        local_short=$(git rev-parse --short "$branch" 2>/dev/null || echo "нет локальной ветки")
        remote_short=$(git rev-parse --short "origin/$branch" 2>/dev/null || echo "нет удаленной ветки")
        echo "$branch: $local_short -> $remote_short"
    done
else
    echo "Ошибка при обновлении веток"
    exit 1
fi
