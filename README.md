# Enterprise Backup Lab (PostgreSQL 16 + MS SQL Server 2022)

Лабораторный стенд, моделирующий промышленный контур резервного копирования и аварийного восстановления (Disaster Recovery) для высокодоступных СУБД (24×7×365) без остановки транзакций.

## Сравнительная таблица модулей

| Параметр | Модуль 1: PostgreSQL 16 | Модуль 2: MS SQL Server 2022 |
| :--- | :--- | :--- |
| **Инструменты СРК** | `pgBackRest 2.60.1` + WAL Archiving | Native Backup (`FULL` Recovery Model) |
| **Хранилище** | SeaweedFS S3 по HTTPS (TLS) | Локальный том `/var/opt/mssql/backup` |
| **Сжатие** | Потоковое `zstd` (29.5 МБ → 3.6 МБ, ~8.2×) | Встроенное `COMPRESSION` |
| **Целевой RPO** | Близкий к нулю (непрерывный WAL) | **RPO = 0** (через Tail-Log Backup) |
| **Сценарии аварии** | Логическая ошибка (`DROP TABLE`) → PITR | Потеря файла данных `.mdf` + разрыв LSN |

## Структура репозитория

```text
enterprise-backup-lab/
├── docker-compose.yml                  # Модуль 1: PostgreSQL 16 + pgBackRest + S3 (TLS)
├── postgres/                           # Dockerfile, инициализация WAL и pgbackrest.conf
├── s3/                                 # Конфигурация SeaweedFS S3
├── scripts/
│   └── dr_test.sh                      # Автотест PITR на изолированный узел pg-dr + RTO
└── mssql/                              # Модуль 2: MS SQL Server 2022
    ├── docker-compose.yml              # Контейнер MS SQL Server (порт 11433)
    ├── scripts/
    │   ├── dr_tail_log_test.sh         # Потеря .mdf -> Tail-Log -> Full/Diff/Log -> RPO=0
    │   └── test_copy_only.sh           # Ошибка разрыва LSN (Msg 3136) vs WITH COPY_ONLY
    └── README.md                       # DR Runbook для MS SQL Server
```

## Быстрый старт

### Модуль 1: PostgreSQL 16 + pgBackRest + S3
```bash
git clone [https://github.com/](https://github.com/)<твой-ник>/enterprise-backup-lab.git
cd enterprise-backup-lab

# 1. Генерация TLS-сертификата для S3
openssl req -x509 -newkey rsa:2048 -nodes -keyout s3/key.pem -out s3/cert.pem -days 365 -subj "/CN=minio"
chmod 644 s3/key.pem s3/cert.pem

# 2. Запуск инфраструктуры и инициализация pgBackRest
sudo docker compose up -d --build
sleep 10 && sudo docker restart pg-primary
sudo docker exec -u postgres pg-primary pgbackrest --stanza=prod stanza-create
sudo docker exec -u postgres pg-primary pgbackrest --stanza=prod check

# 3. Автоматический DR-тест (PITR + замер RTO)
./scripts/dr_test.sh
```
*Порты подключения:* Primary — `127.0.0.1:15432`, DR-узел — `127.0.0.1:15433`, веб-интерфейс S3 — `http://localhost:8888/buckets/pg-backups/`.

### Модуль 2: MS SQL Server 2022 (RPO = 0 и COPY_ONLY)
```bash
cd mssql
sudo docker compose up -d

# Тест потери .mdf и восстановления через Tail-Log Backup (RPO = 0)
./scripts/dr_tail_log_test.sh

# Тест защиты цепочки LSN через WITH COPY_ONLY
./scripts/test_copy_only.sh
```
*Порт подключения:* `127.0.0.1,11433` (пользователь `sa`, `trustServerCertificate=true`).
