# Профили xfstests

Каталог отделён от главного скрипта, чтобы конфигурации не смешивались.

| Файл | Скрипт запуска | Что покрывает дополнительно |
|------|----------------|-----------------------------|
| `default.env` | `deploy_ocfs2_cluster.sh` | generic CRUD, mmap, fallocate — ядро file/inode/dir/alloc |
| `features.env` | `deploy_ocfs2_cluster_2.sh` | xattr, ACL, indexed dirs, refcount |
| `cluster.env` | `deploy_ocfs2_cluster_3.sh` | locks/DLM, параллельный доступ (лучше N≥2) |

Переменные подхватываются `run_tests.sh` внутри контейнера и `deploy_ocfs2_cluster.sh` на host (mkfs options).
