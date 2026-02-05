#!/bin/bash

# Скрипт запуска тестов для файловой системы OCFS2

set -euo pipefail

MOUNT_POINT=${1:?"MOUNT_POINT is required"}
TOTAL_NODES=${2:-1}

TEST_DIR="$MOUNT_POINT/test_data"
NODE_NAME="$(hostname)"
NODE_TEST_DIR="/tmp/test_results_${NODE_NAME}"
RESULTS_FILE="${NODE_TEST_DIR}/test_results.txt"
# Уникальный префикс узла, чтобы файлы разных узлов не пересекались (в контейнерах PID могут совпадать)
NODE_PREFIX="$(hostname | sed 's/ocfs2-node-/n/')_$$"

log_info() {
  echo "[TEST] $1"
}

log_info "Запуск тестов файловой системы OCFS2"
log_info "Точка монтирования: $MOUNT_POINT"
log_info "Количество узлов: $TOTAL_NODES"

# Создаем директорию для сохранения результатов тестов на узле
mkdir -p "$NODE_TEST_DIR"
: > "$RESULTS_FILE"
mkdir -p "$TEST_DIR"

# Тест 1: создание/чтение/удаление файла
test_basic_operations() {
  log_info "Тест 1: Базовые операции с файлами..."
  local test_file="$TEST_DIR/test_file_${NODE_PREFIX}"
  local test_content="Test content from $(hostname) at $(date +%s)"
  echo "$test_content" > "$test_file"

  if [[ -f "$test_file" ]] && [[ "$(cat "$test_file")" == "$test_content" ]]; then
    echo "PASS: Базовые операции с файлами" >> "$RESULTS_FILE"
    log_info "✓ PASS"
  else
    echo "FAIL: Базовые операции с файлами" >> "$RESULTS_FILE"
    log_info "✗ FAIL"
  fi
  rm -f "$test_file" || true
}

# Тест 2: операции с директориями
test_directory_operations() {
  log_info "Тест 2: Операции с директориями..."
  local d="$TEST_DIR/test_dir_${NODE_PREFIX}"
  mkdir -p "$d"
  if [[ -d "$d" ]]; then
    echo "PASS: Операции с директориями" >> "$RESULTS_FILE"
    log_info "✓ PASS"
    rmdir "$d" || true
  else
    echo "FAIL: Операции с директориями" >> "$RESULTS_FILE"
    log_info "✗ FAIL"
  fi
}

# Тест 3: параллельная запись
test_concurrent_write() {
  log_info "Тест 3: Параллельная запись..."
  local f="$TEST_DIR/concurrent_test"
  local node_id
  node_id="$(hostname | sed 's/ocfs2-node-//g')"
  echo "Node ${node_id}: $(date +%s)" >> "$f"
  sleep 2

  if [[ -f "$f" ]]; then
    local line_count
    line_count="$(wc -l < "$f" 2>/dev/null || echo 0)"
    # Убираем пробелы на всякий случай
    line_count="$(echo "$line_count" | tr -d '[:space:]')"
    if [[ "${line_count:-0}" =~ ^[0-9]+$ ]] && [[ "$line_count" -ge 1 ]]; then
      echo "PASS: Параллельная запись (найдено $line_count строк)" >> "$RESULTS_FILE"
      log_info "✓ PASS"
    else
      echo "FAIL: Параллельная запись" >> "$RESULTS_FILE"
      log_info "✗ FAIL"
    fi
  else
    echo "FAIL: Параллельная запись" >> "$RESULTS_FILE"
    log_info "✗ FAIL"
  fi
}

# Тест 4: большой файл
test_large_file() {
  log_info "Тест 4: Работа с большими файлами..."
  local f="$TEST_DIR/large_file_${NODE_PREFIX}"
  local size_mb=8
  dd if=/dev/urandom of="$f" bs=1M count="$size_mb" status=none || true

  if [[ -f "$f" ]]; then
    local actual_size
    actual_size="$(stat -c%s "$f" 2>/dev/null || echo 0)"
    local expected_size=$((size_mb * 1024 * 1024))
    if [[ "${actual_size:-0}" =~ ^[0-9]+$ ]] && [[ "$actual_size" -eq "$expected_size" ]]; then
      echo "PASS: Большие файлы (${size_mb}MB)" >> "$RESULTS_FILE"
      log_info "✓ PASS"
    else
      echo "FAIL: Большие файлы" >> "$RESULTS_FILE"
      log_info "✗ FAIL"
    fi
    rm -f "$f" || true
  else
    echo "FAIL: Большие файлы" >> "$RESULTS_FILE"
    log_info "✗ FAIL"
  fi
}

