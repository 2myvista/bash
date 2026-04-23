#!/bin/bash

# Пути
THUMBNAIL_DIR="../thumbnail/default"
ICONS_DIR="../thumbnail/icons"
SOURCE_DIR="."  # текущая директория с исходными файлами

# Файл лога (если нужно)
LOG_FILE=""
if [ "$1" = "log" ] || [ "$1" = "--log" ]; then
    LOG_FILE="generate_previews_$(date +%Y%m%d_%H%M%S).log"
fi

# Списки расширений
RESIZE_EXTENSIONS=("jpeg" "jpg" "png" "webp")
REPLACE_EXTENSIONS=("glb" "dwg" "link" "mp4" "ods" "odt" "key")

# Функции для вывода
log_message() {
    local message="$1"
    if [ -n "$LOG_FILE" ]; then
        echo "$message" >> "$LOG_FILE"
    else
        echo "$message"
    fi
}

log_error() {
    local message="$1"
    # Ошибки всегда в консоль
    echo "❌ $message" >&2
    if [ -n "$LOG_FILE" ]; then
        echo "❌ $message" >> "$LOG_FILE"
    fi
}

log_success() {
    local message="$1"
    if [ -n "$LOG_FILE" ]; then
        echo "✓ $message" >> "$LOG_FILE"
    else
        echo "✓ $message"
    fi
}

log_info() {
    local message="$1"
    if [ -n "$LOG_FILE" ]; then
        echo "$message" >> "$LOG_FILE"
    else
        echo "$message"
    fi
}

# Создаем директории для превью, если их нет
mkdir -p "$THUMBNAIL_DIR"

# Функция для генерации превью из исходного файла (ресайз)
generate_resize() {
    local input_file="$1"
    local output_file="$2"
    local filename="$3"
    
    # Ресайз по большей стороне до 800px
    if convert "$input_file" -resize 800x800\> -background white -alpha remove -alpha off "$output_file" 2>/dev/null; then
        log_success "Сгенерировано (ресайз 800px): $filename"
        return 0
    else
        log_error "Ошибка ресайза: $filename"
        return 1
    fi
}

# Функция для генерации из иконки (замена)
generate_replace() {
    local input_file="$1"
    local output_file="$2"
    local ext="$3"
    local filename="$4"
    
    # Путь к иконке для данного расширения
    local icon_path="$ICONS_DIR/${ext}.png"
    
    # Проверяем, существует ли иконка
    if [ -f "$icon_path" ]; then
        # Используем готовую иконку, ресайзим до 800px
        if convert "$icon_path" -resize 800x800\> "$output_file" 2>/dev/null; then
            log_success "Использована иконка (ресайз до 800px): $filename"
            return 0
        else
            log_error "Ошибка при обработке иконки: $filename (иконка: $icon_path)"
            return 1
        fi
    else
        log_error "Иконка не найдена: $filename (нужна: ${ext}.png в $ICONS_DIR/)"
        return 1
    fi
}

