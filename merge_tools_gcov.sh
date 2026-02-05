#!/bin/bash
# Объединение lcov tracefile от всех узлов и генерация HTML внутри контейнера (где есть исходники).

set -euo pipefail

TOTAL_NODES=${1:-1}
REPORT_ROOT="/tmp/gcov_reports"
IN_DIR="${REPORT_ROOT}/merge_inputs"
OUT_HTML="${REPORT_ROOT}/tools_html"
MERGED_INFO="${REPORT_ROOT}/ocfs2_tools_merged.info"

log() { echo "[TOOLS MERGE] $*"; }

mkdir -p "${OUT_HTML}"
if ! command -v lcov >/dev/null 2>&1 || ! command -v genhtml >/dev/null 2>&1; then
  log "lcov/genhtml не установлены. Пропуск."
  exit 0
fi

# Собираем список .info
infos=()
for i in $(seq 1 "${TOTAL_NODES}"); do
  f="${IN_DIR}/ocfs2_tools_node${i}.info"
  if [ -f "$f" ]; then
    infos+=("$f")
  fi
done

if [ "${#infos[@]}" -eq 0 ]; then
  log "Нет входных tracefile в ${IN_DIR}. Пропуск."
  exit 0
fi

log "Слияние ${#infos[@]} tracefile..."
tmp="${REPORT_ROOT}/_tmp_merge.info"
cp "${infos[0]}" "${tmp}"
if [ "${#infos[@]}" -gt 1 ]; then
  for f in "${infos[@]:1}"; do
    lcov -a "${tmp}" -a "${f}" -o "${tmp}.next" --ignore-errors mismatch,unused,empty || true
    mv -f "${tmp}.next" "${tmp}"
  done
fi
mv -f "${tmp}" "${MERGED_INFO}"

log "Генерация HTML..."
genhtml "${MERGED_INFO}" --output-directory "${OUT_HTML}" \
  --ignore-errors source,unused,empty,unreachable,negative \
  --no-branch-coverage \
  --prefix "/opt/ocfs2-tools-src" \
  2>&1 | grep -v "WARNING.*source" || true

if [[ -f "${OUT_HTML}/index.html" ]] && [[ -s "${OUT_HTML}/index.html" ]]; then
  log "✓ Готово: ${OUT_HTML}/index.html"
else
  log "WARN: HTML не создан или пуст, пробуем без исходников..."
  genhtml "${MERGED_INFO}" --output-directory "${OUT_HTML}" \
    --ignore-errors source,unused,empty,unreachable,negative \
    --no-branch-coverage \
    --no-source \
    2>&1 | grep -v "WARNING.*source" || true
  if [[ -f "${OUT_HTML}/index.html" ]]; then
    log "✓ Готово: ${OUT_HTML}/index.html (без исходников)"
  else
    log "ERROR: Не удалось создать HTML отчёт"
  fi
fi
