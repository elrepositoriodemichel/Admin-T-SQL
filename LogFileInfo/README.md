# 📋 Información de Ficheros de Log — Todas las Bases de Datos

Script de diagnóstico que recopila información general y de espacio de los ficheros de log (`.ldf`) de todas las bases de datos en línea de la instancia, incluyendo el espacio libre real calculado dinámicamente.

---

## ¿Por qué es importante?

Los ficheros de log son el componente más sensible de SQL Server en términos de espacio y rendimiento. Monitorizarlos de forma centralizada permite:

- Detectar ficheros con **autogrowth configurado en porcentaje** (práctica no recomendada)
- Identificar bases de datos con **log_reuse_wait** distinto de `NOTHING`, lo que indica que el log no puede reutilizarse y crecerá indefinidamente
- Detectar **ficheros próximos a su tamaño máximo** configurado
- Identificar bases de datos con **poco espacio libre** en el log antes de que provoquen un error de espacio en disco

---

## Script base

Utiliza una tabla temporal para recopilar el espacio utilizado de cada fichero de log ejecutando dinámicamente `FILEPROPERTY` en el contexto de cada base de datos.

```sql
CREATE TABLE #SpaceUsed 
	(
		database_id SMALLINT NOT NULL,
		file_id		SMALLINT NOT NULL,
		space_used	DECIMAL(15,3) NOT NULL
			PRIMARY KEY (database_id, file_id)
	);

DECLARE @sql NVARCHAR(max);
SET @sql = N'';

SELECT @sql += 'USE ' + QUOTENAME(name) + ';
				INSERT INTO #SpaceUsed
					SELECT
						DB_ID(),
						file_id,
						FILEPROPERTY(name,''SpaceUsed'') / 128.0
					FROM sys.database_files
					WHERE type = 1;'
FROM sys.databases
WHERE state = 0;

EXEC sp_executesql @sql;

SELECT 
	d.database_id AS [Database Id],
	d.name AS [Name],
	f.physical_name AS [Phyical Name],
	d.state_desc AS [State Desc],
	d.recovery_model_desc AS [Recovery Model Desc],
	d.log_reuse_wait_desc AS [Log Reuse Wait Desc],
	CONVERT(DECIMAL(15, 3), f.size / 128.0) AS [Size in Mb],
	s.space_used AS [Space Used in Mb],
	CONVERT(DECIMAL(15, 3), f.size / 128.0 - s.space_used) AS [Unused in Mb],
	IIF(f.is_percent_growth = 1, f.growth, CONVERT(DECIMAL(15, 3), f.growth / 128.0)) AS [Growth],
	IIF(f.is_percent_growth = 1, '%', 'Mb') AS [Growth Mode],
	IIF(f.max_size = -1, NULL, CONVERT(DECIMAL(15, 3), f.max_size / 128.0)) AS [Max Size in Mb]	
FROM 
	sys.databases d 
		INNER JOIN
	sys.master_files f ON f.database_id = d.database_id
		INNER JOIN
	#SpaceUsed s ON f.database_id = s.database_id AND f.file_id = s.file_id

DROP TABLE #SpaceUsed;
```

---

## Interpretación de campos

| Campo | Descripción | Cuándo preocuparse |
|---|---|---|
| `State Desc` | Estado de la base de datos | Cualquier valor distinto de `ONLINE` |
| `Recovery Model Desc` | Modelo de recuperación (`FULL`, `SIMPLE`, `BULK_LOGGED`) | `SIMPLE` en BDs que deberían tener `FULL` |
| `Log Reuse Wait Desc` | Razón por la que el log no puede reutilizarse | Cualquier valor distinto de `NOTHING` o `LOG_BACKUP` |
| `Size in Mb` | Tamaño total actual del fichero de log en disco | |
| `Space Used in Mb` | Espacio ocupado por log activo en el fichero | |
| `Unused in Mb` | Espacio libre disponible en el fichero sin necesidad de autogrowth | Valores muy bajos indican riesgo de autogrowth inminente |
| `Growth` | Valor de crecimiento automático | |
| `Growth Mode` | `%` o `Mb` — indica si el autogrowth es en porcentaje o en megabytes | `%` no es recomendable |
| `Max Size in Mb` | Tamaño máximo permitido — `NULL` si no tiene límite configurado (`-1`) | Ficheros próximos a su límite máximo |

### Valores de `Log Reuse Wait Desc` y su significado

