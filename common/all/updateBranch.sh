#!/bin/bash
#v_3
# - поиск реп в папке $HOME не глубже 2-го уровня вложенности
# - выбор реп из найденного списка
# - служебные ветки master/master_dev/master_com синхронизируются с origin
# - feature-ветки не трогаются автоматически

clear
repos=()
branches=("master" "master_dev" "master_com")

while IFS= read -r gitdir; do
    repo_path="${gitdir%/.git}"
    repo_name=$(basename "$repo_path")
    repos+=("$repo_name:$repo_path")
done < <(find ~ -maxdepth 3 -type d -name ".git" 2>/dev/null)

if [ ${#repos[@]} -eq 0 ]; then
    echo "❌ Репозитории не найдены"
    exit 1
fi

echo "Доступные репозитории:"
echo

for i in "${!repos[@]}"; do
    name="${repos[$i]%%:*}"
    path="${repos[$i]#*:}"
    echo " $(($i+1)). $name ($path)"
done

echo
echo "  q. Выход"
echo

read -p "Выберите репозиторий (номер): " -n 1 choice
echo

if [ "$choice" = "q" ] || [ "$choice" = "Q" ] || [ "$choice" = "й" ] || [ "$choice" = "Й" ]; then
    echo "Выход"
    exit 0
fi

if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
    echo "❌ Введите номер"
    exit 1
fi

if [ "$choice" -lt 1 ] || [ "$choice" -gt "${#repos[@]}" ]; then
    echo "❌ выберите число в диапазоне 1 - ${#repos[@]}"
    exit 1
fi

selected="${repos[$((choice-1))]}"
repo_path="${selected#*:}"

echo
echo "Выбран $repo_path"
echo

cd "$repo_path" || exit 1

current_branch=$(git symbolic-ref --short HEAD 2>/dev/null)
switched=false

is_service_branch() {
    local branch=$1
    for service_branch in "${branches[@]}"; do
        if [ "$branch" = "$service_branch" ]; then
            return 0
        fi
    done
    return 1
}

restore_branch() {
    if [ "$switched" = true ] && [ -n "$current_branch" ]; then
        echo
        echo "Возвращаемся на ветку: $current_branch"
        git checkout "$current_branch"
    fi
}

short_commit() {
    local ref=$1
    git rev-parse --short "$ref" 2>/dev/null || echo "-"
}

if is_service_branch "$current_branch"; then
    echo "Вы находитесь в служебной ветке $current_branch, временно уходим в detached HEAD"
    echo
    if ! git checkout --detach >/dev/null 2>&1; then
        echo "❌ Не удалось перейти в detached HEAD"
        echo "Проверьте, нет ли незакоммиченных изменений"
        exit 1
    fi
    switched=true
fi

echo "Обновляем информацию об удаленных ветках..."
if ! git fetch origin --prune; then
    echo "❌ Ошибка при git fetch origin --prune"
    restore_branch
    exit 1
fi

echo
echo "Синхронизация служебных веток: ${branches[*]}"

for branch in "${branches[@]}"; do
    if ! git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
        echo "  - $branch: удаленная ветка origin/$branch не найдена, пропускаем"
        continue
    fi

    before=$(short_commit "$branch")
    remote=$(short_commit "origin/$branch")

    if git show-ref --verify --quiet "refs/heads/$branch"; then
        if git branch -f "$branch" "origin/$branch" >/dev/null 2>&1; then
            after=$(short_commit "$branch")
            if [ "$before" = "$after" ]; then
                echo "  - $branch: актуальна ($after)"
            else
                echo "  - $branch: обновлена $before -> $after"
            fi
        else
            echo "  - $branch: ❌ не удалось обновить локальную ветку"
        fi
    else
        if git branch --track "$branch" "origin/$branch" >/dev/null 2>&1; then
            echo "  - $branch: создана от origin/$branch ($remote)"
        else
            echo "  - $branch: ❌ не удалось создать локальную ветку"
        fi
    fi
done

echo
echo "Текущее состояние служебных веток:"
for branch in "${branches[@]}"; do
    local_short=$(short_commit "$branch")
    remote_short=$(short_commit "origin/$branch")
    echo "  $branch: $local_short -> $remote_short"
done

if [ -n "$current_branch" ] && ! is_service_branch "$current_branch" ]; then
    echo
    echo "Текущая рабочая ветка $current_branch не изменялась"
fi

restore_branch
