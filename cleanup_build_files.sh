#!/bin/bash

# Скрипт очистки файлов сборки ядра для освобождения места

set -euo pipefail

echo "Очистка файлов сборки ядра..."

cd /home/sergey/kernel-sources/noble

# Удалите ВСЕ объектные файлы и модули сборки
echo "1. Удаление всех объектных файлов (.o)..."
find . -name "*.o" -type f -delete 2>/dev/null || true

echo "2. Удаление всех модулей (.ko)..."
find . -name "*.ko" -type f -delete 2>/dev/null || true

echo "3. Удаление временных файлов сборки..."
find . -name "*.mod.c" -type f -delete 2>/dev/null || true
find . -name "*.mod" -type f -delete 2>/dev/null || true
find . -name "*.cmd" -type f -delete 2>/dev/null || true
find . -name ".tmp_*" -type f -delete 2>/dev/null || true
find . -name "*.d" -type f -delete 2>/dev/null || true

# Удалите директории сборки
echo "4. Удаление директорий сборки..."
rm -rf .tmp_versions 2>/dev/null || true
rm -rf Module.symvers 2>/dev/null || true
rm -rf modules.order 2>/dev/null || true
rm -rf .missing-syscalls.d .missing-syscalls 2>/dev/null || true

# Удалите собранное ядро (если есть)
echo "5. Удаление собранного ядра..."
rm -f vmlinux vmlinux.o System.map 2>/dev/null || true

# Проверьте размер
echo ""
echo "Размер после очистки:"
du -sh .
echo ""
echo "Свободное место:"
df -h / | tail -1

echo ""
echo "Очистка завершена!"
