#!/bin/bash
#
# deploy_ocfs2_cluster.sh
# Развёртывание OCFS2-кластера в Docker поверх общего DRBD-девайса, который поднимается на host.
# Сценарий ориентирован на single-host (все контейнеры на одной машине).
#
# Использование:
#   sudo ./deploy_ocfs2_cluster.sh 4   # 4 узла (при конфликте heartbeat — см. ниже)
#   sudo ./deploy_ocfs2_cluster.sh 1   # 1 узел: надёжный режим для Docker + один DRBD (монтирование без конфликтов)
#   sudo ./deploy_ocfs2_cluster.sh cleanup
#
set -euo pipefail

case "${1:-}" in
  clean|cleanup) ACTION="cleanup" ;;
  *) ACTION="deploy" ;;
esac

# --- Конфигурация ---
if [[ "$ACTION" == "cleanup" ]]; then
  NODES=8
else
  NODES=${1:-4}
fi

CLUSTER_NAME="ocfs2cluster"               # только [A-Za-z0-9]
DRBD_RESOURCE="ocfs2-resource"
DRBD_DEVICE="/dev/drbd0"
MOUNT_POINT="/mnt/ocfs2"
NETWORK_NAME="ocfs2-network"
IMAGE_NAME="ocfs2-node:latest"

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
  require_cmd docker
  docker info >/dev/null 2>&1 || { log_error "Docker daemon не запущен"; exit 1; }
}

