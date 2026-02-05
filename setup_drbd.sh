#!/bin/bash
# Настройка DRBD внутри контейнера.
# Важно: все контейнеры используют одно ядро хоста, поэтому полноценную двухузловую репликацию DRBD
# в Docker на одном хосте сделать нельзя без отдельных VM/ядер.
# В данном стенде DRBD используется как нижележащий блочный девайс для iSCSI target.
# Инициализация ресурса выполняется только на ocfs2-node-1, остальные ноды DRBD не трогают.

set -euo pipefail

NODE_ID="${1:?node id}"
TOTAL_NODES="${2:?total nodes}"
RESOURCE_NAME="${3:?resource name}"
DEVICE="${4:?device}"   # ожидается /dev/drbd0

log() { echo "[DRBD Node ${NODE_ID}] $*"; }

if [ "$NODE_ID" != "1" ]; then
  log "Пропуск DRBD (инициализация выполняется только на ocfs2-node-1)"
  exit 0
fi

mkdir -p /run/lock /var/lock /tmp /var/lib/drbd

# Backing file для DRBD (локальный диск внутри контейнера; loop-девайсы глобальны по ядру хоста)
LOOP_FILE="/var/lib/drbd/${RESOURCE_NAME}_backing.img"
if [ ! -f "$LOOP_FILE" ]; then
  log "Создание backing файла: $LOOP_FILE (1024M)"
  truncate -s 1024M "$LOOP_FILE"
fi

# Привязка к loop устройству (идемпотентно)
existing_loop="$(losetup -j "$LOOP_FILE" | awk -F: 'NR==1{print $1}' || true)"
if [ -n "${existing_loop:-}" ]; then
  LOOP_DEV="$existing_loop"
  log "Backing файл уже привязан к $LOOP_DEV"
else
  LOOP_DEV="$(losetup -fP --show "$LOOP_FILE")"
  log "Backing file: $LOOP_FILE -> $LOOP_DEV"
fi

DRBD_CONFIG="/etc/drbd.d/${RESOURCE_NAME}.res"
NODE_NAME="ocfs2-node-1"
NODE_IP="172.20.0.11"

log "Генерация DRBD конфигурации: $DRBD_CONFIG"
cat > "$DRBD_CONFIG" <<CONF
resource ${RESOURCE_NAME} {
    protocol C;

    disk {
        on-io-error detach;
        no-disk-flushes;
        no-disk-barrier;
    }

    net {
        sndbuf-size 0;
        rcvbuf-size 0;
    }

    on ${NODE_NAME} {
        device    ${DEVICE};
        disk      ${LOOP_DEV};
        meta-disk internal;
        address   ${NODE_IP}:7789;
    }
}
CONF

log "Загрузка модулей DRBD"
modprobe drbd >/dev/null 2>&1 || true
modprobe drbd_transport_tcp >/dev/null 2>&1 || true

if [ ! -e /proc/drbd ]; then
  log "ОШИБКА: /proc/drbd отсутствует. На host должен быть загружен модуль drbd (DRBD kernel module)."
  exit 2
fi

# Сброс предыдущего состояния ресурса (идемпотентно)
log "Сброс предыдущего состояния ресурса (если было)"
drbdadm down "$RESOURCE_NAME" >/dev/null 2>&1 || true
drbdsetup down "$RESOURCE_NAME" >/dev/null 2>&1 || true

# create-md + up
log "Инициализация DRBD meta-data"
drbdadm -v create-md "$RESOURCE_NAME" --force

log "Подъём DRBD ресурса"
drbdadm -v up "$RESOURCE_NAME"

# делаем primary, иначе блочный девайс может быть RO
log "Перевод ресурса в Primary"
drbdadm -v primary --force "$RESOURCE_NAME"

# ожидание появления устройства
for i in $(seq 1 30); do
  if [ -b "$DEVICE" ]; then
    break
  fi
  sleep 0.2
done
if [ ! -b "$DEVICE" ]; then
  log "ОШИБКА: блочный девайс $DEVICE не появился"
  exit 3
fi

log "DRBD готов: $DEVICE"
