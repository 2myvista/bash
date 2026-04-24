#!/bin/bash

# Включаем trap для функций
set -o errtrace
trap 'echo ❌ "ОШИБКА в строке $LINENO: $BASH_COMMAND" >&2; exit 1' ERR
nginxPath="/var/log/nginx/" 
prodErrorPath="$HOME/pim/backend/var/log/"
#prefixErrorMode="prod"          #16:44:25
prefixErrorMode="dev"           #11:12:35

getDate() {
    [[ -z "$1" ]] && { echo "❌ Пустая строка" >&2; false; }
    [[ -z "$2" ]] && { echo "❌ Нет времени" >&2; false; }
    
    local date=$(grep -o '[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}' <<< "$1" | head -1)
    [[ -z "$date" ]] && { echo "Дата не найдена" >&2; false; }
    
    echo $(date -d "$date" '+%d/%b/%Y')':'$2
}

getAccessData() {
    local date="$1"
    local file="$2"
    
    [[ -z "$date" ]] && { echo "❌ Пустая дата" >&2; false; }
    
    # Сначала точный поиск
    local exact_result=$({
        zgrep -H -n "$date" "$nginxPath$file"*.gz 2>/dev/null || true
        grep -H -n "$date" "$nginxPath$file"* 2>/dev/null | grep -v '\.gz:' || true
    })
    
    exact_result=$(echo "$exact_result" | sed '/^$/d')
    
    # Если нашли и есть ошибки - возвращаем
    if [[ -n "$exact_result" ]]; then
        local errors=$(echo "$exact_result" | grep -v ' 200 \| 204 \| 3[0-9][0-9] ')
        if [[ -n "$errors" ]]; then
            echo "$errors"
            return 0
        fi
    fi
    
    # Если не нашли или нет ошибок - ищем в диапазоне
    echo "⚠️ Точного совпадения нет, ищем в соседних секундах..." >&2
    
    local base_time=$(echo "$date" | cut -d: -f1-3)  # Без секунд
    local second=$(echo "$date" | cut -d: -f4 | sed 's/^0*//')  # Без ведущих нулей
    
    for offset in -2 -1 1 2; do
        local new_second=$((second + offset))
        if [[ $new_second -ge 0 && $new_second -le 59 ]]; then
            local new_time="${base_time}:$(printf "%02d" $new_second)"
            
            local range_result=$({
                zgrep -H -n "$new_time" "$nginxPath$file"*.gz 2>/dev/null || true
                grep -H -n "$new_time" "$nginxPath$file"* 2>/dev/null | grep -v '\.gz:' || true
            })
            
            # Ищем ошибки в результатах
            local range_errors=$(echo "$range_result" | grep -v ' 200 \| 204 \| 3[0-9][0-9] ' | sed '/^$/d')
            
            if [[ -n "$range_errors" ]]; then
                echo "✅ Найдено в соседней секунде ($offset):" >&2
                echo "$range_errors"
                return 0
            fi
        fi
    done

    local dateLog=$(echo "$base_time" | cut -d: -f1)
    echo "⚠️  Ничего не нашли, ищем наличие логов на дату ошибки ($dateLog)..." >&2

    local date_result=$({
        zgrep -H -n "$dateLog" "$nginxPath$file"*.gz 2>/dev/null || true
        grep -H -n "$dateLog" "$nginxPath$file"* 2>/dev/null | grep -v '\.gz:' || true
    })

    if [[ -z "$date_result" ]]; then
        echo "❌ Не найдены логи для даты ошибки ($dateLog)\n" >&2
        false
    fi
    
    echo "❌ Не найдено даже в соседних секундах\n" >&2
    false
}

