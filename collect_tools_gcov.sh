#!/bin/bash

# Сбор line-coverage для ocfs2-tools (userspace) в виде lcov tracefile.
# Скрипт запускается ВНУТРИ контейнера на каждом узле.
# Далее tracefile сливаются на узле-1 и генерируется единый HTML отчёт.

set -euo pipefail

NODE_ID=${1:-1}

REPORT_ROOT="/tmp/gcov_reports"
SRC_DIR="/opt/ocfs2-tools-src"
OUT_INFO="${REPORT_ROOT}/ocfs2_tools_node${NODE_ID}.info"

log() { echo "[TOOLS LCOV node=${NODE_ID}] $*"; }

mkdir -p "${REPORT_ROOT}"

if ! command -v lcov >/dev/null 2>&1; then
  log "lcov не установлен в контейнере. Пропуск."
  exit 0
fi

if [ ! -d "${SRC_DIR}" ]; then
  log "Исходники ocfs2-tools не найдены (${SRC_DIR}). Сборка образа должна была упасть — проверьте Docker build."
  exit 0
fi

gcda_count="$(find "${SRC_DIR}" -name '*.gcda' 2>/dev/null | wc -l | tr -d ' ')"
if [ "${gcda_count}" = "0" ]; then
  log "ВНИМАНИЕ: *.gcda не найдены в ${SRC_DIR}. Это означает, что покрываемые бинарники ещё не выполнялись на этом узле."
fi

log "lcov --capture из ${SRC_DIR}..."
if lcov --capture --directory "${SRC_DIR}" --output-file "${OUT_INFO}" --ignore-errors mismatch,unused,empty 2>&1; then
  log "✓ Захват данных выполнен"
else
  log "WARN: Ошибка при захвате данных (возможно, нет .gcda файлов)"
fi

# Проверяем, что файл создался
if [ ! -f "${OUT_INFO}" ]; then
  log "ERROR: Файл ${OUT_INFO} не создан после захвата"
  exit 1
fi

# Оставляем только собственное дерево исходников, отбрасываем системные заголовки
if lcov --extract "${OUT_INFO}" "${SRC_DIR}/*" --output-file "${OUT_INFO}.tmp" --ignore-errors unused,empty 2>&1; then
  mv -f "${OUT_INFO}.tmp" "${OUT_INFO}"
  log "✓ Извлечение данных выполнено"
else
  log "WARN: Ошибка при извлечении данных, используем исходный файл"
fi

# Проверяем размер файла
if [ -f "${OUT_INFO}" ]; then
  file_size=$(stat -c%s "${OUT_INFO}" 2>/dev/null || echo "0")
  if [ "$file_size" -gt 0 ]; then
    log "✓ Готово: ${OUT_INFO} (размер: $file_size байт)"
  else
    log "WARN: Файл ${OUT_INFO} пуст (размер: $file_size байт)"
  fi
else
  log "ERROR: Файл ${OUT_INFO} не существует"
  exit 1
fi
