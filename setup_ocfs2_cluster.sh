#!/bin/bash

# Скрипт настройки OCFS2 кластера

set -euo pipefail

CLUSTER_NAME=$1
TOTAL_NODES=$2
MODE="${3:-bootstrap}"   # bootstrap | heartbeat | register | join

CLUSTER_CONFIG="/etc/ocfs2/cluster.conf"
NODE_ID=$(hostname | sed 's/ocfs2-node-//g' || echo "1")

log_info() {
    echo "[OCFS2] $1"
}

log_warn() {
    echo "[OCFS2] WARN: $1"
}

log_error() {
    echo "[OCFS2] ERROR: $1"
}

log_info "Настройка кластера OCFS2: $CLUSTER_NAME (режим: $MODE)"

# Создание конфигурации кластера только в режиме bootstrap (узел 1)
if [ "$MODE" = "bootstrap" ]; then
  log_info "Создание конфигурации кластера..."
  cat > "$CLUSTER_CONFIG" <<EOF
cluster:
        node_count = $TOTAL_NODES
        name = $CLUSTER_NAME

node:
        ip_port = 7777
        ip_address = 172.20.0.11
        number = 0
        name = ocfs2-node-1
        cluster = $CLUSTER_NAME

EOF
  for i in $(seq 2 $TOTAL_NODES); do
    NODE_IP="172.20.0.$((10 + i))"
    NODE_NAME="ocfs2-node-$i"
    NODE_NUM=$((i - 1))
    cat >> "$CLUSTER_CONFIG" <<EOF
node:
        ip_port = 7777
        ip_address = $NODE_IP
        number = $NODE_NUM
        name = $NODE_NAME
        cluster = $CLUSTER_NAME

EOF
  done
  log_info "Конфигурация кластера создана: $CLUSTER_CONFIG"
elif [ "$MODE" = "heartbeat" ]; then
  log_info "Режим heartbeat: add-heartbeat на /dev/drbd0"
  if [ ! -f "$CLUSTER_CONFIG" ]; then
    log_error "Нет $CLUSTER_CONFIG — сначала bootstrap"
    exit 1
  fi
elif [ "$MODE" = "register" ]; then
  log_info "Режим register: cluster.conf уже есть, heartbeat не трогаем"
  if [ ! -f "$CLUSTER_CONFIG" ]; then
    log_error "Нет $CLUSTER_CONFIG"
    exit 1
  fi
else
  log_info "Режим join: используем существующий $CLUSTER_CONFIG (не перезаписываем)"
  if [ ! -f "$CLUSTER_CONFIG" ] || ! grep -q "heartbeat:" "$CLUSTER_CONFIG"; then
    log_error "В режиме join нужен cluster.conf с heartbeat (скопируйте с узла 1)"
    exit 1
  fi
fi

# Загрузка модулей OCFS2
log_info "Загрузка модулей OCFS2..."
# configfs должен быть загружен первым (нужен для ocfs2_dlmfs)
modprobe configfs || true
# ocfs2_stack_o2cb автоматически загрузит зависимости (ocfs2_stackglue, ocfs2_nodemanager)
modprobe ocfs2_stack_o2cb || true
# ocfs2_dlm зависит от ocfs2_stack_o2cb
modprobe ocfs2_dlm || true
# ocfs2 и ocfs2_dlmfs зависят от ocfs2_stack_o2cb
modprobe ocfs2 || true
modprobe ocfs2_dlmfs || true

# Монтирование configfs
log_info "Монтирование configfs..."
mkdir -p /sys/kernel/config
mount -t configfs none /sys/kernel/config >/dev/null 2>&1 || true

# Запуск o2cb
log_info "Запуск o2cb..."
if [ -f /etc/init.d/o2cb ]; then
    /etc/init.d/o2cb start || true
elif command -v systemctl &> /dev/null; then
    systemctl start o2cb || true
fi

# Очистка только в режиме bootstrap (на join не трогаем config и не удаляем регионы)
# o2cb может падать с SIGSEGV если кластер не зарегистрирован — выполняем в subshell с set +e
if [ "$MODE" = "bootstrap" ]; then
  log_info "Очистка старых heartbeat регионов и процессов..."
  ( set +e
    o2cb stop-heartbeat "$CLUSTER_NAME" >/dev/null 2>&1
    o2cb list-heartbeats "$CLUSTER_NAME" 2>/dev/null | while IFS= read -r line; do
      if echo "$line" | grep -q "region ="; then
        hb_region=$(echo "$line" | grep -oP 'region = \K[^\s]+' || echo '')
        [ -n "$hb_region" ] && o2cb remove-heartbeat "$CLUSTER_NAME" "$hb_region" >/dev/null 2>&1
      fi
    done
    o2cb list-heartbeats "$CLUSTER_NAME" 2>/dev/null | grep -q "/dev/drbd0" && \
      o2cb remove-heartbeat "$CLUSTER_NAME" /dev/drbd0 >/dev/null 2>&1
    o2cb unregister-cluster "$CLUSTER_NAME" >/dev/null 2>&1
  ) || true
  sleep 1