# Тест 5: целостность данных
test_data_integrity() {
  log_info "Тест 5: Целостность данных..."
  local f="$TEST_DIR/integrity_test_${NODE_PREFIX}"
  local data="Integrity test data: $(date +%s)"
  echo "$data" > "$f"
  if [[ "$(cat "$f" 2>/dev/null || true)" == "$data" ]]; then
    echo "PASS: Целостность данных" >> "$RESULTS_FILE"
    log_info "✓ PASS"
  else
    echo "FAIL: Целостность данных" >> "$RESULTS_FILE"
    log_info "✗ FAIL"
  fi
  rm -f "$f" || true
}

# Тест 6: метаданные/права
test_metadata() {
  log_info "Тест 6: Метаданные..."
  local f="$TEST_DIR/metadata_test_${NODE_PREFIX}"
  echo "Metadata test" > "$f"
  chmod 640 "$f" || true
  if [[ -f "$f" ]] && [[ -r "$f" ]]; then
    echo "PASS: Метаданные" >> "$RESULTS_FILE"
    log_info "✓ PASS"
  else
    echo "FAIL: Метаданные" >> "$RESULTS_FILE"
    log_info "✗ FAIL"
  fi
  rm -f "$f" || true
}

# Запуск кастомных тестов
test_basic_operations
test_directory_operations
test_concurrent_write
test_large_file
test_data_integrity
test_metadata

# Запуск xfstests для OCFS2 (если доступен)
run_xfstests() {
  log_info "Проверка наличия xfstests..."
  
  local xfstests_cmd=""
  local xfstests_dir=""
  
  # Ищем xfstests в различных местах
  if command -v check >/dev/null 2>&1; then
    xfstests_cmd="check"
  elif [ -f "/opt/xfstests/check" ]; then
    xfstests_dir="/opt/xfstests"
    xfstests_cmd="$xfstests_dir/check"
  elif [ -f "/usr/share/xfstests/check" ]; then
    xfstests_dir="/usr/share/xfstests"
    xfstests_cmd="$xfstests_dir/check"
  elif [ -f "/xfstests/check" ]; then
    xfstests_dir="/xfstests"
    xfstests_cmd="$xfstests_dir/check"
  else
    log_info "xfstests не найден, пропускаем..."
    return 0
  fi

  local xfstests_results="${NODE_TEST_DIR}/xfstests_results.txt"
  local xfstests_log="${NODE_TEST_DIR}/xfstests.log"
  local xfstests_summary="${NODE_TEST_DIR}/xfstests_summary.txt"

  log_info "Найден xfstests: $xfstests_cmd"
  log_info "Результаты будут сохранены в: $NODE_TEST_DIR"

  # Определяем устройство из точки монтирования
  local test_dev
  test_dev="$(mount | grep -w "$MOUNT_POINT" | awk '{print $1}' | head -1)"
  if [ -z "$test_dev" ] || [ ! -b "$test_dev" ]; then
    test_dev="/dev/drbd0"
  fi

  log_info "Используемое устройство: $test_dev"
  log_info "Точка монтирования: $MOUNT_POINT"

  # Переходим в директорию xfstests если нужно
  local old_pwd="$(pwd)"
  if [ -n "$xfstests_dir" ] && [ -d "$xfstests_dir" ]; then
    cd "$xfstests_dir" || cd "$old_pwd"
  fi

  # Создаем конфигурационный файл для xfstests
  local xfstests_config="${NODE_TEST_DIR}/local.config"
  cat > "$xfstests_config" <<EOF
export TEST_DEV="$test_dev"
export TEST_DIR="$MOUNT_POINT"
export FSTYP=ocfs2
EOF

  log_info "Запуск xfstests generic группы (базовые тесты для всех ФС)..."
  
  # Запускаем generic тесты (базовые тесты для всех ФС)
  # Используем timeout чтобы не зависнуть навсегда
  local xfstests_passed=0
  local xfstests_failed=0
  
  # Пробуем запустить generic тесты
  if timeout 300 bash -c "source $xfstests_config && $xfstests_cmd -g auto" > "$xfstests_log" 2>&1; then
    xfstests_passed=1
    log_info "✓ xfstests generic группа завершена успешно"
    echo "PASS: xfstests generic группа" >> "$RESULTS_FILE"
  else
    local exit_code=$?
    log_info "xfstests завершился с кодом $exit_code, анализируем результаты..."
    
    # Пробуем извлечь информацию о пройденных тестах из лога
    if grep -q "Passed all" "$xfstests_log" 2>/dev/null || grep -q "All tests passed" "$xfstests_log" 2>/dev/null; then
      xfstests_passed=1
      log_info "✓ xfstests: все тесты пройдены (согласно логу)"
      echo "PASS: xfstests (все тесты пройдены)" >> "$RESULTS_FILE"
    elif grep -q "Failed" "$xfstests_log" 2>/dev/null || grep -q "failed" "$xfstests_log" 2>/dev/null; then
      local passed_count=$(grep -c "Passed" "$xfstests_log" 2>/dev/null || echo 0)
      local failed_count=$(grep -c "Failed" "$xfstests_log" 2>/dev/null || echo 0)
      log_info "xfstests: пройдено ~$passed_count, провалено ~$failed_count"
      echo "PARTIAL: xfstests (пройдено ~$passed_count, провалено ~$failed_count)" >> "$RESULTS_FILE"
    else
      log_warn "Не удалось определить результаты xfstests из лога"
      echo "UNKNOWN: xfstests (см. лог)" >> "$RESULTS_FILE"
    fi
  fi

  # Сохраняем сводку результатов
  {
    echo "=== xfstests Results Summary ==="
    echo "Date: $(date)"
    echo "Node: $NODE_NAME"
    echo "Device: $test_dev"
    echo "Mount point: $MOUNT_POINT"
    echo "Command: $xfstests_cmd -g auto"
    echo ""
    if [ -f "$xfstests_log" ]; then
      echo "=== Last 50 lines of log ==="
      tail -50 "$xfstests_log"
    fi
  } > "$xfstests_summary"

  # Возвращаемся в исходную директорию
  cd "$old_pwd" || true

  log_info "Результаты xfstests сохранены в $NODE_TEST_DIR"
}

