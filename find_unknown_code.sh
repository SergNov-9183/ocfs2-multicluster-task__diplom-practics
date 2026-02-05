#!/bin/bash
# Поиск источника сообщения "Unknown code ocfs 8 while reading region"
# Запуск: ./find_unknown_code.sh

set -e
REPO="${1:-/tmp/ocfs2-tools-search}"
echo "=== Поиск в ocfs2-tools: $REPO ==="
[ -d "$REPO" ] || { echo "Клон: git clone --depth 1 https://github.com/markfasheh/ocfs2-tools.git $REPO"; git clone --depth 1 https://github.com/markfasheh/ocfs2-tools.git "$REPO" 2>/dev/null || true; }

echo "--- 1) Строки с 'Unknown' ---"
grep -rn "Unknown" "$REPO" --include="*.c" --include="*.h" 2>/dev/null || true

echo "--- 2) Строки с 'reading region' ---"
grep -rn "reading region" "$REPO" --include="*.c" --include="*.h" 2>/dev/null || true

echo "--- 3) Строки с 'while reading' (часть сообщения) ---"
grep -rn "while reading" "$REPO" --include="*.c" --include="*.h" 2>/dev/null || true

echo "--- 4) Строки с 'on device' ---"
grep -rn "on device" "$REPO" --include="*.c" --include="*.h" 2>/dev/null || true

echo "--- 5) Поиск в ядре (если есть): /lib/modules/$(uname -r)/build ---"
KSRC="/lib/modules/$(uname -r)/build"
if [ -d "$KSRC/fs/ocfs2" ]; then
  grep -rn "Unknown code\|reading region" "$KSRC/fs/ocfs2" --include="*.c" --include="*.h" 2>/dev/null || true
else
  echo "Исходники ядра не найдены. Поиск в fs/ocfs2: find /usr/src -name '*.c' -path '*ocfs2*' 2>/dev/null | head -5"
fi
