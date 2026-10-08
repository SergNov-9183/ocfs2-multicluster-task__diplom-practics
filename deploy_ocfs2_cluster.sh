#!/bin/bash
#
# deploy_ocfs2_cluster.sh
# Развёртывание OCFS2-кластера в Docker поверх общего DRBD-девайса, который поднимается на host.
# Сценарий ориентирован на single-host (все контейнеры на одной машине).
#
# Использование:
#   sudo ./deploy_ocfs2_cluster.sh 4          # профиль default (generic xfstests)
#   sudo ./deploy_ocfs2_cluster.sh 1          # 1 узел
#   sudo ./deploy_ocfs2_cluster_2.sh 1        # профиль features (xattr/acl/refcount)
#   sudo ./deploy_ocfs2_cluster_3.sh 2        # профиль cluster (DLM/locks, лучше N>=2)
#   sudo ./deploy_ocfs2_cluster.sh cleanup
#
set -euo pipefail

case "${1:-}" in
  clean|cleanup) ACTION="cleanup" ;;
  *) ACTION="deploy" ;;
esac

# Число узлов — любая цифра 1..8 в argv.
CLI_NODES=""
for _arg in "$@"; do
  case "$_arg" in
    [1-8]) CLI_NODES="$_arg" ;;
  esac
done
unset _arg

if [[ "$ACTION" == "cleanup" ]]; then
  NODES=8
else
  NODES="${CLI_NODES:-4}"
fi

