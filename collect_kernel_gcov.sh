#!/bin/bash

# Скрипт сбора gcov отчётов для драйвера OCFS2 ядра Linux

set -euo pipefail

GCOV_BASE="/sys/kernel/debug/gcov"
REPORT_DIR="/tmp/gcov_reports/kernel_ocfs2"
KERNEL_SRC="/usr/src/linux-source-$(uname -r | cut -d- -f1)"

log_info() {
    echo "[KERNEL GCOV] $1"
}

log_info "Сбор gcov отчётов для драйвера OCFS2 ядра"

# Создание директории для отчётов
mkdir -p "$REPORT_DIR"

# Проверка доступности gcov
if [ ! -d "$GCOV_BASE" ]; then
    log_info "WARNING: /sys/kernel/debug/gcov недоступен"
    log_info "Убедитесь, что ядро скомпилировано с CONFIG_GCOV_KERNEL=y"
    log_info "И что debugfs смонтирован: mount -t debugfs none /sys/kernel/debug"
    exit 1
fi

# Монтирование debugfs если не смонтирован
if ! mountpoint -q /sys/kernel/debug; then
    log_info "Монтирование debugfs..."
    mount -t debugfs none /sys/kernel/debug || true
fi

# Поиск gcov данных для OCFS2
log_info "Поиск gcov данных для модулей OCFS2..."

# Пути к исходникам OCFS2 в ядре
OCFS2_PATHS=(
    "fs/ocfs2"
    "fs/ocfs2/dlm"
    "fs/ocfs2/cluster"
)

# Сбор данных для каждого пути
for path in "${OCFS2_PATHS[@]}"; do
    log_info "Обработка пути: $path"
    
    if [ -d "$GCOV_BASE/$path" ]; then
        # Копирование gcov данных
        mkdir -p "$REPORT_DIR/$(dirname $path)"
        cp -r "$GCOV_BASE/$path" "$REPORT_DIR/$path" 2>/dev/null || true
        
        # Обработка gcov файлов
        find "$REPORT_DIR/$path" -name "*.gcda" -o -name "*.gcno" | while read file; do
            log_info "Найден файл: $file"
        done
    fi
done

# Генерация отчёта
log_info "Генерация текстового отчёта..."

REPORT_FILE="$REPORT_DIR/coverage_report.txt"
> "$REPORT_FILE"

echo "Отчёт о покрытии кода драйвера OCFS2 ядра Linux" >> "$REPORT_FILE"
echo "Дата: $(date)" >> "$REPORT_FILE"
echo "Версия ядра: $(uname -r)" >> "$REPORT_FILE"
echo "==========================================" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"

# Подсчёт статистики
TOTAL_FILES=0
TOTAL_LINES=0
COVERED_LINES=0

find "$REPORT_DIR" -name "*.gcda" | while read gcda_file; do
    gcno_file="${gcda_file%.gcda}.gcno"
    
    if [ -f "$gcno_file" ]; then
        echo "Файл: $gcda_file" >> "$REPORT_FILE"
        
        # Попытка использовать gcov для генерации отчёта
        if command -v gcov &> /dev/null; then
            gcov_output=$(gcov "$gcda_file" 2>&1 || true)
            echo "$gcov_output" >> "$REPORT_FILE"
        fi
        echo "" >> "$REPORT_FILE"
    fi
done

log_info "Отчёт сохранён в $REPORT_FILE"

# Вывод краткой информации
if [ -f "$REPORT_FILE" ]; then
    log_info "Краткая информация из отчёта:"
    head -20 "$REPORT_FILE"
fi

log_info "Сбор отчётов завершён"