ensure_host_drbd9() {
  log_info "Проверка DRBD на host..."
  sudo modprobe drbd >/dev/null 2>&1 || true
  sudo modprobe drbd_transport_tcp >/dev/null 2>&1 || true

  if [[ ! -r /proc/drbd ]]; then
    log_warn "/proc/drbd отсутствует. Пытаемся установить drbd-utils + drbd-dkms (нужен интернет)."
    sudo apt-get update
    sudo apt-get install -y drbd-utils drbd-dkms || true
    sudo modprobe drbd >/dev/null 2>&1 || true
  fi

  if [[ ! -r /proc/drbd ]]; then
    log_error "DRBD на host недоступен (/proc/drbd отсутствует)."
    exit 1
  fi

  if ! grep -Eq 'version:\s*9\.' /proc/drbd; then
    log_error "Нужен DRBD 9.x. Текущее состояние /proc/drbd:"
    cat /proc/drbd || true
    exit 1
  fi

  log_info "DRBD9 на host обнаружен."
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
    sudo losetup -a | awk '/\/var\/lib\/drbd\//{print $1}' | tr -d ':' | while read -r loopdev; do
      [[ -n "${loopdev:-}" ]] || continue
      sudo losetup -d "$loopdev" >/dev/null 2>&1 || true
    done
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
        ls -1 /sys/devices/virtual/block/drbd* 2>/dev/null || true
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
  
  # Проверяем: если модули или o2hb kernel threads остались — без перезагрузки не обойтись
  if lsmod 2>/dev/null | grep -q ocfs2; then
    log_warn "OCFS2 модули не выгрузились (держатся старыми o2hb kernel threads)."
    if ps aux 2>/dev/null | grep -q '\[o2hb-'; then
      log_error "На host всё ещё есть [o2hb-XXX] kernel threads — они не убиваются без выгрузки модуля."
      log_error "Единственный надёжный способ: перезагрузите host один раз, затем выполните:"
      log_error "  sudo ./deploy_ocfs2_cluster.sh cleanup"
      log_error "  sudo ./deploy_ocfs2_cluster.sh 1"
      exit 1
    fi
  fi
  
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
  
  # Узел 1: bootstrap (создаёт config и единственный heartbeat-регион)
  log_info "Настройка узла ocfs2-node-1 (bootstrap)..."
  local bootstrap_log="${PWD:-.}/ocfs2_bootstrap_last.log"
  docker exec "ocfs2-node-1" /setup_ocfs2_cluster.sh "$CLUSTER_NAME" "$NODES" bootstrap > "$bootstrap_log" 2>&1 || true
  sleep 5

  # Проверяем, что в cluster.conf есть секция heartbeat (иначе add-heartbeat не сработал)
  local conf_check="/tmp/ocfs2_cluster_check_$$.conf"
  docker cp "ocfs2-node-1:/etc/ocfs2/cluster.conf" "$conf_check" 2>/dev/null || true
  if [[ ! -f "$conf_check" ]] || ! grep -q "heartbeat:" "$conf_check"; then
    log_error "В cluster.conf узла 1 нет секции heartbeat (add-heartbeat не выполнился или устройство /dev/drbd0 не готово)."
    log_error "Вывод bootstrap (последние строки):"
    [[ -f "$bootstrap_log" ]] && tail -60 "$bootstrap_log" | while read -r line; do echo "  $line"; done
    log_error "Полный лог сохранён в: $bootstrap_log"
      rm -f "$conf_check"
      exit 1
    fi
  
  if [[ "$NODES" -ge 2 ]]; then
    # Копируем cluster.conf (уже в conf_check) на узлы 2..N
    log_info "Копирование cluster.conf на узлы 2..$NODES..."
    for i in $(seq 2 "$NODES"); do
      docker cp "$conf_check" "ocfs2-node-$i:/etc/ocfs2/cluster.conf" || {
        log_error "Не удалось скопировать cluster.conf на ocfs2-node-$i"
        rm -f "$conf_check"
        exit 1
      }
    done
    rm -f "$conf_check"
    # Узлы 2..N: join (только register + start-heartbeat, без add-heartbeat)
    for i in $(seq 2 "$NODES"); do
      log_info "Настройка узла ocfs2-node-$i (join)..."
      docker exec "ocfs2-node-$i" /setup_ocfs2_cluster.sh "$CLUSTER_NAME" "$NODES" join >/dev/null 2>&1
      sleep 3
    done
  fi
  rm -f "$conf_check"

  log_info "Ожидание синхронизации кластера (один heartbeat-регион для всех узлов)..."
  sleep 10
  
  for i in $(seq 1 "$NODES"); do
    local name="ocfs2-node-$i"
    if docker exec "$name" o2cb cluster-status "$CLUSTER_NAME" >/dev/null 2>&1; then
      log_info "✓ Кластер онлайн на $name"
    else
      log_warn "Кластер не онлайн на $name, повторная попытка..."
      docker exec "$name" o2cb start-heartbeat "$CLUSTER_NAME" >/dev/null 2>&1 || true
      sleep 2
    fi
  done
  sleep 3
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
  echo "y" | docker exec -i ocfs2-node-1 mkfs.ocfs2 -F -N "$NODES" -T datafiles \
    --cluster-stack=o2cb --cluster-name="$CLUSTER_NAME" -L "ocfs2vol" "$DRBD_DEVICE" || \
  docker exec ocfs2-node-1 bash -c "echo y | mkfs.ocfs2 -F -N $NODES -T datafiles --cluster-stack=o2cb --cluster-name=$CLUSTER_NAME -L ocfs2vol $DRBD_DEVICE"
  
  log_info "Файловая система создана"
  log_info "Ожидание синхронизации файловой системы..."
  sleep 3
}

