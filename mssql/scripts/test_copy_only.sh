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

sudo docker exec mssql-prod mkdir -p /var/opt/mssql/backup

echo "=== Подготовка тестовой БД CopyOnlyLab ==="
run_sql "
IF DB_ID('CopyOnlyLab') IS NOT NULL
BEGIN
    ALTER DATABASE [CopyOnlyLab] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE [CopyOnlyLab];
END
IF DB_ID('CopyOnlyLab_Restore') IS NOT NULL
BEGIN
    ALTER DATABASE [CopyOnlyLab_Restore] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE [CopyOnlyLab_Restore];
END
CREATE DATABASE [CopyOnlyLab];
ALTER DATABASE [CopyOnlyLab] SET RECOVERY FULL;
"

run_sql "
USE [CopyOnlyLab];
CREATE TABLE dbo.AuditLog (Id INT IDENTITY PRIMARY KEY, Msg NVARCHAR(100));
INSERT INTO dbo.AuditLog (Msg) VALUES ('Row 1 - before planned Full');
"

echo "=== СЦЕНАРИЙ А: Внеплановый Full БЕЗ COPY_ONLY (ломает цепочку Diff) ==="
run_sql "BACKUP DATABASE [CopyOnlyLab] TO DISK = '/var/opt/mssql/backup/CO_Full_Planned.bak' WITH FORMAT, INIT;"
run_sql "BACKUP DATABASE [CopyOnlyLab] TO DISK = '/var/opt/mssql/backup/CO_Full_AdHoc_BAD.bak' WITH FORMAT, INIT;"
run_sql "INSERT INTO [CopyOnlyLab].dbo.AuditLog (Msg) VALUES ('Row 2 - before Diff');"
run_sql "BACKUP DATABASE [CopyOnlyLab] TO DISK = '/var/opt/mssql/backup/CO_Diff_Broken.bak' WITH DIFFERENTIAL, FORMAT, INIT;"

echo "Попытка восстановить Planned Full + Diff (ожидаем ошибку LSN 3136):"
run_sql "
RESTORE DATABASE [CopyOnlyLab_Restore]
FROM DISK = '/var/opt/mssql/backup/CO_Full_Planned.bak'
WITH NORECOVERY, REPLACE,
MOVE 'CopyOnlyLab' TO '/var/opt/mssql/data/CopyOnlyLab_Restore.mdf',
MOVE 'CopyOnlyLab_log' TO '/var/opt/mssql/data/CopyOnlyLab_Restore_log.ldf';
"

if run_sql "RESTORE DATABASE [CopyOnlyLab_Restore] FROM DISK = '/var/opt/mssql/backup/CO_Diff_Broken.bak' WITH RECOVERY;"; then
  echo "ОШИБКА: Восстановление не должно было пройти!"
  exit 1
else
  echo ">>> Подтверждено: цепочка сломана (LSN mismatch), Diff нельзя накатить на плановый Full."
fi

echo ""
echo "=== СЦЕНАРИЙ Б: Внеплановый Full С флагом WITH COPY_ONLY (цепочка цела) ==="
run_sql "DROP DATABASE [CopyOnlyLab_Restore];"
run_sql "BACKUP DATABASE [CopyOnlyLab] TO DISK = '/var/opt/mssql/backup/CO_Full_Planned2.bak' WITH FORMAT, INIT;"
run_sql "BACKUP DATABASE [CopyOnlyLab] TO DISK = '/var/opt/mssql/backup/CO_Full_AdHoc_GOOD.bak' WITH COPY_ONLY, FORMAT, INIT;"
run_sql "INSERT INTO [CopyOnlyLab].dbo.AuditLog (Msg) VALUES ('Row 3 - valid Diff after COPY_ONLY');"
run_sql "BACKUP DATABASE [CopyOnlyLab] TO DISK = '/var/opt/mssql/backup/CO_Diff_Valid.bak' WITH DIFFERENTIAL, FORMAT, INIT;"

run_sql "
RESTORE DATABASE [CopyOnlyLab_Restore]
FROM DISK = '/var/opt/mssql/backup/CO_Full_Planned2.bak'
WITH NORECOVERY, REPLACE,
MOVE 'CopyOnlyLab' TO '/var/opt/mssql/data/CopyOnlyLab_Restore.mdf',
MOVE 'CopyOnlyLab_log' TO '/var/opt/mssql/data/CopyOnlyLab_Restore_log.ldf';
"
run_sql "RESTORE DATABASE [CopyOnlyLab_Restore] FROM DISK = '/var/opt/mssql/backup/CO_Diff_Valid.bak' WITH RECOVERY;"

echo ">>> Успех! Содержимое восстановленной БД CopyOnlyLab_Restore:"
run_sql "SELECT * FROM [CopyOnlyLab_Restore].dbo.AuditLog;"
