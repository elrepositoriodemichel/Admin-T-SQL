# 📏 Baseline de SQL Server — Guía Completa

Una **baseline** es una fotografía del estado normal y saludable de tu servidor SQL Server y sus bases de datos. Sirve como punto de referencia para detectar degradaciones de rendimiento, planificar capacidad y diagnosticar incidencias. Sin ella, es imposible saber si algo ha empeorado o cuánto.

---

## ¿Por qué es importante?

Sin baseline, cuando un usuario reporta que "la aplicación va lenta" no tienes datos objetivos con los que comparar. Con una baseline puedes responder: *"El tiempo medio de respuesta de esta query era 200 ms hace tres meses, ahora es 1.800 ms — algo cambió."*

---

## 🗂️ Áreas de la baseline

1. [Configuración de la instancia](#1--configuración-de-la-instancia)
2. [Configuración de las bases de datos](#2--configuración-de-las-bases-de-datos)
3. [Hardware y sistema operativo](#3--hardware-y-sistema-operativo)
4. [Rendimiento y recursos](#4--rendimiento-y-recursos)
5. [Objetos y esquema](#5--objetos-y-esquema)
6. [Seguridad](#6--seguridad)
7. [Jobs y mantenimiento](#7--jobs-y-mantenimiento)
8. [Alta disponibilidad](#8--alta-disponibilidad)

---

## 1 · Configuración de la instancia

**Por qué importa:** Los valores de configuración de la instancia afectan directamente al rendimiento y la estabilidad. Conocer los valores actuales permite detectar cambios no autorizados o accidentales.

### ✅ Checklist

- [ ] Versión y edición de SQL Server, nivel de parche (SP / CU)
- [ ] Configuración de memoria (`max server memory`, `min server memory`)
- [ ] Grado máximo de paralelismo (`MAXDOP`) y umbral de paralelismo (`cost threshold for parallelism`)
- [ ] Compresión de backup por defecto
- [ ] `optimize for ad hoc workloads`
- [ ] Puertos de escucha y protocolos habilitados
- [ ] Collation de la instancia
- [ ] Número de archivos de `tempdb` y su configuración

### Cómo obtenerla

```sql
-- Versión y edición
SELECT @@VERSION;
SELECT SERVERPROPERTY('Edition') AS Edition,
       SERVERPROPERTY('ProductVersion') AS Version,
       SERVERPROPERTY('ProductLevel') AS SP,
       SERVERPROPERTY('ProductUpdateLevel') AS CU;

-- Configuración general de la instancia
SELECT name, value, value_in_use, description
FROM sys.configurations
ORDER BY name;

-- Archivos de tempdb
SELECT name, physical_name, size * 8 / 1024 AS size_mb, growth
FROM tempdb.sys.database_files;
```

---

## 2 · Configuración de las bases de datos

**Por qué importa:** Opciones como el modelo de recuperación, el autogrowth o el nivel de compatibilidad afectan tanto al rendimiento como a la capacidad de recuperación ante desastres.

### ✅ Checklist

- [ ] Modelo de recuperación (`FULL`, `SIMPLE`, `BULK_LOGGED`)
- [ ] Nivel de compatibilidad
- [ ] Tamaño actual y crecimiento de ficheros de datos y log
- [ ] Configuración de autogrowth (debería ser en MB, nunca en %)
- [ ] Collation de cada base de datos
- [ ] Estado de `AUTO_UPDATE_STATISTICS` y `AUTO_CREATE_STATISTICS`
- [ ] `PAGE_VERIFY` (debería ser `CHECKSUM`)
- [ ] `AUTO_CLOSE` y `AUTO_SHRINK` (ambos deberían estar en `OFF`)
- [ ] Estado de Query Store (habilitado / deshabilitado)

### Cómo obtenerla

```sql
SELECT
    name,
    recovery_model_desc,
    compatibility_level,
    collation_name,
    page_verify_option_desc,
    is_auto_update_stats_on,
    is_auto_create_stats_on,
    is_auto_close_on,
    is_auto_shrink_on,
    is_query_store_on
FROM sys.databases
WHERE database_id > 4   -- Excluye bases de datos del sistema
ORDER BY name;

-- Tamaño y configuración de ficheros por base de datos
SELECT
    DB_NAME(database_id)    AS database_name,
    name,
    type_desc,
    physical_name,
    size * 8 / 1024         AS current_size_mb,
    CASE is_percent_growth
        WHEN 1 THEN CAST(growth AS VARCHAR) + ' %'
        ELSE CAST(growth * 8 / 1024 AS VARCHAR) + ' MB'
    END                     AS autogrowth
FROM sys.master_files
ORDER BY database_id, type;
```

---

## 3 · Hardware y sistema operativo

**Por qué importa:** El rendimiento de SQL Server está directamente limitado por el hardware disponible. Conocer la línea base de recursos permite detectar cuándo el servidor está al límite de su capacidad.

### ✅ Checklist

- [ ] Número de CPUs físicas y lógicas (NUMA nodes)
- [ ] Memoria RAM total e instalada
- [ ] Tipo y velocidad de almacenamiento (HDD / SSD / NVMe)
- [ ] Latencia de I/O por unidad de disco en condiciones normales
- [ ] Configuración de energía del SO (debe ser `High Performance`)
- [ ] Versión del SO y nivel de parche
- [ ] Zona horaria del servidor

### Cómo obtenerla

```sql
-- CPUs y memoria desde SQL Server
SELECT
    cpu_count                                       AS logical_cpus,
    hyperthread_ratio,
    cpu_count / hyperthread_ratio                   AS physical_cpus,
    physical_memory_kb / 1024                       AS physical_memory_mb,
    sqlserver_start_time
FROM sys.dm_os_sys_info;

-- Latencia de I/O por fichero (baseline de almacenamiento)
SELECT
    DB_NAME(vfs.database_id)                        AS database_name,
    mf.physical_name,
    vfs.io_stall_read_ms,
    vfs.num_of_reads,
    CASE WHEN vfs.num_of_reads = 0 THEN 0
         ELSE vfs.io_stall_read_ms / vfs.num_of_reads
    END                                             AS avg_read_latency_ms,
    vfs.io_stall_write_ms,
    vfs.num_of_writes,
    CASE WHEN vfs.num_of_writes = 0 THEN 0
         ELSE vfs.io_stall_write_ms / vfs.num_of_writes
    END                                             AS avg_write_latency_ms
FROM sys.dm_io_virtual_file_stats(NULL, NULL) vfs
JOIN sys.master_files mf
    ON vfs.database_id = mf.database_id
    AND vfs.file_id = mf.file_id
ORDER BY avg_read_latency_ms DESC;
```

> 💡 **Referencia de latencias saludables:** < 1 ms en NVMe, < 5 ms en SSD, < 20 ms en HDD. Por encima de 50 ms hay un problema de almacenamiento.

---

## 4 · Rendimiento y recursos

**Por qué importa:** Esta es la parte más crítica de la baseline. Capturar métricas de rendimiento en momentos de carga normal permite comparar futuras situaciones de degradación contra un estado conocido como correcto.

### ✅ Checklist

- [ ] CPU media y picos en ventana representativa (mañana, mediodía, cierre de día)
- [ ] Uso de memoria del buffer pool
- [ ] Page life expectancy (PLE) — esperanza de vida de las páginas en memoria
- [ ] Top queries por CPU, lecturas y elapsed time
- [ ] Wait stats predominantes en condiciones normales
- [ ] Presión sobre `tempdb`
- [ ] Tasa de compilaciones y recompilaciones por segundo
- [ ] Batch requests por segundo (throughput de la instancia)

### Cómo obtenerla

```sql
-- Page Life Expectancy (debería ser > 300, idealmente > 1000)
SELECT
    object_name,
    counter_name,
    cntr_value
FROM sys.dm_os_performance_counters
WHERE counter_name = 'Page life expectancy';

-- Wait stats — qué está esperando el servidor
SELECT TOP 20
    wait_type,
    waiting_tasks_count,
    wait_time_ms,
    wait_time_ms / NULLIF(waiting_tasks_count, 0)   AS avg_wait_ms,
    signal_wait_time_ms,
    wait_time_ms - signal_wait_time_ms               AS resource_wait_ms
FROM sys.dm_os_wait_stats
WHERE wait_type NOT IN (   -- Excluye waits benignos de fondo
    'SLEEP_TASK','BROKER_TO_FLUSH','BROKER_TASK_STOP','CLR_AUTO_EVENT',
    'DISPATCHER_QUEUE_SEMAPHORE','FT_IFTS_SCHEDULER_IDLE_WAIT',
    'HADR_FILESTREAM_IOMGR_IOCOMPLETION','HADR_WORK_QUEUE',
    'LAZYWRITER_SLEEP','LOGMGR_QUEUE','ONDEMAND_TASK_QUEUE',
    'REQUEST_FOR_DEADLOCK_SEARCH','RESOURCE_QUEUE','SERVER_IDLE_CHECK',
    'SLEEP_DBSTARTUP','SLEEP_DCOMSTARTUP','SLEEP_MASTERDBREADY',
    'SLEEP_MASTERMDREADY','SLEEP_MASTERUPGRADED','SLEEP_MSDBSTARTUP',
    'SLEEP_SYSTEMTASK','SLEEP_TEMPDBSTARTUP','SNI_HTTP_ACCEPT',
    'SP_SERVER_DIAGNOSTICS_SLEEP','SQLTRACE_BUFFER_FLUSH',
    'SQLTRACE_INCREMENTAL_FLUSH_SLEEP','WAITFOR','XE_DISPATCHER_WAIT',
    'XE_TIMER_EVENT','BROKER_EVENTHANDLER','CHECKPOINT_QUEUE',
    'DBMIRROR_EVENTS_QUEUE','SQLTRACE_WAIT_ENTRIES'
)
ORDER BY wait_time_ms DESC;

-- Batch requests y compilaciones por segundo
SELECT
    counter_name,
    cntr_value
FROM sys.dm_os_performance_counters
WHERE object_name LIKE '%SQL Statistics%'
  AND counter_name IN (
      'Batch Requests/sec',
      'SQL Compilations/sec',
      'SQL Re-Compilations/sec'
  );

-- Uso actual del buffer pool por base de datos
SELECT
    DB_NAME(database_id)            AS database_name,
    COUNT(*) * 8 / 1024             AS buffer_pool_mb
FROM sys.dm_os_buffer_descriptors
WHERE database_id > 4
GROUP BY database_id
ORDER BY buffer_pool_mb DESC;
```

---

## 5 · Objetos y esquema

**Por qué importa:** El estado de los índices y las estadísticas tiene un impacto directo en la calidad de los planes de ejecución y en el rendimiento general. Una baseline del esquema permite detectar cambios no controlados.

### ✅ Checklist

- [ ] Número de tablas, índices, vistas y procedimientos por base de datos
- [ ] Fragmentación de índices en condiciones normales
- [ ] Estado de las estadísticas (fecha de última actualización)
- [ ] Índices sin usar (candidatos a eliminar)
- [ ] Índices duplicados o redundantes
- [ ] Missing indexes sugeridos por el optimizador

### Cómo obtenerla

```sql
-- Fragmentación de índices (ejecutar en cada BD)
SELECT
    OBJECT_NAME(ips.object_id)          AS table_name,
    i.name                              AS index_name,
    ips.index_type_desc,
    ips.avg_fragmentation_in_percent,
    ips.page_count
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') ips
JOIN sys.indexes i
    ON ips.object_id = i.object_id
    AND ips.index_id = i.index_id
WHERE ips.page_count > 100              -- Índices con volumen suficiente
ORDER BY ips.avg_fragmentation_in_percent DESC;

-- Índices no utilizados desde el último arranque
SELECT
    OBJECT_NAME(i.object_id)            AS table_name,
    i.name                              AS index_name,
    i.type_desc,
    ius.user_seeks,
    ius.user_scans,
    ius.user_lookups,
    ius.user_updates
FROM sys.indexes i
LEFT JOIN sys.dm_db_index_usage_stats ius
    ON i.object_id = ius.object_id
    AND i.index_id = ius.index_id
    AND ius.database_id = DB_ID()
WHERE i.type > 0                        -- Excluye heaps
  AND ISNULL(ius.user_seeks, 0)
    + ISNULL(ius.user_scans, 0)
    + ISNULL(ius.user_lookups, 0) = 0
ORDER BY ISNULL(ius.user_updates, 0) DESC;

-- Missing indexes sugeridos
SELECT TOP 20
    DB_NAME(mid.database_id)            AS database_name,
    OBJECT_NAME(mid.object_id, mid.database_id) AS table_name,
    migs.avg_user_impact,
    migs.user_seeks,
    migs.user_scans,
    mid.equality_columns,
    mid.inequality_columns,
    mid.included_columns
FROM sys.dm_db_missing_index_details mid
JOIN sys.dm_db_missing_index_groups mig
    ON mid.index_handle = mig.index_handle
JOIN sys.dm_db_missing_index_group_stats migs
    ON mig.index_group_handle = migs.group_handle
ORDER BY migs.avg_user_impact * (migs.user_seeks + migs.user_scans) DESC;
```

---

## 6 · Seguridad

**Por qué importa:** Documentar el estado de seguridad en un momento conocido permite detectar cambios inesperados en permisos, logins o usuarios.

### ✅ Checklist

- [ ] Logins de la instancia y sus roles de servidor
- [ ] Usuarios por base de datos y sus roles
- [ ] Logins con `sysadmin` (minimizar al máximo)
- [ ] Columnas con DDM aplicado
- [ ] Logins con autenticación SQL habilitada (política de contraseñas)
- [ ] Permisos explícitos sobre objetos

### Cómo obtenerla

```sql
-- Logins con rol sysadmin
SELECT sp.name AS login, sp.type_desc, sp.is_disabled
FROM sys.server_principals sp
JOIN sys.server_role_members srm ON sp.principal_id = srm.member_principal_id
JOIN sys.server_principals r ON srm.role_principal_id = r.principal_id
WHERE r.name = 'sysadmin'
ORDER BY sp.name;

-- Columnas con DDM
SELECT
    DB_NAME()                           AS database_name,
    SCHEMA_NAME(t.schema_id)            AS schema_name,
    t.name                              AS table_name,
    c.name                              AS column_name,
    c.masking_function
FROM sys.masked_columns c
JOIN sys.tables t ON c.object_id = t.object_id;
```

---

## 7 · Jobs y mantenimiento

**Por qué importa:** Los jobs de mantenimiento (backups, índices, estadísticas, DBCC) son críticos para la salud del servidor. Documentar su estado y resultados habituales permite detectar fallos silenciosos.

### ✅ Checklist

- [ ] Lista de SQL Agent jobs, frecuencia y última ejecución
- [ ] Jobs fallidos en los últimos 7 días
- [ ] Política de backups: frecuencia, tipo (FULL / DIFF / LOG) y destino
- [ ] Última ejecución exitosa de DBCC CHECKDB por base de datos
- [ ] Planes de mantenimiento de índices y estadísticas

### Cómo obtenerla

```sql
-- Estado y última ejecución de todos los jobs
SELECT
    j.name                              AS job_name,
    j.enabled,
    CASE jh.run_status
        WHEN 0 THEN 'Failed'
        WHEN 1 THEN 'Succeeded'
        WHEN 2 THEN 'Retry'
        WHEN 3 THEN 'Cancelled'
    END                                 AS last_run_status,
    msdb.dbo.agent_datetime(jh.run_date, jh.run_time) AS last_run_datetime
FROM msdb.dbo.sysjobs j
LEFT JOIN msdb.dbo.sysjobhistory jh
    ON j.job_id = jh.job_id
    AND jh.step_id = 0
ORDER BY j.name;

-- Último DBCC CHECKDB por base de datos
SELECT
    name                                AS database_name,
    DATABASEPROPERTYEX(name, 'LastGoodCheckDbTime') AS last_checkdb
FROM sys.databases
WHERE database_id > 4
ORDER BY name;

-- Últimos backups por base de datos y tipo
SELECT
    database_name,
    type,
    MAX(backup_finish_date)             AS last_backup
FROM msdb.dbo.backupset
GROUP BY database_name, type
ORDER BY database_name, type;
```

---

## 8 · Alta disponibilidad

**Por qué importa:** Si el servidor forma parte de un grupo de disponibilidad, espejado o replicación, el estado de sincronización es parte fundamental de la baseline.

### ✅ Checklist

- [ ] Rol actual (Primary / Secondary)
- [ ] Estado de sincronización de cada base de datos
- [ ] Latencia de replicación o redo queue
- [ ] Modo de disponibilidad (Synchronous / Asynchronous)

### Cómo obtenerla

```sql
-- Estado de Always On Availability Groups
SELECT
    ag.name                             AS ag_name,
    ags.primary_replica,
    ags.synchronization_health_desc,
    ar.replica_server_name,
    drs.database_id,
    DB_NAME(drs.database_id)            AS database_name,
    drs.synchronization_state_desc,
    drs.synchronization_health_desc,
    drs.redo_queue_size,
    drs.log_send_queue_size
FROM sys.availability_groups ag
JOIN sys.dm_hadr_availability_group_states ags
    ON ag.group_id = ags.group_id
JOIN sys.availability_replicas ar
    ON ag.group_id = ar.group_id
JOIN sys.dm_hadr_database_replica_states drs
    ON ar.replica_id = drs.replica_id
ORDER BY ag.name, ar.replica_server_name;
```

---

## 📅 ¿Con qué frecuencia capturar la baseline?

| Métrica | Frecuencia recomendada |
|---|---|
| Configuración de instancia y BDs | Al instalar, y tras cada cambio relevante |
| Hardware y SO | Mensual |
| Rendimiento (waits, PLE, batch requests) | Diaria durante al menos 2 semanas para establecer el patrón |
| Fragmentación de índices | Semanal |
| Jobs y backups | Diaria (automatizado vía alertas) |
| Seguridad | Mensual o tras cualquier cambio de permisos |

---

## 💾 Cómo conservar la baseline

Las opciones más habituales son guardar los resultados en tablas de una base de datos de administración (patrón DBA database), exportarlos a ficheros con un job programado, o usar herramientas como **sp_WhoIsActive**, **Brent Ozar's First Responder Kit** o **SQL Server Management Data Warehouse** que automatizan gran parte de esta captura.

> 📌 Lo más importante no es la herramienta sino la **consistencia**: capturar siempre en los mismos momentos del día y bajo condiciones de carga comparables.
