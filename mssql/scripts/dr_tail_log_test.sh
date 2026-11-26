#!/usr/bin/env bash
set -euo pipefail

SA_PASS="StrongPassword123!"

run_sql() {
  sudo docker exec mssql-prod bash -c '
    if [ -x /opt/mssql-tools18/bin/sqlcmd ]; then
      /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "'"$SA_PASS"'" -C -b -Q "$1"
    else
      /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "'"$SA_PASS"'" -b -Q "$1"
    fi
  ' -- "$1"
}

wait_mssql() {
  echo "Ожидание готовности MS SQL Server..."
  until run_sql "SELECT 1" >/dev/null 2>&1; do
    sleep 2
  done
}

wait_mssql
sudo docker exec mssql-prod mkdir -p /var/opt/mssql/backup

echo "=== 1. Создание БД ProdDB (Recovery Model = FULL) и генерация данных ==="
run_sql "
IF DB_ID('ProdDB') IS NOT NULL
BEGIN
    ALTER DATABASE [ProdDB] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE [ProdDB];
END
CREATE DATABASE [ProdDB];
ALTER DATABASE [ProdDB] SET RECOVERY FULL;
"

run_sql "
USE [ProdDB];
CREATE TABLE dbo.Payments (
    Id INT IDENTITY(1,1) PRIMARY KEY,
    Stage NVARCHAR(100),
    Amount DECIMAL(18,2),
    CreatedAt DATETIME2 DEFAULT SYSUTCDATETIME()
);
INSERT INTO dbo.Payments (Stage, Amount)
SELECT TOP (1000) 'Initial_Load', 100.00
FROM sys.all_objects a CROSS JOIN sys.all_objects b;
"

echo "=== 2. Снятие Full Backup (со сжатием) ==="
run_sql "
BACKUP DATABASE [ProdDB]
TO DISK = '/var/opt/mssql/backup/ProdDB_Full.bak'
WITH FORMAT, INIT, COMPRESSION, NAME = 'ProdDB-Full';
"

echo "=== 3. Запись новых данных и снятие Differential Backup ==="
run_sql "
USE [ProdDB];
INSERT INTO dbo.Payments (Stage, Amount) VALUES ('Before_Diff', 2500.50);
"
run_sql "
BACKUP DATABASE [ProdDB]
TO DISK = '/var/opt/mssql/backup/ProdDB_Diff.bak'
WITH DIFFERENTIAL, FORMAT, INIT, COMPRESSION, NAME = 'ProdDB-Diff';
"

echo "=== 4. Запись новых данных и снятие Transaction Log Backup ==="
run_sql "
USE [ProdDB];
INSERT INTO dbo.Payments (Stage, Amount) VALUES ('Before_Log1', 5000.00);
"
run_sql "
BACKUP LOG [ProdDB]
TO DISK = '/var/opt/mssql/backup/ProdDB_Log1.trn'
WITH FORMAT, INIT, COMPRESSION, NAME = 'ProdDB-Log1';
"

echo "=== 5. Критичная транзакция (НЕ попала ни в один плановый бэкап!) ==="
run_sql "
USE [ProdDB];
INSERT INTO dbo.Payments (Stage, Amount) VALUES ('CRITICAL_TX_RPO_ZERO', 777777.77);
"

echo "=== 6. Имитация аварии диска данных: удаление ProdDB.mdf + жёсткий сбой ==="
sudo docker exec mssql-prod rm -f /var/opt/mssql/data/ProdDB.mdf
sudo docker kill mssql-prod >/dev/null
sudo docker start mssql-prod >/dev/null
wait_mssql

echo "Состояние БД после аварии (ожидается RECOVERY_PENDING):"
run_sql "SELECT name, state_desc FROM sys.databases WHERE name = 'ProdDB';"

echo "=== 7. Аварийное восстановление: Tail-Log Backup -> Full -> Diff -> Log -> Tail-Log ==="
START_SEC=$(date +%s)

run_sql "
BACKUP LOG [ProdDB]
TO DISK = '/var/opt/mssql/backup/ProdDB_TailLog.trn'
WITH NO_TRUNCATE, FORMAT, INIT;
"

run_sql "
RESTORE DATABASE [ProdDB]
FROM DISK = '/var/opt/mssql/backup/ProdDB_Full.bak'
WITH NORECOVERY, REPLACE;
"

run_sql "
RESTORE DATABASE [ProdDB]
FROM DISK = '/var/opt/mssql/backup/ProdDB_Diff.bak'
WITH NORECOVERY;
"

run_sql "
RESTORE LOG [ProdDB]
FROM DISK = '/var/opt/mssql/backup/ProdDB_Log1.trn'
WITH NORECOVERY;
"

run_sql "
RESTORE LOG [ProdDB]
FROM DISK = '/var/opt/mssql/backup/ProdDB_TailLog.trn'
WITH RECOVERY;
"

END_SEC=$(date +%s)
RTO=$((END_SEC - START_SEC))

echo "=== 8. Верификация данных (RPO = 0) ==="
run_sql "
USE [ProdDB];
SELECT COUNT(*) AS TotalRows FROM dbo.Payments;
SELECT Id, Stage, Amount FROM dbo.Payments WHERE Stage <> 'Initial_Load' ORDER BY Id;
"

echo "=================================================="
echo "Восстановление завершено успешно! RPO = 0 потерь."
echo "Фактический RTO: ${RTO} сек."
echo "=================================================="
