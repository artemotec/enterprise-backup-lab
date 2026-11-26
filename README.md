# Enterprise Backup Lab (PostgreSQL 16 + MS SQL Server 2022)

[![Enterprise Backup CI/CD](https://github.com/artemotec/enterprise-backup-lab/actions/workflows/ci-dr.yml/badge.svg)](https://github.com/artemotec/enterprise-backup-lab/actions/workflows/ci-dr.yml)

Лабораторный стенд, моделирующий промышленный контур резервного копирования и аварийного восстановления (Disaster Recovery) для высокодоступных СУБД (24×7×365) без остановки транзакций, с автоматической верификацией бэкапов через **GitHub Actions CI/CD**.

## Сравнительная таблица модулей

| Параметр | Модуль 1: PostgreSQL 16 | Модуль 2: MS SQL Server 2022 |
| :--- | :--- | :--- |
| **Инструменты СРК** | `pgBackRest 2.60.1` + WAL Archiving | Native Backup (`FULL` Recovery Model) |
| **Хранилище** | SeaweedFS S3 по HTTPS (TLS) | Локальный том `/var/opt/mssql/backup` |
| **Сжатие** | Потоковое `zstd` (29.5 МБ → 3.6 МБ, ~8.2×) | Встроенное `COMPRESSION` |
| **Целевой RPO** | Близкий к нулю (непрерывный WAL) | **RPO = 0** (через Tail-Log Backup) |
| **Сценарии аварии** | Логическая ошибка (`DROP TABLE`) → PITR | Потеря файла данных `.mdf` + разрыв LSN |

## CI/CD и Continuous DR Testing

В репозитории настроен конвейер **GitHub Actions** (`.github/workflows/ci-dr.yml`), работающий на **Self-Hosted Runner** (Linux / WSL2 + Docker) и реализующий принцип **3-2-1-1-0** (автоматическая верификация восстанавливаемости):

1. **Lint & Validate:** проверка синтаксиса и прав исполнения (`+x`) всех bash-скриптов, валидация `s3/s3.json` и манифестов `docker-compose.yml`.
2. **Automated DR Test — PostgreSQL 16:** генерация TLS-сертификатов, подъём чистого стека с SeaweedFS S3, инициализация `pgBackRest`, воспроизведение аварии (`DROP TABLE`) и автоматический PITR на узел `pg-dr`.
3. **Automated DR Test — MS SQL Server 2022:** прогон потери файла данных `.mdf` с восстановлением через Tail-Log Backup (`RPO = 0`) и проверка защиты LSN-цепочки через `WITH COPY_ONLY`.
4. **Аудит и расписание:** логи восстановления с замеренным **RTO** сохраняются в **GitHub Artifacts** (`postgres-dr-report`, `mssql-dr-report`) сроком на 30 дней; пайплайн запускается при каждом `push`, вручную (`workflow_dispatch`) и по ночному расписанию (`cron: 0 3 * * *`).

## Структура репозитория

```text
enterprise-backup-lab/
├── .github/workflows/
│   └── ci-dr.yml                       # CI/CD пайплайн: Lint + DR-тесты + RTO-артефакты
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
git clone [https://github.com/artemotec/enterprise-backup-lab.git](https://github.com/artemotec/enterprise-backup-lab.git)
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
