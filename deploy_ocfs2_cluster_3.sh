#!/bin/bash
# Конфигурация 3: xfstests «cluster» — блокировки, параллельный I/O, DLM.
# Рекомендуется N>=2. Использование: sudo ./deploy_ocfs2_cluster_3.sh N
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export XFSTESTS_PROFILE="${XFSTESTS_PROFILE:-cluster}"
export OCFS2_XFSTESTS_CONF="${OCFS2_XFSTESTS_CONF:-$SCRIPT_DIR/xfstests_configs/cluster.env}"
exec "$SCRIPT_DIR/deploy_ocfs2_cluster.sh" "$@"
