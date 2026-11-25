# Enterprise Backup Lab (PostgreSQL 16 + pgBackRest + S3)

Практический лабораторный стенд, моделирующий промышленный контур резервного копирования и аварийного восстановления (Disaster Recovery) для высокодоступных баз данных (24×7×365) без остановки транзакций.

---

## Что сделано

1. **Контейнерная инфраструктура (`docker-compose.yml`):**
   * **`pg-primary`** — продуктовый сервер PostgreSQL 16 (`postgres:16-bookworm`) со встроенным `pgBackRest 2.60.1` и непрерывной архивацией WAL-сегментов (`wal_level=replica`, `archive_mode=on`, `archive_timeout=60`).
   * **`backup-s3` (SeaweedFS)** — S3-совместимое объектное хранилище, настроенное для работы по защищённому протоколу **HTTPS (TLS)** с аутентификацией по ключам доступа.
   * **`s3-init`** — сервисный init-контейнер, автоматически создающий целевой бакет `pg-backups` перед запуском СУБД.
   * **`pg-dr`** — изолированный резервный узел (Standby / DR Node) для регулярного тестирования аварийного восстановления.

2. **Конфигурация СРК (`postgres/pgbackrest.conf`):**
   * Настроено потоковое сжатие бэкапов и архивов WAL алгоритмом **`zstd`**.
   * Задана политика хранения (Retention Policy): удержание 2 полных копий (`repo1-retention-full=2`) с автоматической ротацией устаревших бэкапов и WAL-сегментов.
   * Включён ускоренный запуск контрольной точки (`start-fast=y`) для минимизации времени старта резервного копирования.

3. **Автоматизация DR-тестирования (`scripts/dr_test.sh`):**
   * Написан bash-скрипт полного цикла верификации резервных копий (принцип **3-2-1-1-0**): генерация нагрузки, снятие `Full`-бэкапа, фиксация критичной транзакции и точного времени в UTC, имитация логической аварии (`DROP TABLE orders;`), принудительный сброс WAL (`pg_switch_wal()`), восстановление на `pg-dr` на момент до сбоя (**PITR**) и сверка контрольных сумм.

---

## Что получено (результаты и метрики)

* **Нулевое окно простоя (Hot Backup):** резервные копии снимаются в горячем режиме без блокировки чтения и записи на основном сервере.
* **Минимальный RPO (близкий к нулю):** непрерывная отправка WAL-журналов в S3 позволяет откатить базу на любую конкретную секунду до логической ошибки или сбоя.
* **Высокая степень сжатия (`zstd`):** базовый кластер PostgreSQL размером **29.5 МБ** сжимается в репозитории S3 до **3.6 МБ** (коэффициент сжатия **~8.2×**), время снятия полного бэкапа — **~4 секунды**.
* **Защита продакшен-архива при тестах:** при восстановлении на узел `pg-dr` автоматически отключается архивация (`archive_mode=off`), что исключает перезапись или конфликт WAL-цепочки боевой базы.
* **Измеряемый RTO:** скрипт `dr_test.sh` автоматически замеряет реальное время от старта команды `restore` до готовности восстановленной БД принимать запросы.

---

## Архитектура и структура репозитория

```text
[pg-primary (PostgreSQL 16)]
       │
       ├── Continuous WAL Archiving (zstd) ──► [SeaweedFS S3 (HTTPS / TLS)]
       └── Full / Incr Backups (pgBackRest) ──────────┘
                                                      │
[pg-dr (Isolated DR Node)] ◄── Point-in-Time Recovery (PITR)
```

```text
enterprise-backup-lab/
├── docker-compose.yml              # Оркестрация PostgreSQL, DR-узла и S3-хранилища
├── postgres/
│   ├── Dockerfile                  # Образ PostgreSQL 16 + pgBackRest
│   ├── init-pgbackrest.sh          # Инициализация параметров WAL и архивации
│   └── pgbackrest.conf             # Конфигурация репозитория S3, сжатия и ротации
├── s3/
│   └── s3.json                     # Учётные записи и права доступа к S3
├── scripts/
│   └── dr_test.sh                  # Автоматический сценарий PITR-теста и замера RTO
└── .gitignore                      # Исключение приватных TLS-ключей (*.pem) и логов
```

---

## Быстрый старт

### 1. Клонирование и генерация TLS-сертификата для S3
`pgBackRest` требует защищённого соединения (HTTPS) при работе с S3-хранилищем. Сгенерируйте самоподписанный сертификат:

```bash
git clone [https://github.com/](https://github.com/)<твой-ник>/enterprise-backup-lab.git
cd enterprise-backup-lab

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout s3/key.pem \
  -out s3/cert.pem \
  -days 365 \
  -subj "/CN=minio"

chmod 644 s3/key.pem s3/cert.pem
```

### 2. Запуск инфраструктуры
Поднимите контейнеры и перезапустите `pg-primary` после первичной инициализации, чтобы применить параметр `archive_mode=on`:

```bash
sudo docker compose up -d --build
sleep 10
sudo docker restart pg-primary
```

### 3. Инициализация профиля `pgBackRest` и проверка связи
Создайте `stanza` в S3 и проверьте корректность прохождения тестового WAL-сегмента:

```bash
sudo docker exec -u postgres pg-primary pgbackrest --stanza=prod stanza-create
sudo docker exec -u postgres pg-primary pgbackrest --stanza=prod check
```
*Ожидаемый результат:* `INFO: check command end: completed successfully`.

### 4. Снятие бэкапов и запуск DR-теста (PITR)
```bash
# Снять полный бэкап и проверить статус репозитория
sudo docker exec -u postgres pg-primary pgbackrest --stanza=prod --type=full backup
sudo docker exec -u postgres pg-primary pgbackrest info

# Запустить автоматический сценарий аварии и восстановления на pg-dr
chmod +x scripts/dr_test.sh
./scripts/dr_test.sh
```
Содержимое S3-бакета с бэкапами и архивами WAL доступно для просмотра в браузере по адресу: `http://localhost:8888/buckets/pg-backups/`.

---

## Полезные команды эксплуатации

* **Снять инкрементальный бэкап:**
  ```bash
  sudo docker exec -u postgres pg-primary pgbackrest --stanza=prod --type=incr backup
  ```
* **Проверить статистику архиватора WAL в PostgreSQL:**
  ```bash
  sudo docker exec -u postgres pg-primary psql -c "SELECT archived_count, last_archived_wal, failed_count FROM pg_stat_archiver;"
  ```
* **Остановить стенд с удалением томов данных:**
  ```bash
  sudo docker compose down -v
  ```
