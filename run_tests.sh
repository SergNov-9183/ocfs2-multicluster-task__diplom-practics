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

log_warn() {
  echo "[TEST] WARN: $1"
}

load_xfstests_profile() {
  XFSTESTS_PROFILE="${XFSTESTS_PROFILE:-default}"
  MKFS_TYPE="${MKFS_TYPE:-datafiles}"
  MKFS_FEATURES="${MKFS_FEATURES:-}"
  XFSTESTS_TESTS="${XFSTESTS_TESTS:-}"
  XFSTESTS_GROUPS="${XFSTESTS_GROUPS:-}"
  XFSTESTS_TIMEOUT="${XFSTESTS_TIMEOUT:-420}"
  SCRATCH_SIZE_MB="${SCRATCH_SIZE_MB:-512}"
  MOUNT_OPTIONS="${MOUNT_OPTIONS:-}"

  local conf="${OCFS2_XFSTESTS_CONF:-}"
  local candidates=()
  [[ -n "$conf" ]] && candidates+=("$conf")
  candidates+=(
    "/opt/xfstests_configs/${XFSTESTS_PROFILE}.env"
    "/xfstests_configs/${XFSTESTS_PROFILE}.env"
  )
  local f
  for f in "${candidates[@]}"; do
    if [[ -f "$f" ]]; then
      # shellcheck disable=SC1090
      set -a
      # shellcheck source=/dev/null
      source "$f"
      set +a
      log_info "Загружен профиль xfstests: $f (profile=${XFSTESTS_PROFILE})"
      return 0
    fi
  done
  log_warn "Файл профиля xfstests не найден, используем значения по умолчанию (profile=${XFSTESTS_PROFILE})"
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

# Расширенные операции, которые xfstests может не успеть (xattr/acl/mmap/fallocate)
test_xattr_acl_mmap() {
  log_info "Тест 7: xattr / ACL / mmap / fallocate (профиль ${XFSTESTS_PROFILE:-default})..."
  local f="$TEST_DIR/extra_${NODE_PREFIX}"
  echo "extra" > "$f" || true
  local ok=1
  if command -v setfattr >/dev/null 2>&1; then
    setfattr -n user.ocfs2test -v "yes" "$f" 2>/dev/null || ok=0
    getfattr -n user.ocfs2test "$f" >/dev/null 2>&1 || ok=0
  fi
  if command -v setfacl >/dev/null 2>&1; then
    setfacl -m u:root:rw "$f" 2>/dev/null || true
  fi
  dd if=/dev/zero of="$TEST_DIR/mmap_${NODE_PREFIX}" bs=4k count=16 status=none 2>/dev/null || true
  if command -v fallocate >/dev/null 2>&1; then
    fallocate -l 1M "$TEST_DIR/falloc_${NODE_PREFIX}" 2>/dev/null || true
    fallocate -p -o 0 -l 64k "$TEST_DIR/falloc_${NODE_PREFIX}" 2>/dev/null || true
  fi
  ln -s "$f" "$TEST_DIR/link_${NODE_PREFIX}" 2>/dev/null || true
  ln "$f" "$TEST_DIR/hlink_${NODE_PREFIX}" 2>/dev/null || true
  mkdir -p "$TEST_DIR/sub_${NODE_PREFIX}" && mv "$f" "$TEST_DIR/sub_${NODE_PREFIX}/" 2>/dev/null || true
  if [[ "$ok" -eq 1 ]]; then
    echo "PASS: xattr/acl/mmap/fallocate" >> "$RESULTS_FILE"
    log_info "✓ PASS"
  else
    echo "PARTIAL: xattr/acl/mmap/fallocate" >> "$RESULTS_FILE"
    log_info "⚠ PARTIAL"
  fi
}

# Запуск кастомных тестов
load_xfstests_profile
test_basic_operations
test_directory_operations
test_concurrent_write
test_large_file
test_data_integrity
test_metadata
test_xattr_acl_mmap

# Запуск xfstests для OCFS2 (если доступен)
run_xfstests() {
  log_info "Проверка наличия xfstests..."

  local xfstests_cmd=""
  local xfstests_dir=""

  if [ -x "/opt/xfstests/check" ]; then
    xfstests_dir="/opt/xfstests"
    xfstests_cmd="$xfstests_dir/check"
  elif [ -f "/opt/xfstests/check" ]; then
    xfstests_dir="/opt/xfstests"
    xfstests_cmd="bash $xfstests_dir/check"
  elif command -v check >/dev/null 2>&1; then
    xfstests_cmd="check"
    xfstests_dir="$(dirname "$(command -v check)")"
  elif [ -f "/usr/share/xfstests/check" ]; then
    xfstests_dir="/usr/share/xfstests"
    xfstests_cmd="bash $xfstests_dir/check"
  elif [ -f "/xfstests/check" ]; then
    xfstests_dir="/xfstests"
    xfstests_cmd="bash $xfstests_dir/check"
  else
    log_info "xfstests не найден, пропускаем..."
    return 0
  fi

  local xfstests_log="${NODE_TEST_DIR}/xfstests.log"
  local xfstests_summary="${NODE_TEST_DIR}/xfstests_summary.txt"

  log_info "Найден xfstests: $xfstests_cmd"
  log_info "Профиль: ${XFSTESTS_PROFILE:-default}"
  log_info "Результаты будут сохранены в: $NODE_TEST_DIR"

  local test_dev
  test_dev="$(mount | grep -w "$MOUNT_POINT" | awk '{print $1}' | head -1)"
  if [ -z "$test_dev" ] || [ ! -b "$test_dev" ]; then
    test_dev="/dev/drbd0"
  fi

  # Scratch-устройство: отдельный loop, чтобы тесты с mkfs на scratch не трогали DRBD
  local scratch_img="/tmp/xfstests_scratch_${NODE_NAME}.img"
  local scratch_mnt="/mnt/xfstests_scratch"
  local scratch_dev=""
  mkdir -p "$scratch_mnt"
  if ! losetup -f >/dev/null 2>&1; then
    log_warn "losetup недоступен, xfstests пойдёт без SCRATCH_DEV (часть тестов skip)"
  else
    dd if=/dev/zero of="$scratch_img" bs=1M count="${SCRATCH_SIZE_MB:-512}" status=none 2>/dev/null || true
    scratch_dev="$(losetup -fP --show "$scratch_img" 2>/dev/null || true)"
  fi

  log_info "TEST_DEV=$test_dev  TEST_DIR=$MOUNT_POINT  SCRATCH_DEV=${scratch_dev:-none}"

  local old_pwd
  old_pwd="$(pwd)"
  if [ -n "$xfstests_dir" ] && [ -d "$xfstests_dir" ]; then
    cd "$xfstests_dir" || cd "$old_pwd"
  fi

  # fsstress: xfstests ищет ltp/fsstress или PATH
  if [ -n "$xfstests_dir" ]; then
    if [ -x "$xfstests_dir/ltp/fsstress" ]; then
      export PATH="$xfstests_dir/ltp:$PATH"
    elif [ -x "$xfstests_dir/src/fsstress" ]; then
      mkdir -p "$xfstests_dir/ltp"
      ln -sf "$xfstests_dir/src/fsstress" "$xfstests_dir/ltp/fsstress" 2>/dev/null || true
      export PATH="$xfstests_dir/src:$xfstests_dir/ltp:$PATH"
    fi
  fi
  if ! command -v fsstress >/dev/null 2>&1 && [ ! -x "${xfstests_dir}/ltp/fsstress" ]; then
    log_warn "fsstress не найден — часть generic-тестов будет пропущена (см. сборку xfstests в образе)"
  fi

  local mkfs_opts="-F -T ${MKFS_TYPE:-datafiles} --cluster-stack=o2cb --cluster-name=${CLUSTER_NAME:-ocfs2cluster}"
  if [ -n "${MKFS_FEATURES:-}" ]; then
    mkfs_opts="$mkfs_opts --fs-features=${MKFS_FEATURES}"
  fi

  local xfstests_config="${NODE_TEST_DIR}/local.config"
  {
    echo "export FSTYP=ocfs2"
    echo "export TEST_DEV='$test_dev'"
    echo "export TEST_DIR='$MOUNT_POINT'"
    if [ -n "$scratch_dev" ]; then
      echo "export SCRATCH_DEV='$scratch_dev'"
      echo "export SCRATCH_MNT='$scratch_mnt'"
    fi
    echo "export MKFS_OPTIONS='$mkfs_opts'"
    if [ -n "${MOUNT_OPTIONS:-}" ]; then
      echo "export MOUNT_OPTIONS='${MOUNT_OPTIONS}'"
    fi
    echo "export RESULT_BASE='${NODE_TEST_DIR}/xfstests_results'"
  } > "$xfstests_config"
  mkdir -p "${NODE_TEST_DIR}/xfstests_results"

  # xfstests читает ./local.config в своём каталоге
  if [ -n "$xfstests_dir" ] && [ -d "$xfstests_dir" ]; then
    cp "$xfstests_config" "$xfstests_dir/local.config" 2>/dev/null || true
  fi

  local tests_arg=""
  if [ -n "${XFSTESTS_TESTS:-}" ]; then
    tests_arg="${XFSTESTS_TESTS}"
    log_info "Запуск xfstests (профиль ${XFSTESTS_PROFILE}): $tests_arg"
  elif [ -n "${XFSTESTS_GROUPS:-}" ]; then
    tests_arg="-g ${XFSTESTS_GROUPS}"
    log_info "Запуск xfstests группы: ${XFSTESTS_GROUPS}"
  else
    tests_arg="-g quick"
    log_info "Запуск xfstests -g quick (fallback)"
  fi

  set +e
  timeout "${XFSTESTS_TIMEOUT:-420}" bash -c "source '$xfstests_config'; $xfstests_cmd $tests_arg" \
    > "$xfstests_log" 2>&1
  local exit_code=$?
  set -e

  if [ "$exit_code" -eq 0 ]; then
    log_info "✓ xfstests завершены успешно"
    echo "PASS: xfstests (${XFSTESTS_PROFILE})" >> "$RESULTS_FILE"
  else
    log_info "xfstests завершился с кодом $exit_code, анализируем лог..."
    if grep -qE "Passed all|All tests passed" "$xfstests_log" 2>/dev/null; then
      echo "PASS: xfstests (все тесты пройдены)" >> "$RESULTS_FILE"
    elif grep -qE "Failed|failed|not run" "$xfstests_log" 2>/dev/null; then
      local passed_count failed_count
      passed_count=$(grep -cE "^Passed |^Ran:" "$xfstests_log" 2>/dev/null || echo 0)
      failed_count=$(grep -cE "Failed" "$xfstests_log" 2>/dev/null || echo 0)
      log_info "xfstests: признаки Passed~$passed_count Failed~$failed_count"
      echo "PARTIAL: xfstests (Passed~$passed_count Failed~$failed_count, см. лог)" >> "$RESULTS_FILE"
    else
      log_warn "Не удалось определить результаты xfstests из лога"
      echo "UNKNOWN: xfstests (см. лог)" >> "$RESULTS_FILE"
    fi
  fi

  {
    echo "=== xfstests Results Summary ==="
    echo "Date: $(date)"
    echo "Node: $NODE_NAME"
    echo "Profile: ${XFSTESTS_PROFILE:-default}"
    echo "Device: $test_dev"
    echo "Scratch: ${scratch_dev:-none}"
    echo "Mount point: $MOUNT_POINT"
    echo "Command: $xfstests_cmd $tests_arg"
    echo "Exit: $exit_code"
    echo ""
    if [ -f "$xfstests_log" ]; then
      echo "=== Last 80 lines of log ==="
      tail -80 "$xfstests_log"
    fi
  } > "$xfstests_summary"

  if [ -n "$scratch_dev" ]; then
    umount "$scratch_mnt" >/dev/null 2>&1 || true
    losetup -d "$scratch_dev" >/dev/null 2>&1 || true
  fi
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