CLUSTER_NAME="ocfs2cluster"               # только [A-Za-z0-9]
DRBD_RESOURCE="ocfs2-resource"
DRBD_DEVICE="/dev/drbd0"
MOUNT_POINT="/mnt/ocfs2"
NETWORK_NAME="ocfs2-network"
IMAGE_NAME="ocfs2-node:latest"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
XFSTESTS_PROFILE="${XFSTESTS_PROFILE:-default}"
OCFS2_XFSTESTS_CONF="${OCFS2_XFSTESTS_CONF:-$SCRIPT_DIR/xfstests_configs/${XFSTESTS_PROFILE}.env}"
if [[ -f "$OCFS2_XFSTESTS_CONF" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$OCFS2_XFSTESTS_CONF"
  set +a
fi
if [[ "$ACTION" == "cleanup" ]]; then
  NODES=8
else
  NODES="${CLI_NODES:-4}"
fi
export OCFS2_NODES="$NODES"

# Минимально рекомендуется >= 2G, иначе mkfs.ocfs2 откажется.
BACKING_SIZE="${BACKING_SIZE:-4G}"

# --- Логи: каждое сообщение с новой строки (без вкраплений вывода команд) ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info() { printf '\n'; echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { printf '\n'; echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { printf '\n'; echo -e "${RED}[ERROR]${NC} $*"; }

# --- Проверки/утилиты ---
require_cmd() {
  local c="$1"
  command -v "$c" >/dev/null 2>&1 || { log_error "Команда не найдена: $c"; exit 1; }
}

ensure_lcov_on_host() {
  if command -v lcov >/dev/null 2>&1 && command -v genhtml >/dev/null 2>&1; then
    return 0
  fi
  log_warn "На host не установлены lcov/genhtml — установим через apt (нужен интернет)."
  sudo apt-get update
  sudo apt-get install -y lcov
}

ensure_debugfs() {
  sudo mkdir -p /sys/kernel/debug
  sudo mount -t debugfs debugfs /sys/kernel/debug >/dev/null 2>&1 || true
}

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    log_warn "Docker не найден."
    return 1
  fi
  if docker info >/dev/null 2>&1; then
    return 0
  fi
  log_warn "Docker daemon недоступен."
  return 1
}

ensure_host_drbd9() {
  log_info "Проверка DRBD на host..."
  sudo modprobe drbd >/dev/null 2>&1 || true
  sudo modprobe drbd_transport_tcp >/dev/null 2>&1 || true

  if [[ ! -r /proc/drbd ]]; then
    if ! command -v drbdadm >/dev/null 2>&1; then
      log_warn "/proc/drbd отсутствует. Пытаемся установить drbd-utils + drbd-dkms (нужен интернет)."
      sudo apt-get update
      sudo apt-get install -y drbd-utils drbd-dkms || true
    else
      log_warn "/proc/drbd отсутствует, drbd-utils уже установлены — пробуем только modprobe."
    fi
    sudo modprobe drbd >/dev/null 2>&1 || true
    sudo modprobe drbd_transport_tcp >/dev/null 2>&1 || true
  fi

  if [[ ! -r /proc/drbd ]]; then
    log_warn "DRBD на host недоступен (/proc/drbd отсутствует или модуль не загружается)."
    return 1
  fi

  if ! grep -Eq 'version:\s*9\.' /proc/drbd; then
    log_error "Нужен DRBD 9.x. Текущее состояние /proc/drbd:"
    cat /proc/drbd || true
    return 1
  fi

  log_info "DRBD9 на host обнаружен."
  return 0
}

cleanup_host_drbd() {
  log_info "Очистка DRBD/loop артефактов на host..."

  # Размонтировать, если вдруг смонтировано на host
  sudo umount "$MOUNT_POINT" >/dev/null 2>&1 || true
  
  # Закрыть устройство, если открыто
  if [[ -b "${DRBD_DEVICE}" ]]; then
    sudo blockdev --flushbufs "${DRBD_DEVICE}" >/dev/null 2>&1 || true
  fi

  # Остановить ресурс (сначала secondary, потом down)
  sudo drbdadm secondary "${DRBD_RESOURCE}" >/dev/null 2>&1 || true
  sudo drbdadm disconnect "${DRBD_RESOURCE}" >/dev/null 2>&1 || true
  sudo drbdadm down "${DRBD_RESOURCE}" >/dev/null 2>&1 || true
  
  # Остановка через drbdsetup (DRBD 9.x синтаксис)
  sudo drbdsetup down "${DRBD_RESOURCE}" >/dev/null 2>&1 || true
  sudo drbdsetup del-minor "${DRBD_RESOURCE}" 0 >/dev/null 2>&1 || true
  sudo drbdsetup del-resource "${DRBD_RESOURCE}" >/dev/null 2>&1 || true
  
  sudo rm -f "/etc/drbd.d/${DRBD_RESOURCE}.res" >/dev/null 2>&1 || true

  # Отцепить loop устройства, которые указывают на /var/lib/drbd/*
  if [[ -d /var/lib/drbd ]]; then
    sudo losetup -a 2>/dev/null | awk '/\/var\/lib\/drbd\//{print $1}' | tr -d ':' | while read -r loopdev; do
      [[ -n "${loopdev:-}" ]] || continue
      sudo losetup -d "$loopdev" >/dev/null 2>&1 || true
    done || true
    sudo rm -f /var/lib/drbd/*.img >/dev/null 2>&1 || true
  fi

  # Перезагрузка модуля (на случай залипших minors)
  if ls /sys/devices/virtual/block/drbd* >/dev/null 2>&1; then
    log_warn "Обнаружены drbd minors — перезагружаем модуль drbd..."
    sudo modprobe -r drbd_transport_tcp drbd >/dev/null 2>&1 || true
    sudo modprobe drbd >/dev/null 2>&1 || true
    sudo modprobe drbd_transport_tcp >/dev/null 2>&1 || true
  fi
}

ensure_clean_drbd_minors() {
  if ! ls /sys/devices/virtual/block/drbd* >/dev/null 2>&1; then
    return 0
  fi

  log_warn "В ядре уже есть drbd minors (например drbd0). Проверяем, можно ли переиспользовать..."
  
  # Проверяем, существует ли уже наш ресурс и соответствует ли он нужному
  if sudo drbdsetup status "${DRBD_RESOURCE}" >/dev/null 2>&1; then
    local current_device
    current_device="$(sudo drbdsetup status "${DRBD_RESOURCE}" 2>/dev/null | grep -oP 'device:\s*\K[^\s]+' || echo '')"
    if [[ "$current_device" == "${DRBD_DEVICE}" ]] || [[ -n "$current_device" ]]; then
      log_info "Найден существующий ресурс ${DRBD_RESOURCE} на ${current_device:-${DRBD_DEVICE}}"
      log_info "Попытка переиспользовать существующий ресурс..."
      
      # Проверяем, что устройство не занято процессами
      if ! sudo lsof "${DRBD_DEVICE}" >/dev/null 2>&1 && ! sudo fuser "${DRBD_DEVICE}" >/dev/null 2>&1; then
        log_info "Устройство свободно, переиспользуем существующий ресурс"
        return 0
      else
        log_warn "Устройство занято процессами, пытаемся очистить..."
      fi
    fi
  fi

  log_warn "Пытаемся очистить существующие ресурсы..."
  cleanup_host_drbd

  if ls /sys/devices/virtual/block/drbd* >/dev/null 2>&1; then
    log_warn "drbd minors всё ещё присутствуют после очистки."
    
    # Проверяем, можно ли переиспользовать существующий ресурс
    if sudo drbdsetup status "${DRBD_RESOURCE}" >/dev/null 2>&1; then
      log_info "Ресурс ${DRBD_RESOURCE} существует. Проверяем возможность переиспользования..."
      local status_info
      status_info="$(sudo drbdsetup status "${DRBD_RESOURCE}" 2>/dev/null || echo '')"
      if echo "$status_info" | grep -q "role:Primary" && [[ -b "${DRBD_DEVICE}" ]]; then
        log_info "Ресурс ${DRBD_RESOURCE} активен и готов к использованию. Переиспользуем его."
        return 0
      fi
    fi
    
    log_warn "Попытка принудительно остановить ресурс через drbdsetup..."
    
    # Останавливаем конкретный ресурс (DRBD 9.x синтаксис)
    sudo drbdsetup down "${DRBD_RESOURCE}" >/dev/null 2>&1 || true
    sudo drbdsetup del-minor "${DRBD_RESOURCE}" 0 >/dev/null 2>&1 || true
    sudo drbdsetup del-resource "${DRBD_RESOURCE}" >/dev/null 2>&1 || true
    
    # Ещё раз попробуем выгрузить модуль
    sudo modprobe -r drbd_transport_tcp drbd >/dev/null 2>&1 || true
    sleep 2
    sudo modprobe drbd >/dev/null 2>&1 || true
    sudo modprobe drbd_transport_tcp >/dev/null 2>&1 || true
    
    if ls /sys/devices/virtual/block/drbd* >/dev/null 2>&1; then
      log_warn "Не удалось полностью очистить drbd minors."
      log_warn "Попробуем переиспользовать существующий ресурс, если он соответствует нашим требованиям..."
      
      # Проверяем, соответствует ли существующий ресурс нашим требованиям
      if sudo drbdsetup status "${DRBD_RESOURCE}" >/dev/null 2>&1 && [[ -b "${DRBD_DEVICE}" ]]; then
        log_info "Обнаружен существующий ресурс ${DRBD_RESOURCE} на ${DRBD_DEVICE}"
        log_info "Переиспользуем его вместо создания нового"
        return 0
      else
        log_error "Существующий ресурс не соответствует требованиям."
        log_error "Попробуйте вручную: sudo drbdsetup down ${DRBD_RESOURCE} && sudo drbdsetup del-resource ${DRBD_RESOURCE}"
        ls -d /sys/devices/virtual/block/drbd* 2>/dev/null || true
        exit 1
      fi
    fi
  fi

  log_info "drbd minors очищены."
}

host_setup_drbd_single() {
  log_info "Настройка DRBD на host (single-node)..."
  sudo modprobe loop >/dev/null 2>&1 || true
  sudo modprobe drbd >/dev/null 2>&1 || true
  sudo modprobe drbd_transport_tcp >/dev/null 2>&1 || true

  sudo mkdir -p /var/lib/drbd /etc/drbd.d
  local backing_file="/var/lib/drbd/${DRBD_RESOURCE}_backing.img"

  # Проверяем, существует ли уже активный ресурс
  if sudo drbdsetup status "${DRBD_RESOURCE}" >/dev/null 2>&1 && [[ -b "${DRBD_DEVICE}" ]]; then
    log_info "Ресурс ${DRBD_RESOURCE} уже существует и активен на ${DRBD_DEVICE}"
    log_info "Проверяем, можно ли его использовать..."
    
    # Проверяем статус
    local status_output
    status_output="$(sudo drbdsetup status "${DRBD_RESOURCE}" 2>/dev/null || echo '')"
    if echo "$status_output" | grep -q "role:Primary"; then
      log_info "Ресурс уже в состоянии Primary, переиспользуем его"
      return 0
    else
      log_info "Ресурс существует, но не в Primary. Переводим в Primary..."
      sudo drbdadm primary "${DRBD_RESOURCE}" --force >/dev/null 2>&1 || true
      return 0
    fi
  fi

  if [[ ! -f "$backing_file" ]]; then
    log_info "Создание backing файла: $backing_file (${BACKING_SIZE})"
    sudo truncate -s "${BACKING_SIZE}" "$backing_file"
  else
    # если файл есть, но меньше 2G — увеличим
    local sz
    sz="$(sudo stat -c%s "$backing_file" 2>/dev/null || echo 0)"
    if [[ "${sz:-0}" -lt 2147483648 ]]; then
      log_warn "backing файл меньше 2GiB — увеличиваем до ${BACKING_SIZE}"
      sudo truncate -s "${BACKING_SIZE}" "$backing_file"
    fi
  fi

  # loop attach (идемпотентно)
  local loop_dev
  loop_dev="$(sudo losetup -j "$backing_file" | awk -F: 'NR==1{print $1}' || true)"
  if [[ -z "${loop_dev:-}" ]]; then
    loop_dev="$(sudo losetup -fP --show "$backing_file")"
  fi

  local host_name
  host_name="$(uname -n)"

  sudo rm -f "/etc/drbd.d/${DRBD_RESOURCE}.res" >/dev/null 2>&1 || true
  sudo tee "/etc/drbd.d/${DRBD_RESOURCE}.res" >/dev/null <<EOF
resource ${DRBD_RESOURCE} {
  protocol C;
  disk { on-io-error detach; }

  on ${host_name} {
    node-id   0;
    device    ${DRBD_DEVICE};
    disk      ${loop_dev};
    meta-disk internal;
    address   127.0.0.1:7789;
  }
}
EOF

  sudo drbdadm down "${DRBD_RESOURCE}" >/dev/null 2>&1 || true
  sudo drbdsetup down "${DRBD_RESOURCE}" >/dev/null 2>&1 || true

  log_info "Инициализация метаданных DRBD..."
  sudo drbdadm create-md "${DRBD_RESOURCE}" --force
  log_info "Подъём ресурса DRBD..."
  sudo drbdadm up "${DRBD_RESOURCE}"
  log_info "Перевод ресурса в Primary..."
  sudo drbdadm primary "${DRBD_RESOURCE}" --force

  for _ in $(seq 1 60); do
    [[ -b "${DRBD_DEVICE}" ]] && break
    sleep 0.1
  done

  if [[ ! -b "${DRBD_DEVICE}" ]]; then
    log_error "DRBD устройство ${DRBD_DEVICE} не появилось. Проверьте: sudo drbdadm status"
    exit 1
  fi

  log_info "DRBD готов: ${DRBD_DEVICE}"
}

create_network() {
  log_info "Создание Docker сети..."
  if docker network ls | grep -q "$NETWORK_NAME"; then
    log_warn "Сеть $NETWORK_NAME уже существует — удаляем..."
    docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
  fi
  docker network create --subnet=172.20.0.0/16 "$NETWORK_NAME" >/dev/null
  log_info "Сеть $NETWORK_NAME создана"
}

build_image() {
  log_info "Построение Docker образа (нужен интернет для сборки ocfs2-tools с coverage)..."
  docker build -t "$IMAGE_NAME" -f Dockerfile.ocfs2 .
  log_info "Образ $IMAGE_NAME построен"
}

create_containers() {
  log_info "Создание $NODES контейнеров..."
  for i in $(seq 1 "$NODES"); do
    local name="ocfs2-node-$i"
    if docker ps -a --format '{{.Names}}' | grep -qx "$name"; then
      docker rm -f "$name" >/dev/null 2>&1 || true
    fi
  done

  for i in $(seq 1 "$NODES"); do
    local name="ocfs2-node-$i"
    local ip="172.20.0.$((10 + i))"
    log_info "Старт $name ($ip)..."
    docker run -d \
      --name "$name" \
      --hostname "$name" \
      --network "$NETWORK_NAME" --ip "$ip" \
      --privileged \
      --cap-add SYS_MODULE --cap-add SYS_ADMIN --cap-add NET_ADMIN --cap-add SYS_RESOURCE \
      --device "${DRBD_DEVICE}:${DRBD_DEVICE}" \
      -v /lib/modules:/lib/modules:ro \
      "$IMAGE_NAME" \
      /bin/bash -c "tail -f /dev/null" >/dev/null
    sleep 1
  done

  log_info "Контейнеры запущены"
}

configure_ocfs2_cluster() {
  log_info "Настройка кластера OCFS2: один heartbeat-регион на узле 1, остальные используют тот же config..."
  
  # 0) Полная очистка DRBD перед повторным запуском
  log_info "Полная очистка DRBD перед настройкой кластера..."
  cleanup_host_drbd
  sleep 2
  
  # 1) Останавливаем и удаляем контейнеры, чтобы ни один процесс не держал модули/устройство
  log_info "Остановка и удаление контейнеров перед выгрузкой OCFS2 модулей..."
  for i in $(seq 1 8); do
    local name="ocfs2-node-$i"
    if docker ps -a --format '{{.Names}}' | grep -qx "$name"; then
      docker rm -f "$name" >/dev/null 2>&1 || true
    fi
  done
  sleep 2
  
  # 2) На host: остановить heartbeat/unregister, если o2cb установлен (убивает старые o2hb, созданные с host)
  sudo pkill -9 o2cb 2>/dev/null || true
  if command -v o2cb >/dev/null 2>&1; then
    sudo o2cb stop-heartbeat "$CLUSTER_NAME" 2>/dev/null || true
    sudo o2cb unregister-cluster "$CLUSTER_NAME" 2>/dev/null || true
    sleep 1
  fi
  
  # 3) Размонтировать ocfs2 на host
  if mount | grep -q "type ocfs2"; then
    log_warn "Размонтирование ocfs2 на host..."
    mount | grep "type ocfs2" | awk '{print $3}' | while read -r mp; do
      sudo umount "$mp" 2>/dev/null || true
    done
  fi
  
  # 4) Выгружаем OCFS2 модули — единственный способ убить старые [o2hb-XXX] kernel threads
  log_info "Выгрузка OCFS2 модулей на host (уничтожает старые o2hb kernel threads)..."
  for mod in ocfs2_stack_o2cb ocfs2_dlm ocfs2_dlmfs ocfs2 ocfs2_nodemanager ocfs2_stackglue; do
    if sudo modprobe -r "$mod" 2>/dev/null; then
      : # ok
    else
      sudo rmmod -f "$mod" 2>/dev/null || true
    fi
  done
  sleep 2
  
  # 5) Очищаем dmesg для текущего запуска
  sudo dmesg -c >/dev/null 2>&1 || true

  # 5b) Убеждаемся, что /dev/drbd0 есть на host (DRBD уже поднят в main через host_setup_drbd_single)
  if [[ ! -b "${DRBD_DEVICE}" ]]; then
    log_warn "Устройство ${DRBD_DEVICE} отсутствует на host. Поднимаем DRBD..."
    host_setup_drbd_single
  fi
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -b "${DRBD_DEVICE}" ]] && break
    log_warn "Ожидание ${DRBD_DEVICE} на host..."
    sleep 2
  done
  if [[ ! -b "${DRBD_DEVICE}" ]]; then
    log_error "Устройство ${DRBD_DEVICE} не появилось на host. Запустите сначала: sudo ./deploy_ocfs2_cluster.sh cleanup ; sudo ./deploy_ocfs2_cluster.sh 1"
    exit 1
  fi

  # 5c) Полное обнуление /dev/drbd0 на host (оставляем последние 128 MiB под метаданные DRBD)
  log_info "Полное стирание подписей и обнуление начала ${DRBD_DEVICE} на host..."
  sudo wipefs -a "${DRBD_DEVICE}" >/dev/null 2>&1 || true
  sleep 1
  size_bytes=$(sudo blockdev --getsize64 "${DRBD_DEVICE}" 2>/dev/null || echo 0)
  size_mb=$(( size_bytes / 1024 / 1024 ))
  # DRBD с meta-disk internal хранит метаданные в конце — не трогаем последние 128 MiB
  zero_mb=4096
  if [[ "$size_mb" -gt 128 ]] && [[ "$size_mb" -le 16384 ]]; then
    zero_mb=$(( size_mb - 128 ))
  fi
  if [[ "$zero_mb" -gt 0 ]]; then
    log_info "Обнуление первых ${zero_mb} MiB устройства (метаданные DRBD сохранены)..."
    sudo dd if=/dev/zero of="${DRBD_DEVICE}" bs=1M count="$zero_mb" conv=fsync 2>/dev/null || true
    log_info "Обнулено первых ${zero_mb} MiB."
  fi
  sync
  sleep 2

  log_info "Очистка на host завершена, создаём контейнеры..."
  
  # 6) Создаём контейнеры заново (они загрузят модули при первом o2cb)
  create_containers
  sleep 3
  
  # Узел 1: cluster.conf и регистрация o2cb
  log_info "Настройка узла ocfs2-node-1 (bootstrap)..."
  local bootstrap_log="${PWD:-.}/ocfs2_bootstrap_last.log"
  docker exec "ocfs2-node-1" /setup_ocfs2_cluster.sh "$CLUSTER_NAME" "$NODES" bootstrap > "$bootstrap_log" 2>&1 || true
  sleep 3

  if ! docker exec ocfs2-node-1 test -f /etc/ocfs2/cluster.conf; then
    log_error "bootstrap не создал /etc/ocfs2/cluster.conf на ocfs2-node-1"
    [[ -f "$bootstrap_log" ]] && tail -40 "$bootstrap_log" | while read -r line; do echo "  $line"; done
    exit 1
  fi
  log_info "cluster.conf на ocfs2-node-1 готов"
}

start_heartbeat_after_mkfs() {
  log_info "Heartbeat на ${DRBD_DEVICE}..."
  docker exec ocfs2-node-1 /setup_ocfs2_cluster.sh "$CLUSTER_NAME" "$NODES" heartbeat >/dev/null 2>&1 || true
  sleep 2

  local conf_check="/tmp/ocfs2_cluster_hb_$$.conf"
  docker cp "ocfs2-node-1:/etc/ocfs2/cluster.conf" "$conf_check" 2>/dev/null || true
  if [[ ! -f "$conf_check" ]] || ! grep -q "heartbeat:" "$conf_check"; then
    docker exec ocfs2-node-1 /setup_ocfs2_cluster.sh "$CLUSTER_NAME" "$NODES" heartbeat >/dev/null 2>&1 || true
    sleep 2
    docker cp "ocfs2-node-1:/etc/ocfs2/cluster.conf" "$conf_check" 2>/dev/null || true
  fi

  if [[ "$NODES" -ge 2 && -f "$conf_check" ]]; then
    log_info "Копирование cluster.conf на узлы 2..$NODES..."
    for i in $(seq 2 "$NODES"); do
      docker cp "$conf_check" "ocfs2-node-$i:/etc/ocfs2/cluster.conf" >/dev/null 2>&1 || true
      docker exec "ocfs2-node-$i" /setup_ocfs2_cluster.sh "$CLUSTER_NAME" "$NODES" register >/dev/null 2>&1 || true
    done
  fi
  rm -f "$conf_check"
  sleep 4
}

create_filesystem() {
  log_info "Форматирование ${DRBD_DEVICE} в OCFS2..."
  
  # Проверяем, что устройство доступно в контейнере
  if ! docker exec ocfs2-node-1 test -b "${DRBD_DEVICE}"; then
    log_error "Устройство ${DRBD_DEVICE} недоступно в контейнере ocfs2-node-1"
    log_error "Проверьте, что устройство передано в контейнер через --device"
    exit 1
  fi
  
  # Используем yes для автоматического подтверждения, если mkfs всё ещё запрашивает
  local mkfs_extra=()
  if [[ -n "${MKFS_FEATURES:-}" ]]; then
    mkfs_extra+=(--fs-features="${MKFS_FEATURES}")
    log_info "mkfs.ocfs2 extra features: ${MKFS_FEATURES}"
  fi
  echo "y" | docker exec -i ocfs2-node-1 mkfs.ocfs2 -F -N "$NODES" -T "${MKFS_TYPE:-datafiles}" \
    --cluster-stack=o2cb --cluster-name="$CLUSTER_NAME" -L "ocfs2vol" "${mkfs_extra[@]}" "$DRBD_DEVICE" || \
  docker exec ocfs2-node-1 bash -c "echo y | mkfs.ocfs2 -F -N $NODES -T ${MKFS_TYPE:-datafiles} --cluster-stack=o2cb --cluster-name=$CLUSTER_NAME -L ocfs2vol ${MKFS_FEATURES:+--fs-features=$MKFS_FEATURES} $DRBD_DEVICE"
  
  log_info "Файловая система создана"
  log_info "Ожидание синхронизации файловой системы..."
  sleep 3
}

mount_fs_all_nodes() {
  log_info "Монтирование FS на всех узлах..."
  sleep 3

  local mounted=0
  for i in $(seq 1 "$NODES"); do
    local name="ocfs2-node-$i"
    docker exec "$name" mkdir -p "$MOUNT_POINT" >/dev/null 2>&1 || true

    local ok=0
    local attempt=0
    while [ $attempt -lt 5 ]; do
      attempt=$((attempt + 1))
      if docker exec "$name" mountpoint -q "$MOUNT_POINT" >/dev/null 2>&1; then
        ok=1
        break
      fi
      if docker exec "$name" mount -i -t ocfs2 "$DRBD_DEVICE" "$MOUNT_POINT" >/dev/null 2>&1; then
        ok=1
        break
      fi
      if docker exec "$name" mount -t ocfs2 "$DRBD_DEVICE" "$MOUNT_POINT" >/dev/null 2>&1; then
        ok=1
        break
      fi
      sleep 2
    done

    if [ "$ok" -eq 1 ]; then
      log_info "✓ FS смонтирована на $name"
      mounted=$((mounted + 1))
    fi
  done

  if [ "$mounted" -eq 0 ]; then
    return 1
  fi
  log_info "FS смонтирована на $mounted узлах"
}

run_tests() {
  log_info "Запуск тестов..."
  rm -f /tmp/test_results_node_*.log >/dev/null 2>&1 || true

  local ran=0
  for i in $(seq 1 "$NODES"); do
    local name="ocfs2-node-$i"
    if ! docker exec "$name" mountpoint -q "$MOUNT_POINT" >/dev/null 2>&1; then
      continue
    fi
    ran=$((ran + 1))
    ( docker exec \
        -e XFSTESTS_PROFILE="${XFSTESTS_PROFILE:-default}" \
        -e OCFS2_XFSTESTS_CONF="/opt/xfstests_configs/${XFSTESTS_PROFILE:-default}.env" \
        -e CLUSTER_NAME="$CLUSTER_NAME" \
        "$name" /run_tests.sh "$MOUNT_POINT" "$NODES" > "/tmp/test_results_node_${i}.log" 2>&1 ) &
  done
  wait || true

  if [ "$ran" -eq 0 ]; then
    return 0
  fi

  log_info "Результаты тестов (также сохраняются в отчёт):"
  for i in $(seq 1 "$NODES"); do
    [[ -f "/tmp/test_results_node_${i}.log" ]] || continue
    echo "---- ocfs2-node-$i ----"
    cat "/tmp/test_results_node_${i}.log" || true
    echo
  done
}

finalize_report_dir() {
  local d="$1"
  [[ -d "$d" ]] || return 0
  rm -rf "$d"/node_*_gcov
  if [[ -d "$d/tools_tracefiles" ]] && [[ -z "$(ls -A "$d/tools_tracefiles" 2>/dev/null || true)" ]]; then
    rmdir "$d/tools_tracefiles" 2>/dev/null || true
  fi
  if [[ -d "$d/tools_html" ]] && [[ ! -f "$d/tools_html/index.html" ]] && [[ -z "$(ls -A "$d/tools_html" 2>/dev/null || true)" ]]; then
    rmdir "$d/tools_html" 2>/dev/null || true
  fi
  chmod -R a+rX "$d" 2>/dev/null || true
  if [[ -n "${SUDO_USER:-}" ]]; then
    chown -R "${SUDO_USER}:" "$d" 2>/dev/null || true
  fi
}

generate_kernel_html_report() {
  local report_dir="$1"
  mkdir -p "$report_dir/kernel_html" "$report_dir/test_results" "$report_dir/tools_html"
  local gen="$SCRIPT_DIR/coverage/generate_ocfs2_html_report.py"
  if [[ ! -f "$gen" ]]; then
    log_warn "Нет $gen — интерактивный kernel HTML не будет собран"
    return 0
  fi
  local lcov_args=()
  if [[ -f "$report_dir/kernel_ocfs2.info" ]] && grep -q '^DA:' "$report_dir/kernel_ocfs2.info" 2>/dev/null; then
    lcov_args+=(--lcov "$report_dir/kernel_ocfs2.info")
    log_info "lcov: $report_dir/kernel_ocfs2.info"
  fi
  log_info "Генерация интерактивного HTML покрытия OCFS2 (профиль ${XFSTESTS_PROFILE:-default}, узлов: ${OCFS2_NODES:-$NODES})..."
  local py_cmd=(python3 "$gen"
    --src "$SCRIPT_DIR/coverage/ocfs2_src"
    --out "$report_dir/kernel_html"
    --profile "${XFSTESTS_PROFILE:-default}"
    --report-root "$report_dir"
    --nodes "${OCFS2_NODES:-$NODES}")
  if [[ ${#lcov_args[@]} -gt 0 ]]; then
    py_cmd+=("${lcov_args[@]}")
  fi
  "${py_cmd[@]}" || {
      log_warn "Генератор HTML вернул ошибку"
      return 1
    }
  chmod -R a+rX "$report_dir" 2>/dev/null || true
  if [[ -f "$report_dir/kernel_html/index.html" ]]; then
    local nfiles
    nfiles="$(find "$report_dir/kernel_html/files" -name '*.html' 2>/dev/null | wc -l | tr -d ' ')"
    log_info "✓ Kernel HTML: $report_dir/kernel_html/index.html (файлов драйвера: $nfiles)"
    log_info "✓ Сводка отчёта: $report_dir/index.html"
    local i
    for i in $(seq 1 "${OCFS2_NODES:-$NODES}"); do
      if [[ -f "$report_dir/node_${i}_tests/kernel_html/index.html" ]]; then
        log_info "✓ Покрытие ocfs2-node-$i: $report_dir/node_${i}_tests/kernel_html/index.html"
      fi
    done
  fi
  finalize_report_dir "$report_dir"
}

collect_reports() {
  local report_dir="gcov_reports_${XFSTESTS_PROFILE:-default}_$(date +%Y%m%d_%H%M%S)_$$"
  mkdir -p "$report_dir"

  # ---- Сохраняем результаты тестов для визуализации ----
  log_info "Сохранение результатов тестов в $report_dir/test_results/..."
  mkdir -p "$report_dir/test_results"
  for i in $(seq 1 "$NODES"); do
    [[ -f "/tmp/test_results_node_${i}.log" ]] && cp "/tmp/test_results_node_${i}.log" "$report_dir/test_results/ocfs2-node-${i}.log"
  done
  # Простой HTML для просмотра результатов тестов
  {
    echo '<!DOCTYPE html><html><head><meta charset="utf-8"><title>OCFS2 Test Results</title></head><body>'
    echo '<h1>OCFS2 cluster test results</h1><p>Nodes: '"$NODES"'</p><ul>'
    for i in $(seq 1 "$NODES"); do
      echo '<li><a href="ocfs2-node-'"$i"'.log">ocfs2-node-'"$i"'</a></li>'
    done
    echo '</ul><pre>'
    for i in $(seq 1 "$NODES"); do
      echo "=== ocfs2-node-$i ==="
      [[ -f "$report_dir/test_results/ocfs2-node-${i}.log" ]] && cat "$report_dir/test_results/ocfs2-node-${i}.log" || echo "(no log)"
      echo
    done
    echo '</pre></body></html>'
  } > "$report_dir/test_results/index.html"
  log_info "✓ Результаты тестов: $report_dir/test_results/index.html"

  # ---- Kernel OCFS2 coverage (host) ----
  log_info "Сбор Kernel coverage (OCFS2) на host..."
  ensure_lcov_on_host
  ensure_debugfs

  if [[ -d "/sys/kernel/debug/gcov" ]]; then
    mkdir -p "$report_dir/kernel_html"
    
    # Собираем данные GCOV (DRBD/DKMS могут вызывать сбой geninfo — игнорируем ошибки)
    log_info "Захват данных GCOV из /sys/kernel/debug/gcov..."
    sudo lcov --capture --directory /sys/kernel/debug/gcov --output-file "$report_dir/kernel_raw.info" \
      --ignore-errors mismatch,unused,empty,gcov,exception,negative 2>/dev/null || true
    
    # Если полный захват пуст (geninfo упал на DRBD и т.п.), пробуем только каталоги с ocfs2
    if [[ ! -s "$report_dir/kernel_raw.info" ]]; then
      ocfs2_gcov_root=""
      for d in /sys/kernel/debug/gcov/home /sys/kernel/debug/gcov; do
        if [[ -d "$d" ]] && sudo find "$d" -path '*fs/ocfs2*' -name '*.gcda' 2>/dev/null | head -1 | grep -q .; then
          ocfs2_gcov_root="$d"
          break
        fi
      done
      if [[ -n "$ocfs2_gcov_root" ]]; then
        log_info "Повторный захват только для путей с ocfs2..."
        sudo lcov --capture --directory "$ocfs2_gcov_root" --output-file "$report_dir/kernel_raw.info" \
          --include '*/fs/ocfs2/*' --ignore-errors mismatch,unused,empty,gcov,exception,negative 2>/dev/null || true
      fi
    fi
    
    # Извлекаем только OCFS2
    log_info "Извлечение данных для OCFS2..."
    sudo lcov --extract "$report_dir/kernel_raw.info" "*/fs/ocfs2/*" --output-file "$report_dir/kernel_ocfs2.info" \
      --ignore-errors unused,empty 2>/dev/null || true
  fi

  # ---- Сохранение результатов тестов из узлов ----
  for i in $(seq 1 "$NODES"); do
    local name="ocfs2-node-$i"
    local node_test_dir="$report_dir/node_${i}_tests"
    mkdir -p "$node_test_dir"
    docker ps --format '{{.Names}}' | grep -qx "$name" || continue
    docker cp "${name}:/tmp/test_results_${name}" "$node_test_dir" >/dev/null 2>&1 || \
      docker cp "${name}:/tmp/test_results_ocfs2-node-${i}" "$node_test_dir" >/dev/null 2>&1 || true
  done

  if docker ps --format '{{.Names}}' | grep -qx "ocfs2-node-1"; then
    mkdir -p "$report_dir/tools_tracefiles"
    docker exec ocfs2-node-1 bash -lc 'mkdir -p /tmp/gcov_reports/merge_inputs' >/dev/null 2>&1 || true
    local tracefiles_count=0
    for i in $(seq 1 "$NODES"); do
      local name="ocfs2-node-$i"
      docker ps --format '{{.Names}}' | grep -qx "$name" || continue
      docker exec "$name" /collect_tools_gcov.sh "$i" >/dev/null 2>&1 || true
      if docker exec "$name" test -s "/tmp/gcov_reports/ocfs2_tools_node${i}.info" 2>/dev/null; then
        docker cp "${name}:/tmp/gcov_reports/ocfs2_tools_node${i}.info" \
          "$report_dir/tools_tracefiles/ocfs2_tools_node${i}.info" >/dev/null 2>&1 || true
      fi
      if [[ -s "$report_dir/tools_tracefiles/ocfs2_tools_node${i}.info" ]]; then
        docker cp "$report_dir/tools_tracefiles/ocfs2_tools_node${i}.info" \
          "ocfs2-node-1:/tmp/gcov_reports/merge_inputs/ocfs2_tools_node${i}.info" >/dev/null 2>&1 || true
        tracefiles_count=$((tracefiles_count + 1))
      fi
    done
    if [[ "$tracefiles_count" -gt 0 ]]; then
      docker exec ocfs2-node-1 /merge_tools_gcov.sh "$NODES" >/dev/null 2>&1 || true
      docker cp "ocfs2-node-1:/tmp/gcov_reports/tools_html" "$report_dir/tools_html" >/dev/null 2>&1 || true
    fi
  fi
  mkdir -p "$report_dir/tools_html"

  generate_kernel_html_report "$report_dir"
  log_info "Готово: $report_dir/index.html"
}

cleanup() {
  log_info "Очистка..."
  # контейнеры
  docker ps -a --filter "name=ocfs2-node-" --format "{{.Names}}" | while read -r n; do
    [[ -n "${n:-}" ]] || continue
    docker rm -f "$n" >/dev/null 2>&1 || true
  done
  # сеть
  if docker network ls | awk '{print $2}' | grep -qx "$NETWORK_NAME"; then
    docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
  fi
  
  # Остановка o2cb процессов на host
  sudo pkill -9 o2cb 2>/dev/null || true
  
  # Размонтирование ocfs2 на host (если есть)
  mount | grep "type ocfs2" | awk '{print $3}' | while read -r mp; do
    sudo umount "$mp" 2>/dev/null || true
  done
  
  # Выгрузка OCFS2 модулей для уничтожения o2hb kernel threads
  log_info "Выгрузка OCFS2 модулей для очистки o2hb kernel threads..."
  sudo modprobe -r ocfs2_stack_o2cb 2>/dev/null || true
  sudo modprobe -r ocfs2_dlm 2>/dev/null || true
  sudo modprobe -r ocfs2_dlmfs 2>/dev/null || true
  sudo modprobe -r ocfs2 2>/dev/null || true
  sudo modprobe -r ocfs2_nodemanager 2>/dev/null || true
  sudo modprobe -r ocfs2_stackglue 2>/dev/null || true
  
  cleanup_host_drbd
  log_info "Очистка завершена"
}

main() {
  if [[ "$ACTION" == "cleanup" ]]; then
    cleanup
    exit 0
  fi

  log_info "Начало развёртывания OCFS2. Узлов: $NODES  профиль xfstests: ${XFSTESTS_PROFILE:-default}"
  if [[ "$NODES" -lt 1 || "$NODES" -gt 8 ]]; then
    log_error "Количество узлов должно быть 1..8"
    exit 1
  fi
  if [[ "$NODES" -eq 1 ]]; then
    log_info "Режим 1 узла: один heartbeat-регион, монтирование без конфликтов (рекомендуется для Docker + один DRBD)"
  fi

  trap 'log_warn "Прерывание — выполняю cleanup..."; cleanup; exit 1' INT TERM

  if ensure_docker && ensure_host_drbd9 && (
      ensure_clean_drbd_minors
      create_network
      build_image
      host_setup_drbd_single
      configure_ocfs2_cluster
      create_filesystem
      start_heartbeat_after_mkfs
      mount_fs_all_nodes
      run_tests
    ); then
    :
  fi

  trap - INT TERM
  collect_reports
}

main