mount_fs_all_nodes() {
  log_info "Монтирование FS на всех узлах..."
  
  # Даём время кластеру полностью запуститься
  log_info "Ожидание готовности кластера OCFS2..."
  sleep 5
  
  # Проверяем статус кластера на каждом узле перед монтированием
  for i in $(seq 1 "$NODES"); do
    local name="ocfs2-node-$i"
    log_info "Проверка статуса кластера на $name..."
    if docker exec "$name" o2cb cluster-status "$CLUSTER_NAME" >/dev/null 2>&1; then
      log_info "Кластер онлайн на $name"
    else
      log_warn "Кластер не онлайн на $name, пытаемся запустить..."
      docker exec "$name" o2cb start-heartbeat "$CLUSTER_NAME" >/dev/null 2>&1 || true
      sleep 2
    fi
    if docker exec "$name" test -b "${DRBD_DEVICE}" >/dev/null 2>&1; then
      log_info "Устройство доступно на $name"
    else
      log_error "Устройство ${DRBD_DEVICE} недоступно на $name"
      exit 1
    fi
  done
  
  sleep 3
  
  for i in $(seq 1 "$NODES"); do
    local name="ocfs2-node-$i"
    docker exec "$name" mkdir -p "$MOUNT_POINT"
    
    # Пытаемся смонтировать с несколькими повторами
    local mount_attempt=0
    local max_attempts=5
    while [ $mount_attempt -lt $max_attempts ]; do
      mount_err=$(docker exec "$name" mount -t ocfs2 "$DRBD_DEVICE" "$MOUNT_POINT" 2>&1) && {
        log_info "✓ FS смонтирована на $name"
        break
      }
      mount_attempt=$((mount_attempt + 1))
      if [ $mount_attempt -lt $max_attempts ]; then
        log_warn "mount на $name не удался (попытка $mount_attempt/$max_attempts): ${mount_err:-unknown}"
        sleep 3
      else
        log_error "Не удалось смонтировать FS на $name после $max_attempts попыток"
        log_error "Ошибка mount: ${mount_err:-unknown}"
        log_error "dmesg на $name (последние строки):"
        docker exec "$name" dmesg 2>/dev/null | tail -25 | while read -r line; do echo -e "  $line"; done
        log_error "Проверьте: docker exec $name o2cb cluster-status $CLUSTER_NAME"
        log_error "Проверьте: docker exec $name o2cb list-heartbeats $CLUSTER_NAME"
        log_error "Если в dmesg несколько регионов (o2hb-XXX, o2hb-YYY): старые o2hb kernel threads не выгружаются — перезагрузите host, затем: sudo ./deploy_ocfs2_cluster.sh cleanup ; sudo ./deploy_ocfs2_cluster.sh $NODES"
        exit 1
      fi
    done
  done
  log_info "FS смонтирована на всех узлах"
}

run_tests() {
  log_info "Запуск тестов..."
  rm -f /tmp/test_results_node_*.log >/dev/null 2>&1 || true

  for i in $(seq 1 "$NODES"); do
    ( docker exec "ocfs2-node-$i" /run_tests.sh "$MOUNT_POINT" "$NODES" > "/tmp/test_results_node_${i}.log" 2>&1 ) &
  done
  wait || true

  log_info "Результаты тестов (также сохраняются в отчёт):"
  for i in $(seq 1 "$NODES"); do
    echo "---- ocfs2-node-$i ----"
    cat "/tmp/test_results_node_${i}.log" || true
    echo
  done
}