| Valor | Significado | Acción recomendada |
|---|---|---|
| `NOTHING` | El log puede reutilizarse con normalidad | — |
| `LOG_BACKUP` | Esperando el siguiente backup de log | Ejecutar `BACKUP LOG` |
| `ACTIVE_TRANSACTION` | Hay una transacción activa larga o abierta | Identificar y revisar la transacción (ver script de [transacciones activas más antiguas](https://github.com/elrepositoriodemichel/Admin-T-SQL/tree/main/OldestActiveTransactions) ) |
| `DATABASE_MIRRORING` | Lag en el mirror | Revisar el estado del mirroring |
| `AVAILABILITY_REPLICA` | Lag en réplica secundaria de Always On | Revisar el estado de sincronización |
| `REPLICATION` | Transacciones pendientes de replicar | Revisar el agente de replicación |
| `ACTIVE_BACKUP_OR_RESTORE` | Backup o restauración en curso | Esperar a que finalice |
| `LOG_SCAN` | Escaneo de log en progreso | Transitorio — si persiste, investigar |

> ⚠️ **Autogrowth en porcentaje no es recomendable.** En ficheros de log grandes, un crecimiento del 10% puede suponer cientos de MB o incluso GB de una sola vez, lo que causa una pausa notable en el servidor durante el crecimiento. Siempre es preferible configurar el autogrowth en MB con un valor fijo que genere VLFs de tamaño uniforme.

---

## Versión extendida con sys.dm_db_log_stats

`sys.dm_db_log_stats` proporciona métricas adicionales de diagnóstico del log a **nivel de base de datos**: VLFs activos, LSN de recuperación, último backup de log, etc. Se puede incorporar al script anterior mediante un `CROSS APPLY`.

> ⚠️ **Importante:** `dm_db_log_stats` devuelve **una fila por base de datos**, no por fichero de log. Si una base de datos tiene más de un fichero de log (práctica no recomendada), sus datos aparecerán **repetidos** en tantas filas como ficheros de log tenga. En la práctica, con la configuración correcta de una sola fichero de log por base de datos, el resultado es uno a uno.

```sql
CREATE TABLE #SpaceUsed 
	(
		database_id SMALLINT NOT NULL,
		file_id		SMALLINT NOT NULL,
		space_used	DECIMAL(15,3) NOT NULL
			PRIMARY KEY (database_id, file_id)
	);

DECLARE @sql NVARCHAR(max);
SET @sql = N'';

SELECT @sql += 'USE ' + QUOTENAME(name) + ';
               INSERT INTO #SpaceUsed
                   SELECT
                       DB_ID(),
                       file_id,
                       FILEPROPERTY(name, ''SpaceUsed'') / 128.0
                   FROM sys.database_files
                   WHERE type = 1;'
FROM sys.databases
WHERE state = 0;

EXEC sp_executesql @sql;

SELECT 
	d.database_id AS [Database Id],
	d.name AS [Name],
	f.physical_name AS [Phyical Name],
	d.state_desc AS [State Desc],
	d.recovery_model_desc AS [Recovery Model Desc],
	d.log_reuse_wait_desc AS [Log Reuse Wait Desc],
	CONVERT(DECIMAL(15, 3), f.size / 128.0) AS [Size in Mb],
	s.space_used AS [Space Used in Mb],
	CONVERT(DECIMAL(15, 3), f.size / 128.0 - s.space_used) AS [Unused in Mb],
	IIF(f.is_percent_growth = 1, f.growth, CONVERT(DECIMAL(15, 3), f.growth / 128.0)) AS [Growth],
	IIF(f.is_percent_growth = 1, '%', 'Mb') AS [Growth Mode],
	IIF(f.max_size = -1, NULL, CONVERT(DECIMAL(15, 3), f.max_size / 128.0)) AS [Max Size in Mb],
	 -- Campos adicionales de dm_db_log_stats (nivel base de datos, no fichero)
	ls.total_vlf_count AS [Total VLF Count],
	ls.active_vlf_count AS [Active VLF Count],
	ls.active_log_size_mb AS [Active Log Size Mb],
	ls.log_backup_time AS [Last Log Backup Time],
	ls.log_since_last_log_backup_mb AS [Log Since Last Backup Mb],
	ls.log_since_last_checkpoint_mb AS [Log Since Last Checkpoint Mb]
FROM 
	sys.databases d 
		INNER JOIN
	sys.master_files f ON f.database_id = d.database_id
		INNER JOIN
	#SpaceUsed s ON f.database_id = s.database_id AND f.file_id = s.file_id
        CROSS APPLY -- CROSS APPLY acepta database_id como parámetro, evitando SQL dinámico adicional
    sys.dm_db_log_stats(d.database_id) ls;

DROP TABLE #SpaceUsed;
```

### Campos adicionales de `dm_db_log_stats`

| Campo | Descripción | Cuándo preocuparse |
|---|---|---|
| `Total VLF Count` | Número total de VLFs en el fichero de log | > 200 VLFs indica fragmentación del log — considerar redistribución |
| `Active VLF Count` | VLFs que contienen log activo no reutilizable | Valor alto relativo al total indica que el log no se está vaciando |
| `Active Log Size Mb` | Tamaño en MB del log activo | |
| `Last Log Backup Time` | Fecha y hora del último backup de log | `NULL` o muy antiguo en BDs con Recovery Model `FULL` es una alerta crítica |
| `Log Since Last Backup Mb` | MB de log generados desde el último backup de log | Valores altos indican que la frecuencia de backup de log es insuficiente |
| `Log Since Last Checkpoint Mb` | MB de log generados desde el último checkpoint | |

---

## Vistas del sistema utilizadas

| Vista | Propósito |
|---|---|
| `sys.databases` | Estado, modelo de recuperación y `log_reuse_wait_desc` de cada base de datos |
| `sys.master_files` | Metadatos de todos los ficheros de datos y log a nivel de instancia |
| `sys.database_files` | Metadatos de ficheros en el contexto de cada base de datos `FILEPROPERTY` |
| `sys.dm_db_log_stats` | Métricas de diagnóstico del log por base de datos |
