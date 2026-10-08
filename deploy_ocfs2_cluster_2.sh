#!/bin/bash
# Конфигурация 2: xfstests «features» — xattr, ACL, indexed dirs, refcount/reflink.
# Использование: sudo ./deploy_ocfs2_cluster_2.sh N
#                sudo ./deploy_ocfs2_cluster_2.sh cleanup
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export XFSTESTS_PROFILE="${XFSTESTS_PROFILE:-features}"
export OCFS2_XFSTESTS_CONF="${OCFS2_XFSTESTS_CONF:-$SCRIPT_DIR/xfstests_configs/features.env}"
exec "$SCRIPT_DIR/deploy_ocfs2_cluster.sh" "$@"
