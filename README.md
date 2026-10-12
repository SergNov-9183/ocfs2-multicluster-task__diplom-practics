# Стенд тестирования драйвера OCFS2

Сценарии поднимают на одной машине кластер OCFS2: общее блочное устройство DRBD на хосте, несколько контейнеров Docker и три профиля xfstests. Покрытие драйвера `fs/ocfs2` снимается gcov с ядра хоста.

## Три профиля

Профиль задаёт флаги `mkfs.ocfs2` и список тестов xfstests. Файлы лежат в `xfstests_configs/`. `TEST_DEV` - `/dev/drbd0`, scratch - отдельный loop внутри контейнера.

| Профиль | Скрипт | Что добавляет |
| --- | --- | --- |
| `default` | `deploy_ocfs2_cluster.sh` | Том `-T datafiles` без xattr, acl, refcount и квот. Базовый generic: файлы, каталоги, mmap, fallocate. |
| `features` | `deploy_ocfs2_cluster_2.sh` | `--fs-features` с xattr, acl, indexed-dirs, refcount и соседними флагами, монтирование `user_xattr,acl`. |
| `cluster` | `deploy_ocfs2_cluster_3.sh` | Уже набор features, тесты блокировок и параллельной записи. На каждом узле свой префикс имён файлов. |

Общий список `-g auto` на томе без этих флагов хуже: квоты, NFS, shutdown и freeze на OCFS2 пропускаются, а остальные тесты повторяют одни и те же пути `file.c`, `inode.c` и `dir.c`.

Сводный запуск гоняет три профиля подряд и объединяет строки: строка покрыта, если она исполнилась хотя бы в одном профиле.

```bash
sudo ./deploy_ocfs2_all.sh 4
```

На 4 узлах, 45877 исполняемых строк, 54 файла `fs/ocfs2`:

| Профиль | Покрытие |
| --- | --- |
| default | 86,8 % (39821 / 45877) |
| features | 88,5 % (40610 / 45877) |
| cluster | 87,6 % (40197 / 45877) |
| объединение | 94,3 % (43252 / 45877) |

По узлам объединённого прогона покрытие ниже сводки: узел исполняет свой слот и свой набор файлов. Узел 1 - 75,0 %, узел 2 - 72,1 %, узел 3 - 70,3 %, узел 4 - 67,6 %.

## Порядок одного прогона

`deploy_ocfs2_cluster.sh` (и обёртки `_2` / `_3`, которые только подставляют другой `.env`):

1. Проверяет Docker и DRBD 9 на хосте. Если minor занят, останавливает старый ресурс.
2. Создаёт сеть `ocfs2-network` и собирает образ `ocfs2-node:latest`.
3. Поднимает DRBD на хосте: backing-файл, loop, `drbdadm create-md`, `up`, `primary`. На хосте есть `/dev/drbd0`.
4. Перед новой настройкой снимает старые контейнеры, останавливает o2cb, размонтирует ocfs2 и выгружает модули `ocfs2`, `ocfs2_dlm`, `ocfs2_dlmfs`, `ocfs2_nodemanager`, `ocfs2_stack_o2cb`, `ocfs2_stackglue`. Так уходят застрявшие потоки `[o2hb-*]`. Если модуль не выгрузился, хост лучше перезагрузить.
5. Стирает подписи с начала `/dev/drbd0` (`wipefs`, `dd`). Последние 128 МиБ не трогает: там внутренние метаданные DRBD.
6. Запускает контейнеры: `--privileged`, `--device /dev/drbd0`, `--network`, фиксированный IP, возможности `SYS_ADMIN`, `SYS_MODULE`, `NET_ADMIN`, `SYS_RESOURCE`, каталог `/lib/modules` только для чтения.
7. На узле 1 выполняет `setup_ocfs2_cluster.sh ... bootstrap`: пишет `cluster.conf` и регистрирует кластер в o2cb. Heartbeat-регион здесь ещё не добавляется.
8. На узле 1 форматирует том: `mkfs.ocfs2 -F -N <узлы> -T datafiles --cluster-stack=o2cb --cluster-name=ocfs2cluster -L ocfs2vol`. Список `--fs-features` берётся из профиля.
9. После `mkfs` добавляет heartbeat на `/dev/drbd0` (`setup_ocfs2_cluster.sh ... heartbeat`), чтобы UUID региона совпал с суперблоком. `cluster.conf` копируется на узлы 2..N, там выполняется режим `register`.
10. Каждый узел, где устройство доступно, монтирует том в `/mnt/ocfs2` (`mount -i -t ocfs2`, при неудаче обычный `mount`).
11. В каждом смонтированном контейнере запускается `run_tests.sh`: сначала короткие операции стенда, затем `/opt/xfstests/check` со списком из профиля.
12. На хосте `lcov` читает `/sys/kernel/debug/gcov`, оставляет пути `*/fs/ocfs2/*` и пишет `kernel_ocfs2.info`. Рядом сохраняются журналы узлов. По этому файлу собирается HTML-отчёт драйвера. Если ocfs2-tools собраны с покрытием, их трассы складываются отдельно в `tools_html`.

Каталог отчёта: `gcov_reports_<профиль>_<дата>_<pid>/`.

- `index.html` - оглавление прогона;
- `kernel_ocfs2.info` - трасса lcov (строки `SF:`, `DA:`);
- `kernel_html/` - сводка и страницы файлов `fs/ocfs2`;
- `node_N_tests/kernel_html/` - те же файлы по счётчикам узла;
- `test_results/` - журналы xfstests.

`deploy_ocfs2_all.sh` вызывает три скрипта по очереди, затем `lcov -a` по трём `kernel_ocfs2.info`. Результат: `gcov_reports_merged_<дата>/`, внутри ссылки `default`, `features`, `cluster` на отдельные отчёты.

## Запуск

```bash
sudo ./deploy_ocfs2_cluster.sh 4
sudo ./deploy_ocfs2_cluster_2.sh 4
sudo ./deploy_ocfs2_cluster_3.sh 4
sudo ./deploy_ocfs2_all.sh 4
```

Один узел:

```bash
sudo ./deploy_ocfs2_cluster.sh 1
```

Очистка (контейнеры, сеть, o2cb, модули OCFS2, ресурс DRBD):

```bash
sudo ./deploy_ocfs2_cluster.sh cleanup
```

`deploy_ocfs2_all.sh cleanup` делает то же самое.
