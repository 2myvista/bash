#!/bin/bash
#v_1
PATH_NAME=$1

if [ -z "$PATH_NAME" ]; then
    echo "❌  путь пустой укажите правильный путь backend или frontend или sync_to_ergonode"
    exit 1
elif [ "$PATH_NAME" != "backend"  ] &&  [ "$PATH_NAME" != "frontend"  ] &&  [ "$PATH_NAME" != "sync_to_ergonode"  ]; then
    echo "❌  укажите правильный путь backend или frontend или sync_to_ergonode"
    exit 1
fi

echo "обновляем $PATH_NAME"

if [ "$PATH_NAME" = "sync_to_ergonode" ]; then
    cd ~/$PATH_NAME || exit 1
else
    cd ~/pim/$PATH_NAME || exit 1
fi

# Получаем текущую ветку
current_branch=$(git symbolic-ref --short HEAD 2>/dev/null)

# Проверяем, что текущая ветка не является одной из защищенных
if [ "$current_branch" = "master" ] || [ "$current_branch" = "master_dev" ] || [ "$current_branch" = "master_com" ]; then
    echo "Ошибка: Вы находитесь в ветке $current_branch"
    echo "Пожалуйста, переключитесь на другую ветку перед обновлением защищенных веток"
    exit 1
fi

# Функция для проверки наличия обновлений в ветке
check_updates() {
    local branch=$1
    
    # Сохраняем текущий коммит локальной ветки
    local local_commit=$(git rev-parse "$branch" 2>/dev/null)
    
    # Получаем последний коммит с удаленной ветки
    local remote_commit=$(git ls-remote origin "refs/heads/$branch" 2>/dev/null | cut -f1)
    
    if [ -z "$remote_commit" ]; then
        echo "  - $branch: удаленная ветка не найдена"
        return 1
    fi
    
    if [ "$local_commit" = "$remote_commit" ]; then
        echo "  - $branch: нет обновлений (актуальна)"
        return 1
    else
        echo "  - $branch: есть обновления"
        echo "    Локальный:  $(echo $local_commit | cut -c1-7)"
        echo "    Удаленный:  $(echo $remote_commit | cut -c1-7)"
        return 0
    fi
}

echo "Проверка наличия обновлений в ветках..."

# Проверяем каждую ветку
updates_available=false
for branch in master master_dev master_com; do
    if check_updates $branch; then
        updates_available=true
    fi
done

if [ "$updates_available" = false ]; then
    echo "Нет обновлений ни в одной из веток"
    exit 0
fi

# Если все хорошо, выполняем fetch для обновления веток
echo "Обновление веток master, master_dev, master_com..."
git fetch origin master:master master_com:master_com master_dev:master_dev

if [ $? -eq 0 ]; then
    echo "Ветки успешно обновлены"
    
    # Показываем разницу между локальной и удаленной ветками
    echo ""
    echo "Текущее состояние:"
    for branch in master master_dev master_com; do
        echo "$branch: $(git rev-parse --short $branch) -> $(git rev-parse --short origin/$branch 2>/dev/null || echo 'нет удаленной ветки')"
    done
else
    echo "Ошибка при обновлении веток"
    exit 1
fi