# Функция для проверки существования иконок
check_icons() {
    log_info "=== Проверка иконок в $ICONS_DIR ==="
    
    local found_icons=0
    local missing_icons=0
    
    # Создаем массив для пропущенных иконок
    local missing_list=()
    
    for ext in "${REPLACE_EXTENSIONS[@]}"; do
        icon_path="$ICONS_DIR/${ext}.png"
        if [ -f "$icon_path" ]; then
            log_info "  ✓ .$ext: $icon_path"
            ((found_icons++))
        else
            log_info "  ✗ .$ext: отсутствует"
            ((missing_icons++))
            missing_list+=("$ext")
        fi
    done
    
    log_info ""
    log_info "Найдено иконок: $found_icons из ${#REPLACE_EXTENSIONS[@]}"
    log_info "Отсутствует: $missing_icons"
    
    if [ $missing_icons -gt 0 ]; then
        log_info ""
        log_info "⚠ ВНИМАНИЕ: Отсутствуют иконки для следующих расширений:"
        for ext in "${missing_list[@]}"; do
            log_info "  $ext"
        done
        log_info ""
        log_info "Добавьте PNG иконки в директорию:"
        log_info "  $ICONS_DIR/"
        log_info "Имена файлов: ${missing_list[@]// /}.png"
        log_info ""
        
        # Спрашиваем подтверждение на продолжение
        if [ $missing_icons -eq ${#REPLACE_EXTENSIONS[@]} ]; then
            log_error "Нет ни одной иконки! Продолжение невозможно."
            return 1
        else
            if [ -z "$LOG_FILE" ]; then
                read -p "Продолжить без отсутствующих иконок? (y/N): " -n 1 -r
                echo ""
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    return 1
                fi
            else
                log_info "Продолжаем без отсутствующих иконок (режим логирования)"
            fi
        fi
    fi
    
    return 0
}

# Проверка наличия ImageMagick
check_imagemagick() {
    if ! command -v convert &> /dev/null; then
        log_error "ImageMagick не установлен"
        log_error "Установите: sudo apt install imagemagick"
        exit 1
    fi
    
    # Проверяем, что convert работает
    if ! convert --version &> /dev/null; then
        log_error "Команда convert не работает"
        exit 1
    fi
    
    log_info "ImageMagick доступен: $(convert --version | head -1)"
    return 0
}

# Функция проверки, находится ли расширение в массиве
in_array() {
    local element="$1"
    shift
    local array=("$@")
    for item in "${array[@]}"; do
        if [[ "$item" == "$element" ]]; then
            return 0
        fi
    done
    return 1
}

# Проверяем зависимости
log_info "=== Проверка зависимостей ==="
check_imagemagick
log_info ""

# Проверяем иконки
if ! check_icons; then
    log_error "Завершение работы."
    exit 1
fi

# Массивы для статистики
declare -A processed_extensions  # расширения, которые мы обработали (ресайз или замена)
declare -A unprocessed_extensions  # расширения, которые мы НЕ обрабатываем (не в списках)
declare -A first_file_of_type  # первый файл каждого типа для вывода в отчет
declare -A missing_icon_extensions  # расширения, для которых нет иконок

# Статистика генерации
declare -i generated_resize=0
declare -i generated_replace=0
declare -i skipped=0
declare -i skipped_missing_icon=0
declare -i already_exists=0
declare -i errors_count=0

log_info ""
log_info "=== Поиск отсутствующих превью и генерация ==="
log_info ""

# Проходим по всем файлам в текущей директории
for f in "$SOURCE_DIR"/*; do
    [ -f "$f" ] || continue
    
    filename=$(basename "$f")
    name="${filename%.*}"
    ext="${filename##*.}"
    ext_lower=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
    
    # Пропускаем системные файлы и скрытые файлы
    [[ "$filename" == .* ]] && continue
    
    # Пропускаем файлы без расширения
    [[ "$name" == "$filename" ]] && continue
    
    # Проверяем существование превью
    thumbnail_path="$THUMBNAIL_DIR/${name}.png"
    
    if [ -f "$thumbnail_path" ]; then
        ((already_exists++))
        continue
    fi
    
    # Определяем тип обработки
    if in_array "$ext_lower" "${RESIZE_EXTENSIONS[@]}"; then
        # Ресайз
        if [[ -z "${processed_extensions[$ext_lower]}" ]]; then
            log_info "[Новый тип] .$ext_lower - ресайз: $filename"
            processed_extensions[$ext_lower]="resize"
            first_file_of_type[$ext_lower]="$filename"
        fi
        
        if generate_resize "$f" "$thumbnail_path" "$filename"; then
            ((generated_resize++))
        else
            ((errors_count++))
        fi
        
    elif in_array "$ext_lower" "${REPLACE_EXTENSIONS[@]}"; then
        # Замена на иконку
        if [[ -z "${processed_extensions[$ext_lower]}" ]]; then
            log_info "[Новый тип] .$ext_lower - иконка: $filename"
            processed_extensions[$ext_lower]="replace"
            first_file_of_type[$ext_lower]="$filename"
        fi
        
        # Проверяем наличие иконки
        icon_path="$ICONS_DIR/${ext_lower}.png"
        if [ ! -f "$icon_path" ]; then
            if [[ -z "${missing_icon_extensions[$ext_lower]}" ]]; then
                log_error "Пропущен (нет иконки): $filename"
                missing_icon_extensions[$ext_lower]="$filename"
            fi
            ((skipped_missing_icon++))
            ((skipped++))
            continue
        fi
        
        if generate_replace "$f" "$thumbnail_path" "$ext_lower" "$filename"; then
            ((generated_replace++))
        else
            ((errors_count++))
        fi
        
    else
        # Не обрабатываем этот тип (не в списках)
        if [[ -z "${unprocessed_extensions[$ext_lower]}" ]]; then
            unprocessed_extensions[$ext_lower]="$filename"
        fi
        ((skipped++))
        continue
    fi
done

# Статистика
log_info ""
log_info "=== Статистика обработки ==="
log_info "Уже существовало превью:          $already_exists"
log_info "Сгенерировано (ресайз):            $generated_resize"
log_info "Сгенерировано (иконка):            $generated_replace"
log_info "Пропущено (нет иконки):            $skipped_missing_icon"
log_info "Пропущено (не в списках):          $((skipped - skipped_missing_icon))"
log_info "Ошибок при генерации:              $errors_count"
log_info "Всего файлов обработано:           $((generated_resize + generated_replace))"

if [ $errors_count -gt 0 ]; then
    log_error "ВНИМАНИЕ: Было $errors_count ошибок при генерации!"
fi

log_info ""

# Вывод обработанных расширений
if [ ${#processed_extensions[@]} -gt 0 ]; then
    log_info "=== Обработанные расширения (${#processed_extensions[@]}) ==="
    for ext in $(echo "${!processed_extensions[@]}" | tr ' ' '\n' | sort); do
        type="${processed_extensions[$ext]}"
        first_file="${first_file_of_type[$ext]}"
        if [ "$type" = "resize" ]; then
            log_info "  .$ext - РЕСАЙЗ из исходника - пример: $first_file"
        else
            log_info "  .$ext - ИКОНКА - пример: $first_file"
        fi
    done
    log_info ""
fi

# Вывод расширений без иконок
if [ ${#missing_icon_extensions[@]} -gt 0 ]; then
    log_error "=== Расширения без иконок (${#missing_icon_extensions[@]}) ==="
    log_error "  Файлы пропущены. Добавьте иконки в $ICONS_DIR/"
    for ext in $(echo "${!missing_icon_extensions[@]}" | tr ' ' '\n' | sort); do
        first_file="${missing_icon_extensions[$ext]}"
        log_error "  .$ext - пример: $first_file (нужен файл: ${ext}.png)"
    done
    log_info ""
fi

# Вывод НЕобработанных расширений (не в списках)
if [ ${#unprocessed_extensions[@]} -gt 0 ]; then
    # Исключаем те, которые уже вывели в missing_icon_extensions
    for ext in "${!missing_icon_extensions[@]}"; do
        unset unprocessed_extensions[$ext]
    done
    
    if [ ${#unprocessed_extensions[@]} -gt 0 ]; then
        log_info "=== НЕ обработанные расширения (${#unprocessed_extensions[@]}) ==="
        log_info "  (не входят в списки RESIZE_EXTENSIONS или REPLACE_EXTENSIONS)"
        for ext in $(echo "${!unprocessed_extensions[@]}" | tr ' ' '\n' | sort); do
            first_file="${unprocessed_extensions[$ext]}"
            log_info "  .$ext - пример: $first_file"
        done
        log_info ""
    fi
fi

# Сводка по спискам расширений
log_info "=== Списки обработки ==="
log_info "Ресайз (${#RESIZE_EXTENSIONS[@]} расширений):"
for ext in $(printf '%s\n' "${RESIZE_EXTENSIONS[@]}" | sort); do
    log_info "  .$ext"
done

log_info ""
log_info "Замена иконкой (${#REPLACE_EXTENSIONS[@]} расширений):"
for ext in $(printf '%s\n' "${REPLACE_EXTENSIONS[@]}" | sort); do
    icon_status="✗"
    if [ -f "$ICONS_DIR/${ext}.png" ]; then
        icon_status="✓"
    fi
    log_info "  $icon_status .$ext"
done

# Информация об иконках
log_info ""
log_info "=== Информация об иконках ==="
log_info "Директория с иконками: $ICONS_DIR"
log_info "Формат имен файлов: {расширение}.png"
log_info ""
log_info "Необходимые иконки:"
for ext in "${REPLACE_EXTENSIONS[@]}"; do
    log_info "  - ${ext}.png"
done

# Информация о файле лога
if [ -n "$LOG_FILE" ]; then
    log_info ""
    log_info "=== Информация о логе ==="
    log_info "Полный лог сохранен в: $LOG_FILE"
    echo "✓ Лог сохранен в: $LOG_FILE" >&2
fi

# Финальное сообщение
if [ $errors_count -eq 0 ] && [ $((generated_resize + generated_replace)) -gt 0 ]; then
    if [ -z "$LOG_FILE" ]; then
        echo "✓ Генерация превью завершена успешно!" >&2
    else
        echo "✓ Генерация превью завершена. Подробности в логе: $LOG_FILE" >&2
    fi
elif [ $errors_count -gt 0 ]; then
    echo "⚠ Генерация завершена с ошибками ($errors_count). Проверьте лог для деталей." >&2
fi