parseLine() {
    local line="$1"
    clean_line=$(echo "$line" | sed 's/^[^:]*:[0-9]*://')
    
    ip=$(echo "$clean_line" | awk '{print $1}')
    
    request=$(echo "$clean_line" | awk -F'"' '{print $2}')
    
    referer=$(echo "$clean_line" | awk -F'"' '{print $4}')
    
    method=$(echo "$request" | awk '{print $1}')
    
    url=$(echo "$request" | awk '{print $2}')
    
    # Статус: 3 цифры после кавычек
    status=$(echo "$clean_line" | grep -o '\"[^"]*\" [0-9]\{3\}' | awk '{print $NF}')
    
    echo "IP: $ip"
    echo "Запрос: $request"
    echo "Метод: $method"
    echo "Referer: $referer"
    echo "URL: $url"
    echo "Статус: $status"
    echo ""

    payload=$(echo "$line" | awk -F'"' 'NF >= 8 {print $8}')
    decoded=$(echo "$payload" | sed -e 's/\\x22/"/g' -e 's/"password":"[^"]*"/"password":"******"/')

    if [[ -n "$decoded" ]]; then
        echo "📄 Данные: $decoded"
    fi
}

getMethod() {
    local line="$1"
    [[ -z "$line" ]] && { echo ""; return 1; }

    awk -F'"' '{print $2}' <<< "$line" | awk '{print $1}'
}

log() {
    echo -e "\n$@"
}

extract_request() {
    echo "$1" | grep -oE '"([A-Z]+) [^ ]+ HTTP/[0-9\.]+"'
}

main() {
    clear
    log "─────────────────────────────────────── начало ───────────────────────────────────────"
    log "prefixErrorMode = $prefixErrorMode-error"
    
    # Ищем ошибку по времени
    error=$(grep "$1" "$prodErrorPath""$prefixErrorMode"-error* 2>/dev/null | grep -E 'ERROR|CRITICAL' | head -1)
    [[ -z "$error" ]] && { 
        log "❌ Ошибки не найдены" >&2
        false
    }

    log "Найденная ошибка:\n\n$error"
    
    date=$(getDate "$error" "$1")
    
    log "✅ Дата запроса: $date"

    accessData=$(getAccessData "$date" "access")

    log '✅ Данные запроса из access:\n'$accessData
    log "Найдено строк : "$(echo "$accessData" | wc -l)

    local start_line=true
    while IFS= read -r accessDataLine; do
        [[ -z "$accessDataLine" ]] && continue
        log "────────────────────────────────"
        log "Тело запроса\n $accessDataLine"
       # log 
        date=""
        method=""
        # Извлекаем дату
        date=$(echo "$accessDataLine" | grep -o '\[[^]]*\]' | tr -d '[]' | cut -d' ' -f1)
        log "✅ Дата реального запроса: $date" 

        # Определяем метод
        method=$(getMethod "$accessDataLine")

        #debug ------------------
        if $start_line; then
            start_line=false
            #method=""
        fi
        #debug ------------------

        log "📋 Метод запроса: $method"

        if [[ -z "$method" ]]; then
            log "❌ Не удалось определить метод"
            continue
        fi

        log "✅ Выводим данные $method запроса:"
        if [[ $method =~ ^(POST|PATCH|PUT)$ ]]; then
            #log "✅ Ищем post_data..."

            postDataContent=$(getAccessData "$date" "post_data")
            access_request=$(extract_request "$accessDataLine")

             while IFS= read -r currentDataLine; do
                [[ -z "$currentDataLine" ]] && continue

                current_request=$(extract_request "$currentDataLine")

                if [[ "$access_request" == "$current_request" ]]; then
                    #данные одинаковы вызываем
                    parseLine "$currentDataLine"
                    log $parsedPostData
                fi
             done <<< "$postDataContent"
        else
            parsedData=$(parseLine "$accessDataLine")
            log "$parsedData"
        fi

    done <<< "$accessData"

    log "─────────────────────────────────────── конец ────────────────────────────────────────"
}

if [[ $# -eq 0 ]]; then
    log "❌ Укажите время (пример: 11:12:07)"
    exit 1
fi

main "$@"