elif [ "$MODE" = "heartbeat" ]; then
  log_info "Сброс старых heartbeat-регионов перед add-heartbeat на /dev/drbd0..."
  ( set +e
    o2cb stop-heartbeat "$CLUSTER_NAME" >/dev/null 2>&1
    o2cb list-heartbeats "$CLUSTER_NAME" 2>/dev/null | while IFS= read -r line; do
      if echo "$line" | grep -q "region ="; then
        hb_region=$(echo "$line" | grep -oP 'region = \K[^\s]+' || echo '')
        [ -n "$hb_region" ] && o2cb remove-heartbeat "$CLUSTER_NAME" "$hb_region" >/dev/null 2>&1
      fi
    done
    o2cb remove-heartbeat "$CLUSTER_NAME" /dev/drbd0 >/dev/null 2>&1
    o2cb remove-heartbeat "$CLUSTER_NAME" /tmp/o2hb_region.img >/dev/null 2>&1
  ) || true
  sleep 1
elif [ "$MODE" = "register" ]; then
  :
else
  log_info "Режим join: только остановка heartbeat (config не трогаем)..."
  ( set +e; o2cb stop-heartbeat "$CLUSTER_NAME" >/dev/null 2>&1 ) || true
  sleep 1
fi

# Регистрация кластера
log_info "Регистрация кластера..."
o2cb register-cluster "$CLUSTER_NAME" || true

if [ "$MODE" = "bootstrap" ]; then
  log_info "cluster.conf записан, кластер зарегистрирован"
  log_info "Кластер OCFS2 настроен"
  exit 0
fi

if [ "$MODE" = "register" ]; then
  log_info "Узел зарегистрирован"
  log_info "Кластер OCFS2 настроен"
  exit 0
fi

if [ "$MODE" = "heartbeat" ]; then
  DRBD_DEV="/dev/drbd0"
  for wait_attempt in 1 2 3 4 5 6 7 8 9 10; do
    if [ -b "$DRBD_DEV" ]; then
      break
    fi
    log_warn "Ожидание $DRBD_DEV... ($wait_attempt/10)"
    sleep 2
  done
  if [ ! -b "$DRBD_DEV" ]; then
    log_error "Устройство $DRBD_DEV недоступно"
    exit 1
  fi

  o2cb heartbeat-mode local "$CLUSTER_NAME" >/dev/null 2>&1 || true
  O2CB_ADD="o2cb"
  for candidate in /usr/sbin/o2cb /usr/bin/o2cb o2cb; do
    if command -v "$candidate" >/dev/null 2>&1; then
      O2CB_ADD="$candidate"
      break
    fi
  done
  log_info "add-heartbeat $DRBD_DEV ($O2CB_ADD)..."
  add_ok=0
  for attempt in 1 2 3 4 5; do
    if "$O2CB_ADD" add-heartbeat "$CLUSTER_NAME" "$DRBD_DEV" >/dev/null 2>&1; then
      add_ok=1
      break
    fi
    sleep 2
  done
  if [ "$add_ok" -eq 0 ]; then
    log_error "Не удалось добавить heartbeat-регион на $DRBD_DEV"
    exit 1
  fi
  sleep 1
  if ! grep -q "heartbeat:" "$CLUSTER_CONFIG"; then
    log_error "В $CLUSTER_CONFIG нет секции heartbeat после add-heartbeat"
    exit 1
  fi
  log_info "Heartbeat-регион добавлен, секция heartbeat есть в $CLUSTER_CONFIG"
else
  o2cb heartbeat-mode local "$CLUSTER_NAME" >/dev/null 2>&1 || true
  log_info "Join: используем heartbeat-регион из cluster.conf (не вызываем add-heartbeat)"
fi

log_info "Запуск heartbeat..."
heartbeat_started=0
for attempt in 1 2 3 4 5; do
  if o2cb start-heartbeat "$CLUSTER_NAME" 2>&1; then
    heartbeat_started=1
    log_info "✓ Heartbeat запущен (попытка $attempt)"
    break
  else
    log_warn "Не удалось запустить heartbeat (попытка $attempt/5), повтор через 2s..."
    sleep 2
  fi
done

if [ "$heartbeat_started" -eq 0 ]; then
  log_error "Не удалось запустить heartbeat после 5 попыток"
  log_error "Проверьте: o2cb list-heartbeats $CLUSTER_NAME"
  log_error "Проверьте: dmesg | tail -20"
  exit 1
fi

sleep 3

# Проверка статуса кластера
log_info "Проверка статуса кластера..."
cluster_online=0
for i in $(seq 1 20); do
  if o2cb cluster-status "$CLUSTER_NAME" >/dev/null 2>&1; then
    cluster_online=1
    log_info "✓ Кластер онлайн"
    break
  else
    log_info "Ожидание готовности кластера... ($i/20)"
    sleep 1
  fi
done

if [ "$cluster_online" -eq 0 ]; then
  log_warn "Кластер не стал онлайн после 20 попыток"
  log_warn "Проверьте: o2cb cluster-status $CLUSTER_NAME"
  log_warn "Проверьте: o2cb list-heartbeats $CLUSTER_NAME"
  log_warn "Проверьте: dmesg | tail -30"
fi

# Проверка сетевой связности между узлами
log_info "Проверка сетевой связности..."
NODE_ID=$(hostname | sed 's/ocfs2-node-//g')
for i in $(seq 1 $TOTAL_NODES); do
  if [ "$i" != "$NODE_ID" ]; then
    TARGET_IP="172.20.0.$((10 + i))"
    if ping -c 1 -W 1 "$TARGET_IP" >/dev/null 2>&1; then
      log_info "✓ Связь с $TARGET_IP установлена"
    else
      log_warn "Нет связи с $TARGET_IP"
    fi
  fi
done

log_info "Кластер OCFS2 настроен"
