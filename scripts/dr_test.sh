#!/usr/bin/env bash
set -euo pipefail

echo "=== 1. Наполнение тестовыми данными и снятие Full-бэкапа ==="
sudo docker exec -u postgres pg-primary psql -d prod_db -c "
DROP TABLE IF EXISTS orders;
CREATE TABLE orders (id serial PRIMARY KEY, amount numeric, created_at timestamptz DEFAULT now());
INSERT INTO orders (amount) SELECT round((random()*1000)::numeric, 2) FROM generate_series(1, 5000);
"
sudo docker exec -u postgres pg-primary pgbackrest --stanza=prod --type=full backup

echo "=== 2. Запись критичной транзакции и фиксация точки восстановления ==="
sudo docker exec -u postgres pg-primary psql -d prod_db -c "
INSERT INTO orders (amount) VALUES (99999.99);
"
TARGET_TIME=$(sudo docker exec -u postgres pg-primary psql -d prod_db -tAc "SELECT to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS.US+00');")
echo "Точка здорового состояния (UTC): $TARGET_TIME"
sleep 2

echo "=== 3. Имитация аварии (DROP TABLE) и принудительный сброс WAL ==="
sudo docker exec -u postgres pg-primary psql -d prod_db -c "DROP TABLE orders;"
sudo docker exec -u postgres pg-primary psql -d prod_db -c "SELECT pg_switch_wal();"
sleep 3

echo "=== 4. Запуск аварийного восстановления (PITR) на узел pg-dr ==="
START_SEC=$(date +%s)

sudo docker exec -u postgres pg-dr bash -c "
pg_ctl -D /var/lib/postgresql/data stop -m immediate >/dev/null 2>&1 || true
rm -rf /var/lib/postgresql/data/*
pgbackrest --stanza=prod --delta restore --type=time --target=\"$TARGET_TIME\" --target-action=promote
pg_ctl -D /var/lib/postgresql/data -o \"-c archive_mode=off\" -l /tmp/pg_dr.log start
"

END_SEC=$(date +%s)
RTO=$((END_SEC - START_SEC))

echo "=== 5. Верификация данных на pg-dr ==="
RESTORED_COUNT=$(sudo docker exec -u postgres pg-dr psql -d prod_db -tAc "SELECT count(*) FROM orders;")
VIP_ORDER=$(sudo docker exec -u postgres pg-dr psql -d prod_db -tAc "SELECT amount FROM orders WHERE amount = 99999.99;")

echo "Восстановлено строк: $RESTORED_COUNT (ожидалось 5001)"
echo "Критичный заказ найден: $VIP_ORDER"
echo "Фактический RTO: ${RTO} сек."