collect_reports() {
  local report_dir="gcov_reports_$(date +%Y%m%d_%H%M%S)"
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
    
    # Проверяем, есть ли данные в файле
    if [[ -f "$report_dir/kernel_ocfs2.info" ]] && [[ -s "$report_dir/kernel_ocfs2.info" ]]; then
      log_info "Генерация HTML отчёта..."
      # Используем --source-directory для указания пути к исходникам (если есть)
      # Или генерируем без исходников, если их нет
      # Добавляем --prefix для правильной обработки путей и --no-branch-coverage для совместимости
      sudo genhtml "$report_dir/kernel_ocfs2.info" --output-directory "$report_dir/kernel_html" \
        --ignore-errors source,unused,empty,unreachable,negative \
        --no-branch-coverage \
        --prefix "$(pwd)" \
        2>&1 | grep -v "stamp mismatch\|cannot open\|WARNING.*source" || true
      
      # Проверяем, что HTML файл создан и не пустой
      if [[ -f "$report_dir/kernel_html/index.html" ]] && [[ -s "$report_dir/kernel_html/index.html" ]]; then
        local html_size=$(stat -c%s "$report_dir/kernel_html/index.html" 2>/dev/null || echo "0")
        if [ "$html_size" -gt 1000 ]; then
          log_info "✓ Kernel HTML: $report_dir/kernel_html/index.html (размер: $html_size байт)"
        else
          log_warn "Kernel HTML создан, но слишком мал ($html_size байт), возможно пуст"
          # Пробуем создать без исходников
          log_info "Повторная генерация без исходников..."
          sudo genhtml "$report_dir/kernel_ocfs2.info" --output-directory "$report_dir/kernel_html" \
            --ignore-errors source,unused,empty,unreachable,negative \
            --no-branch-coverage \
            --no-source \
            2>&1 | grep -v "stamp mismatch\|cannot open\|WARNING.*source" || true
        fi
      else
        log_warn "HTML не создан или пуст. Возможно, нет исходников ядра на хосте."
        log_warn "GCOV данные содержат пути из VM: /home/ubuntu-24-for-kernel-build/kernel-sources/noble/"
        log_warn "Для генерации HTML скопируйте исходники ядра на хост в тот же путь или используйте --source-directory"
        # Создаем минимальный HTML для отображения данных покрытия без исходников
        mkdir -p "$report_dir/kernel_html"
        log_info "Генерация HTML без исходников..."
        sudo genhtml "$report_dir/kernel_ocfs2.info" --output-directory "$report_dir/kernel_html" \
          --ignore-errors source,unused,empty,unreachable,negative \
          --no-branch-coverage \
          --no-source \
          2>&1 | grep -v "stamp mismatch\|cannot open\|WARNING.*source" || true
        
        # Проверяем результат
        if [[ -f "$report_dir/kernel_html/index.html" ]] && [[ -s "$report_dir/kernel_html/index.html" ]]; then
          local html_size=$(stat -c%s "$report_dir/kernel_html/index.html" 2>/dev/null || echo "0")
          log_info "✓ Kernel HTML создан без исходников (размер: $html_size байт)"
        else
          log_warn "Не удалось создать Kernel HTML даже без исходников"
        fi
      fi
    else
      log_warn "kernel_ocfs2.info пуст или отсутствует. Возможно, нет данных покрытия для OCFS2."
      # Плейсхолдер, чтобы kernel_html не был пустым
      mkdir -p "$report_dir/kernel_html"
      {
        echo '<!DOCTYPE html><html><head><meta charset="utf-8"><title>Kernel OCFS2 Coverage</title></head><body>'
        echo '<h1>Kernel OCFS2 coverage</h1><p>No coverage data.</p>'
        echo '<p>Possible reasons: /sys/kernel/debug/gcov missing or empty; kernel built without CONFIG_GCOV_KERNEL;'
        echo ' debugfs not mounted; or lcov capture failed (e.g. DRBD/DKMS).</p>'
        echo '<p>Ensure kernel was built with GCOV and run: <code>sudo mount -t debugfs debugfs /sys/kernel/debug</code></p>'
        echo '</body></html>'
      } > "$report_dir/kernel_html/index.html"
    fi
  else
    log_warn "/sys/kernel/debug/gcov отсутствует. Нужны CONFIG_GCOV_KERNEL=y и debugfs."
    mkdir -p "$report_dir/kernel_html"
    {
      echo '<!DOCTYPE html><html><head><meta charset="utf-8"><title>Kernel OCFS2 Coverage</title></head><body>'
      echo '<h1>Kernel OCFS2 coverage</h1><p>/sys/kernel/debug/gcov not found.</p>'
      echo '<p>Kernel needs CONFIG_GCOV_KERNEL=y and debugfs mounted: <code>sudo mount -t debugfs debugfs /sys/kernel/debug</code></p>'
      echo '</body></html>'
    } > "$report_dir/kernel_html/index.html"
  fi

  # ---- Сохранение результатов тестов из узлов ----
  log_info "Копирование результатов тестов из узлов..."
  for i in $(seq 1 "$NODES"); do
    local name="ocfs2-node-$i"
    local node_test_dir="$report_dir/node_${i}_tests"
    mkdir -p "$node_test_dir"
    
    # Проверяем, что контейнер еще работает
    if ! docker ps --format '{{.Names}}' | grep -qx "$name"; then
      log_warn "Контейнер $name не запущен, пропускаем копирование тестов"
      continue
    fi
    
    # Пробуем скопировать результаты тестов (может быть несколько вариантов путей)
    local copied=0
    if docker cp "${name}:/tmp/test_results_${name}" "$node_test_dir" 2>/dev/null; then
      copied=1
      log_info "✓ Результаты тестов скопированы с $name"
    elif docker cp "${name}:/tmp/test_results_ocfs2-node-${i}" "$node_test_dir" 2>/dev/null; then
      copied=1
      log_info "✓ Результаты тестов скопированы с $name (альтернативный путь)"
    else
      # Пробуем скопировать отдельные файлы
      log_warn "Не удалось скопировать папку с $name, пробуем отдельные файлы..."
      mkdir -p "$node_test_dir/test_results_${name}"
      docker cp "${name}:/tmp/test_results_${name}/node_info.txt" "$node_test_dir/test_results_${name}/" 2>/dev/null || true
      docker cp "${name}:/tmp/test_results_${name}/summary.txt" "$node_test_dir/test_results_${name}/" 2>/dev/null || true
      docker cp "${name}:/tmp/test_results_${name}/xfstests_summary.txt" "$node_test_dir/test_results_${name}/" 2>/dev/null || true
      docker cp "${name}:/tmp/test_results_${name}/xfstests.log" "$node_test_dir/test_results_${name}/" 2>/dev/null || true
      if [ -f "$node_test_dir/test_results_${name}/node_info.txt" ]; then
        copied=1
        log_info "✓ Результаты тестов скопированы с $name (отдельные файлы)"
      fi
    fi
    
    if [ "$copied" -eq 0 ]; then
      log_warn "Не удалось скопировать результаты тестов с $name"
      # Проверяем, что есть в контейнере
      log_info "Содержимое /tmp в контейнере $name:"
      docker exec "$name" ls -la /tmp/ | grep -i test || log_warn "  (нет файлов с 'test' в имени)"
    fi
  done

  # ---- ocfs2-tools coverage (containers) ----
  log_info "Сбор tools coverage на каждом узле..."
  mkdir -p "$report_dir/tools_tracefiles"
  
  # Проверяем, что хотя бы один контейнер работает
  if ! docker ps --format '{{.Names}}' | grep -q "ocfs2-node-1"; then
    log_warn "Контейнер ocfs2-node-1 не запущен, пропускаем сбор tools coverage"
  else
    docker exec ocfs2-node-1 bash -lc 'mkdir -p /tmp/gcov_reports/merge_inputs' >/dev/null 2>&1 || true

    for i in $(seq 1 "$NODES"); do
      local name="ocfs2-node-$i"
      
      # Проверяем, что контейнер работает
      if ! docker ps --format '{{.Names}}' | grep -qx "$name"; then
        log_warn "Контейнер $name не запущен, пропускаем сбор coverage"
        continue
      fi
      
      log_info "Сбор coverage на $name..."
      local collect_log="$report_dir/collect_node${i}.log"
      docker exec "$name" /collect_tools_gcov.sh "$i" > "$collect_log" 2>&1 || log_warn "Ошибка при сборе coverage на $name"
      
      # Проверяем, что файл создался в контейнере
      if docker exec "$name" test -f "/tmp/gcov_reports/ocfs2_tools_node${i}.info" 2>/dev/null; then
        local file_size=$(docker exec "$name" stat -c%s "/tmp/gcov_reports/ocfs2_tools_node${i}.info" 2>/dev/null || echo "0")
        if [ "$file_size" -gt 0 ]; then
          log_info "  Tracefile существует в контейнере (размер: $file_size байт)"
          
          # копируем tracefile в host
          if docker cp "${name}:/tmp/gcov_reports/ocfs2_tools_node${i}.info" "$report_dir/tools_tracefiles/ocfs2_tools_node${i}.info" 2>/dev/null; then
            log_info "✓ Tracefile скопирован с $name"
          else
            log_warn "Не удалось скопировать tracefile с $name (файл существует в контейнере)"
            # Пробуем скопировать через exec cat
            docker exec "$name" cat "/tmp/gcov_reports/ocfs2_tools_node${i}.info" > "$report_dir/tools_tracefiles/ocfs2_tools_node${i}.info" 2>/dev/null && \
              log_info "✓ Tracefile скопирован через cat" || \
              log_warn "Не удалось скопировать даже через cat"
          fi
        else
          log_warn "Tracefile существует, но пуст (размер: $file_size)"
          # Показываем последние строки лога сбора
          log_info "Последние строки лога сбора:"
          tail -5 "$collect_log" | while read -r line; do echo "  $line"; done
        fi
      else
        log_warn "Tracefile не создан в контейнере $name"
        log_info "Проверяем содержимое /tmp/gcov_reports в контейнере:"
        docker exec "$name" ls -la /tmp/gcov_reports/ 2>/dev/null | head -10 || log_warn "  Директория не существует"
        log_info "Последние строки лога сбора:"
        tail -10 "$collect_log" | while read -r line; do echo "  $line"; done
      fi

      # копируем все артефакты узла
      if docker cp "${name}:/tmp/gcov_reports" "$report_dir/node_${i}_gcov" 2>/dev/null; then
        log_info "✓ GCOV артефакты скопированы с $name"
      else
        log_warn "Не удалось скопировать GCOV артефакты с $name"
      fi
    done
  fi

  # складываем tracefile в node1 и делаем merge + HTML внутри node1 (там есть исходники)
  if docker ps --format '{{.Names}}' | grep -qx "ocfs2-node-1"; then
    local tracefiles_count=0
    log_info "Проверка tracefile для объединения..."
    for i in $(seq 1 "$NODES"); do
      if [[ -f "$report_dir/tools_tracefiles/ocfs2_tools_node${i}.info" ]] && [[ -s "$report_dir/tools_tracefiles/ocfs2_tools_node${i}.info" ]]; then
        local file_size=$(stat -c%s "$report_dir/tools_tracefiles/ocfs2_tools_node${i}.info" 2>/dev/null || echo "0")
        log_info "  Найден tracefile для node $i (размер: $file_size байт)"
        if docker cp "$report_dir/tools_tracefiles/ocfs2_tools_node${i}.info" \
          "ocfs2-node-1:/tmp/gcov_reports/merge_inputs/ocfs2_tools_node${i}.info" >/dev/null 2>&1; then
          tracefiles_count=$((tracefiles_count + 1))
          log_info "  ✓ Tracefile node $i скопирован в node1 для объединения"
        else
          log_warn "  Не удалось скопировать tracefile node $i в node1"
        fi
      else
        log_warn "  Tracefile для node $i отсутствует или пуст"
      fi
    done
    log_info "Найдено $tracefiles_count tracefile для объединения"
    
    if [ "$tracefiles_count" -gt 0 ]; then
      log_info "Генерация единого tools HTML (внутри ocfs2-node-1, найдено $tracefiles_count tracefile)..."
      
      # Проверяем, что файлы действительно скопировались в node1
      log_info "Проверка tracefile в node1 перед объединением:"
      docker exec ocfs2-node-1 ls -lh /tmp/gcov_reports/merge_inputs/ 2>/dev/null | head -10 || log_warn "  Директория merge_inputs не существует"
      
      docker exec ocfs2-node-1 /merge_tools_gcov.sh "$NODES" > "$report_dir/ocfs2_tools_merge.txt" 2>&1 || log_warn "Ошибка при генерации HTML"
      
      # Показываем последние строки лога объединения
      log_info "Последние строки лога объединения:"
      tail -10 "$report_dir/ocfs2_tools_merge.txt" | while read -r line; do echo "  $line"; done
      
      # Проверяем, что HTML создался
      if docker exec ocfs2-node-1 test -f "/tmp/gcov_reports/tools_html/index.html" 2>/dev/null; then
        local html_size=$(docker exec ocfs2-node-1 stat -c%s "/tmp/gcov_reports/tools_html/index.html" 2>/dev/null || echo "0")
        log_info "HTML создан в контейнере (размер: $html_size байт)"
        
        if docker cp "ocfs2-node-1:/tmp/gcov_reports/tools_html" "$report_dir/tools_html" 2>/dev/null; then
          log_info "✓ Tools HTML скопирован"
        else
          log_warn "Не удалось скопировать tools_html, пробуем через tar..."
          docker exec ocfs2-node-1 tar czf - -C /tmp/gcov_reports tools_html 2>/dev/null | tar xzf - -C "$report_dir" 2>/dev/null && \
            log_info "✓ Tools HTML скопирован через tar" || \
            log_warn "Не удалось скопировать даже через tar"
        fi
      else
        log_warn "HTML не создан в контейнере"
        log_info "Проверяем содержимое /tmp/gcov_reports/tools_html в контейнере:"
        docker exec ocfs2-node-1 ls -la /tmp/gcov_reports/tools_html/ 2>/dev/null || log_warn "  Директория tools_html не существует"
      fi
      
      docker cp "ocfs2-node-1:/tmp/gcov_reports/ocfs2_tools_merged.info" "$report_dir/ocfs2_tools_merged.info" 2>/dev/null || true
    else
      log_warn "Нет tracefile для объединения, пропускаем генерацию tools HTML"
      log_info "Доступные tracefile в $report_dir/tools_tracefiles/:"
      ls -lh "$report_dir/tools_tracefiles/" 2>/dev/null || log_warn "  Директория пуста или не существует"
    fi
  else
    log_warn "Контейнер ocfs2-node-1 не запущен, пропускаем генерацию tools HTML"
  fi

  if [[ -f "$report_dir/tools_html/index.html" ]] && [[ -s "$report_dir/tools_html/index.html" ]]; then
    log_info "✓ Tools HTML: $report_dir/tools_html/index.html"
  else
    log_warn "Tools HTML не создан. См. $report_dir/ocfs2_tools_merge.txt и $report_dir/tools_tracefiles/"
    mkdir -p "$report_dir/tools_html"
    {
      echo '<!DOCTYPE html><html><head><meta charset="utf-8"><title>OCFS2 Tools Coverage</title></head><body>'
      echo '<h1>OCFS2 tools coverage</h1><p>Merged HTML was not generated.</p>'
      echo '<p><a href="../ocfs2_tools_merge.txt">Merge log (ocfs2_tools_merge.txt)</a></p>'
      echo '<p>Tracefiles:</p><ul>'
      for f in "$report_dir/tools_tracefiles"/ocfs2_tools_node*.info; do
        [[ -f "$f" ]] && echo '<li><a href="../tools_tracefiles/'"$(basename "$f")"'">'"$(basename "$f")"'</a></li>'
      done
      echo '</ul></body></html>'
    } > "$report_dir/tools_html/index.html"
  fi

  # Финальная проверка сохраненных отчетов
  log_info ""
  log_info "=== Сводка сохраненных отчетов ==="
  log_info "Директория отчетов: $report_dir"
  log_info ""
  
  # Проверяем test_results
  if [ -f "$report_dir/test_results/index.html" ] && [ -s "$report_dir/test_results/index.html" ]; then
    local size=$(stat -c%s "$report_dir/test_results/index.html" 2>/dev/null || echo "0")
    log_info "✓ test_results/index.html - сохранен (размер: $size байт)"
  else
    log_warn "✗ test_results/index.html - отсутствует или пуст"
    # Проверяем, есть ли хотя бы логи
    local log_count=$(find "$report_dir/test_results" -name "*.log" -type f 2>/dev/null | wc -l)
    if [ "$log_count" -gt 0 ]; then
      log_info "  Найдено $log_count лог-файлов в test_results/"
    fi
  fi
  
  # Проверяем kernel_html
  if [ -f "$report_dir/kernel_html/index.html" ] && [ -s "$report_dir/kernel_html/index.html" ]; then
    SIZE=$(du -h "$report_dir/kernel_html/index.html" 2>/dev/null | cut -f1)
    log_info "✓ kernel_html/index.html - сохранен (размер: $SIZE)"
  else
    log_warn "✗ kernel_html/index.html - отсутствует или пуст"
  fi
  
  # Проверяем tools_html
  if [ -f "$report_dir/tools_html/index.html" ] && [ -s "$report_dir/tools_html/index.html" ]; then
    local html_size=$(stat -c%s "$report_dir/tools_html/index.html" 2>/dev/null || echo "0")
    SIZE=$(du -h "$report_dir/tools_html/index.html" 2>/dev/null | cut -f1)
    if [ "$html_size" -gt 1000 ]; then
      log_info "✓ tools_html/index.html - сохранен (размер: $SIZE, $html_size байт)"
    else
      log_warn "✗ tools_html/index.html - слишком мал ($html_size байт), возможно пуст"
    fi
  else
    log_warn "✗ tools_html/index.html - отсутствует или пуст"
    # Проверяем tracefile
    local tracefile_count=$(find "$report_dir/tools_tracefiles" -name "*.info" -type f -size +0 2>/dev/null | wc -l)
    if [ "$tracefile_count" -gt 0 ]; then
      log_info "  Найдено $tracefile_count непустых tracefile в tools_tracefiles/"
      log_info "  Проверьте логи объединения: $report_dir/ocfs2_tools_merge.txt"
    else
      log_warn "  Tracefile отсутствуют или пусты - это причина отсутствия HTML"
    fi
  fi
  
  # Проверяем сохранение тестов из узлов
  NODES_SAVED=0
  for i in $(seq 1 "$NODES"); do
    if [ -d "$report_dir/node_${i}_tests" ] && [ "$(ls -A "$report_dir/node_${i}_tests" 2>/dev/null)" ]; then
      NODES_SAVED=$((NODES_SAVED + 1))
    fi
  done
  if [ "$NODES_SAVED" -gt 0 ]; then
    log_info "✓ Тесты из узлов сохранены ($NODES_SAVED из $NODES узлов)"
  else
    log_warn "✗ Тесты из узлов не сохранены"
  fi
  
  log_info ""
  log_info "Все отчёты сохранены в: $report_dir"
  log_info "Откройте в браузере:"
  log_info "  - Тесты: $report_dir/test_results/index.html"
  log_info "  - Kernel coverage: $report_dir/kernel_html/index.html"
  log_info "  - Tools coverage: $report_dir/tools_html/index.html"
  
  # Выводим структуру директории для удобства
  log_info ""
  log_info "Структура отчетов:"
  if command -v tree >/dev/null 2>&1; then
    tree -L 2 "$report_dir" 2>/dev/null || find "$report_dir" -maxdepth 2 -type d | head -20
  else
    find "$report_dir" -maxdepth 2 -type d | head -20
  fi
  
  # Показываем размеры файлов
  log_info ""
  log_info "Размеры файлов:"
  for f in "$report_dir/test_results/index.html" "$report_dir/kernel_html/index.html" "$report_dir/tools_html/index.html"; do
    if [ -f "$f" ]; then
      local size=$(stat -c%s "$f" 2>/dev/null || echo "0")
      local human_size=$(du -h "$f" 2>/dev/null | cut -f1)
      echo "  $(basename $(dirname $f))/$(basename $f): $human_size ($size байт)"
    fi
  done
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

  log_info "Начало развёртывания OCFS2. Узлов: $NODES"
  if [[ "$NODES" -lt 1 || "$NODES" -gt 8 ]]; then
    log_error "Количество узлов должно быть 1..8"
    exit 1
  fi
  if [[ "$NODES" -eq 1 ]]; then
    log_info "Режим 1 узла: один heartbeat-регион, монтирование без конфликтов (рекомендуется для Docker + один DRBD)"
  fi

  trap 'log_warn "Прерывание — выполняю cleanup..."; cleanup; exit 1' INT TERM

  ensure_docker
  ensure_host_drbd9
  ensure_clean_drbd_minors

  create_network
  build_image
  host_setup_drbd_single

  configure_ocfs2_cluster
  create_filesystem
  mount_fs_all_nodes
  run_tests
  collect_reports

  trap - INT TERM
  log_info "Готово. Для очистки: sudo ./deploy_ocfs2_cluster.sh cleanup"
}

main
