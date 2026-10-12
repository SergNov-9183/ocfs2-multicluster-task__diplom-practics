#!/bin/bash
#
# Последовательный прогон трёх конфигураций xfstests (default, features, cluster)
# и отчёт с объединением покрытых строк.
#
#   sudo ./deploy_ocfs2_all.sh 4
#   sudo ./deploy_ocfs2_all.sh cleanup
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
log_info() { printf '\n'; echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { printf '\n'; echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { printf '\n'; echo -e "${RED}[ERROR]${NC} $*"; }

case "${1:-}" in
  clean|cleanup)
    exec "$SCRIPT_DIR/deploy_ocfs2_cluster.sh" cleanup
    ;;
esac

CLI_NODES=""
for _arg in "$@"; do
  case "$_arg" in
    [1-8]) CLI_NODES="$_arg" ;;
  esac
done
N="${CLI_NODES:-4}"

latest_report() {
  local p="$1"
  ls -dt "$SCRIPT_DIR"/gcov_reports_${p}_* 2>/dev/null | head -1 || true
}

log_info "Конфигурация 1/3: default, узлов: $N"
"$SCRIPT_DIR/deploy_ocfs2_cluster.sh" "$N"
d1="$(latest_report default)"
if [[ -z "$d1" || ! -d "$d1" ]]; then
  log_error "Нет отчёта default"
  exit 1
fi

log_info "Конфигурация 2/3: features, узлов: $N"
"$SCRIPT_DIR/deploy_ocfs2_cluster_2.sh" "$N"
d2="$(latest_report features)"
if [[ -z "$d2" || ! -d "$d2" ]]; then
  log_error "Нет отчёта features"
  exit 1
fi

log_info "Конфигурация 3/3: cluster, узлов: $N"
"$SCRIPT_DIR/deploy_ocfs2_cluster_3.sh" "$N"
d3="$(latest_report cluster)"
if [[ -z "$d3" || ! -d "$d3" ]]; then
  log_error "Нет отчёта cluster"
  exit 1
fi

stamp="$(date +%Y%m%d_%H%M%S)_$$"
out="$SCRIPT_DIR/gcov_reports_merged_${stamp}"
mkdir -p "$out"
ln -sfn "$(realpath --relative-to="$out" "$d1")" "$out/default"
ln -sfn "$(realpath --relative-to="$out" "$d2")" "$out/features"
ln -sfn "$(realpath --relative-to="$out" "$d3")" "$out/cluster"

if command -v lcov >/dev/null 2>&1; then
  infos=()
  for d in "$d1" "$d2" "$d3"; do
    if [[ -f "$d/kernel_ocfs2.info" ]] && grep -q '^DA:' "$d/kernel_ocfs2.info" 2>/dev/null; then
      infos+=("$d/kernel_ocfs2.info")
    fi
  done
  if [[ ${#infos[@]} -ge 2 ]]; then
    lcov_cmd=(lcov)
    for inf in "${infos[@]}"; do
      lcov_cmd+=(-a "$inf")
    done
    lcov_cmd+=(-o "$out/kernel_ocfs2.info" --ignore-errors source,unused,empty)
    "${lcov_cmd[@]}" >/dev/null 2>&1 || true
  fi
fi

log_info "Объединение покрытия строк..."
python3 "$SCRIPT_DIR/coverage/generate_ocfs2_html_report.py" \
  --src "$SCRIPT_DIR/coverage/ocfs2_src" \
  --out "$out/kernel_html" \
  --report-root "$out" \
  --profile merged \
  --nodes "$N" \
  --merge-dirs "$d1" "$d2" "$d3"

rm -rf "$out"/node_*_gcov
if [[ -d "$out/tools_tracefiles" ]] && [[ -z "$(ls -A "$out/tools_tracefiles" 2>/dev/null || true)" ]]; then
  rmdir "$out/tools_tracefiles" 2>/dev/null || true
fi
if [[ -d "$out/tools_html" ]] && [[ ! -f "$out/tools_html/index.html" ]] && [[ -z "$(ls -A "$out/tools_html" 2>/dev/null || true)" ]]; then
  rmdir "$out/tools_html" 2>/dev/null || true
fi
chmod -R a+rX "$out" 2>/dev/null || true
if [[ -n "${SUDO_USER:-}" ]]; then
  chown -R "${SUDO_USER}:" "$out" 2>/dev/null || true
fi

log_info "✓ Объединённый отчёт: $out/index.html"
if [[ -f "$out/kernel_html/index.html" ]]; then
  log_info "✓ Kernel HTML: $out/kernel_html/index.html"
fi
for i in $(seq 1 "$N"); do
  if [[ -f "$out/node_${i}_tests/kernel_html/index.html" ]]; then
    log_info "✓ Покрытие ocfs2-node-$i: $out/node_${i}_tests/kernel_html/index.html"
  fi
done