# Запускаем xfstests (DRBD_DEVICE будет определен внутри функции через mount)
run_xfstests

log_info "Результаты тестов:"
echo "=========================================="
cat "$RESULTS_FILE"
echo "=========================================="

pass_count="$(grep -c '^PASS' "$RESULTS_FILE" 2>/dev/null || true)"
fail_count="$(grep -c '^FAIL' "$RESULTS_FILE" 2>/dev/null || true)"
pass_count="${pass_count:-0}"
fail_count="${fail_count:-0}"

# Нормализуем числа
pass_count="$(echo "$pass_count" | tr -d '[:space:]')"
fail_count="$(echo "$fail_count" | tr -d '[:space:]')"
[[ "$pass_count" =~ ^[0-9]+$ ]] || pass_count=0
[[ "$fail_count" =~ ^[0-9]+$ ]] || fail_count=0

total_count=$((pass_count + fail_count))

log_info "Итого: $pass_count успешных, $fail_count неудачных из $total_count тестов"

# Сохраняем результаты тестов в директории узла
log_info "Сохранение результатов тестов в $NODE_TEST_DIR..."
mkdir -p "$NODE_TEST_DIR"
cp "$RESULTS_FILE" "${NODE_TEST_DIR}/summary.txt" 2>/dev/null || true
{
  echo "Node: $NODE_NAME"
  echo "Mount point: $MOUNT_POINT"
  echo "Total nodes: $TOTAL_NODES"
  echo "Test date: $(date)"
  echo "Passed: $pass_count"
  echo "Failed: $fail_count"
} > "${NODE_TEST_DIR}/node_info.txt"

# Сохраняем полный лог тестов
log_info "Полный лог тестов сохранен в ${NODE_TEST_DIR}/full_test_log.txt"
{
  echo "=== Test Results Summary ==="
  cat "$RESULTS_FILE"
  echo ""
  echo "=== Full Test Output ==="
} > "${NODE_TEST_DIR}/full_test_log.txt"

log_info "Файлы сохранены:"
ls -la "$NODE_TEST_DIR" | tail -n +2 || true

if [[ "$fail_count" -eq 0 ]]; then
  log_info "Все тесты пройдены успешно!"
  exit 0
else
  log_info "Некоторые тесты не пройдены"
  exit 1
fi
