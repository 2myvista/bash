#!/bin/bash
#v_2
# - поиск реп в папке $HOME не глубже 2-го уровня вложенности
# - выбор реп из предустановленного списка 
 
clear
repos=()

while IFS= read -r gitdir; do
    repo_path="${gitdir%/.git}"
    repo_name=$(basename "$repo_path")
    repos+=("$repo_name:$repo_path")
done < <(find ~ -maxdepth 3 -type d -name ".git" 2>/dev/null)

# Проверяем, что нашли
if [ ${#repos[@]} -eq 0 ]; then
    echo "❌ Репозитории не найдены"
    exit 1
fi

branches=("master" "master_dev" "master_com");

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

echo 
read -p "Выберите репозиторий (номер): " -n 1 choice
echo 

if [ "$choice" = "q" ] || [ "$choice" = "Q" ] || [ "$choice" = "й" ] || [ "$choice" = "Й" ]; then 
    echo "Выход";
    exit 0;
fi

if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
    echo "❌ Введите номер";
    exit 1; 
fi

if [ "$choice" -lt 1 ] || [ "$choice" -gt "${#repos[@]}" ]; then 
    echo "❌ выберите число в диапазоне 1 - ${#repos[@]}";
    exit 1;
fi

#echo "${repos[$((choice-1))]}";
selected="${repos[$((choice-1))]}";

repo_path="${selected#*:}"
echo 
echo "Выбран $repo_path"
echo 

cd $repo_path || exit 1

# Получаем текущую ветку
current_branch=$(git symbolic-ref --short HEAD 2>/dev/null)

switched=false
# Проверяем, что текущая ветка не является одной из защищенных
if [ "$current_branch" = "master" ] || [ "$current_branch" = "master_dev" ] || [ "$current_branch" = "master_com" ]; then
    echo "Вы находитесь в ветке $current_branch, делаем detach"
    echo
    git switch --detach

    switched=true
    #exit 1
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

checkback() {
       if [ "$switched" = true ]; then
        echo "Возвращаемся на ветку: $current_branch"
        git checkout "$current_branch"
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
    checkback
    echo "Нет обновлений ни в одной из веток"
    exit 0
fi

# Если все хорошо, выполняем fetch для обновления веток
echo "Обновление веток master, master_dev, master_com..."
git fetch origin 

if [ $? -eq 0 ]; then
    echo "Ветки успешно обновлены"
   
    # Показываем разницу между локальной и удаленной ветками
    echo ""
    echo "Текущее состояние:"
    for branch in ${branches[@]}; do
        echo "$branch: $(git rev-parse --short $branch) -> $(git rev-parse --short origin/$branch 2>/dev/null || echo 'нет удаленной ветки')"
    done
else
    echo "Ошибка при обновлении веток"
    checkback
    exit 1
fi
checkback
