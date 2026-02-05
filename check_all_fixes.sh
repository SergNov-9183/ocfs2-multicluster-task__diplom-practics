#!/bin/bash
# Скрипт проверки всех исправлений

echo "=== Проверка всех исправлений ==="
echo ""

LATEST_REPORT=$(ls -td gcov_reports_* 2>/dev/null | head -1)

if [ -z "$LATEST_REPORT" ]; then
  echo "❌ Отчеты не найдены. Запустите сначала: sudo ./deploy_ocfs2_cluster.sh 4"
  exit 1
fi

echo "📁 Последний отчет: $LATEST_REPORT"
echo ""

# 1. Проверка HTML отчетов
echo "1️⃣ Проверка HTML отчетов..."
if [ -f "$LATEST_REPORT/kernel_html/index.html" ] && [ -s "$LATEST_REPORT/kernel_html/index.html" ]; then
  SIZE=$(du -h "$LATEST_REPORT/kernel_html/index.html" 2>/dev/null | cut -f1)
  echo "   ✅ kernel_html/index.html существует (размер: $SIZE)"
else
  echo "   ❌ kernel_html/index.html отсутствует или пуст"
fi

if [ -f "$LATEST_REPORT/tools_html/index.html" ] && [ -s "$LATEST_REPORT/tools_html/index.html" ]; then
  SIZE=$(du -h "$LATEST_REPORT/tools_html/index.html" 2>/dev/null | cut -f1)
  echo "   ✅ tools_html/index.html существует (размер: $SIZE)"
else
  echo "   ❌ tools_html/index.html отсутствует или пуст"
fi

# 2. Проверка сохранения тестов
echo ""
echo "2️⃣ Проверка сохранения тестов в папках нод..."
NODES_FOUND=0
for i in 1 2 3 4; do
  if [ -d "$LATEST_REPORT/node_${i}_tests" ]; then
    NODES_FOUND=$((NODES_FOUND + 1))
    if [ -f "$LATEST_REPORT/node_${i}_tests/test_results_ocfs2-node-${i}/node_info.txt" ]; then
      echo "   ✅ Node $i: тесты сохранены"
    else
      echo "   ⚠️  Node $i: папка есть, но node_info.txt отсутствует"
    fi
  fi
done
if [ $NODES_FOUND -eq 0 ]; then
  echo "   ❌ Папки с тестами не найдены"
fi

# 3. Проверка xfstests
echo ""
echo "3️⃣ Проверка xfstests..."
XFSTESTS_FOUND=0
for i in 1 2 3 4; do
  if [ -f "$LATEST_REPORT/node_${i}_tests/test_results_ocfs2-node-${i}/xfstests_summary.txt" ] 2>/dev/null; then
    XFSTESTS_FOUND=$((XFSTESTS_FOUND + 1))
    echo "   ✅ Node $i: xfstests результаты найдены"
  fi
done
if [ $XFSTESTS_FOUND -eq 0 ]; then
  echo "   ⚠️  xfstests результаты не найдены (возможно, xfstests не установлен)"
fi

# 4. Проверка логов на ошибки DRBD
echo ""
echo "4️⃣ Проверка логов на ошибки DRBD..."
if grep -q "I/O error on channel" "$LATEST_REPORT/test_results"/*.log 2>/dev/null; then
  echo "   ⚠️  Найдены ошибки I/O error on channel (возможно, нужна очистка)"
else
  echo "   ✅ Ошибок I/O error on channel не найдено"
fi

# 5. Проверка heartbeat
echo ""
echo "5️⃣ Проверка heartbeat в логах..."
if [ -f "ocfs2_bootstrap_last.log" ] && grep -q "Heartbeat запущен\|✓ Heartbeat запущен" ocfs2_bootstrap_last.log 2>/dev/null; then
  echo "   ✅ Heartbeat успешно запущен (согласно логам)"
else
  echo "   ⚠️  Не найдено подтверждение запуска heartbeat в логах"
fi

echo ""
echo "=== Проверка завершена ==="
echo ""
echo "Для просмотра отчетов:"
echo "  - Тесты: $LATEST_REPORT/test_results/index.html"
echo "  - Kernel coverage: $LATEST_REPORT/kernel_html/index.html"
echo "  - Tools coverage: $LATEST_REPORT/tools_html/index.html"
