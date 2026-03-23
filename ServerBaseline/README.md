# 📏 Baseline Operativa de SQL Server y Azure SQL

Una **baseline operativa** es un registro sistemático de las **métricas variables** de rendimiento, salud y operación de tu plataforma de datos en condiciones normales de carga. Su propósito es proporcionar un punto de referencia objetivo contra el que comparar cuando alguien reporta que "algo va lento" o cuando se producen degradaciones.

> **Diferencia clave:** La configuración de instalación (collation, `tempdb`, parámetros fijos) se documenta una sola vez. La baseline operativa se **captura periódicamente** porque las métricas de rendimiento **cambian constantemente**.

---

## 🎯 Alcance: SQL Server On-Premise vs. Azure SQL

| Plataforma | DMVs disponibles | Herramientas principales |
|:---|:---|:---|
| **SQL Server (IaaS/On-prem)** | Todas las DMVs | DMVs, Extended Events, Query Store, PerfMon |
| **Azure SQL Managed Instance** | Mayoría de DMVs, sin OS-level | DMVs, Query Store, Azure Monitor |
| **Azure SQL Database (PaaS)** | Subset limitado (`sys.dm_db_*`) | Query Store, Azure Monitor, Intelligent Insights |

> 📝 Algunas DMVs son específicas de Azure SQL y no existen on-prem (ej: `sys.dm_db_resource_stats`), por el contrario también hay DMVs (`sys.dm_os_process_memory`) que no están disponibles en PaaS. Las queries de este documento indican alternativas donde aplique.

---

## 📅 Frecuencia de Captura

| Métrica | Frecuencia | Contexto |
|:---|:---|:---|
| Métricas de rendimiento (CPU, waits, throughput) | Cada 5-15 minutos durante horario laborable | Establecer patrón diario/semanal |
| Page Life Expectancy (PLE) | Cada hora | Tendencia de presión de memoria |
| Latencias de I/O | Diaria (promedio) y horas pico (máximo) | Detectar degradación de storage |
| Fragmentación de índices | Semanal | Planificar reorganizaciones |
| Jobs y backups | Tras cada ejecución | Alertas inmediatas de fallo |
| Alta disponibilidad / sincronización | Cada 5 minutos (si aplica) | Detectar lag antes de failover |

> 📝 **PLE en contexto:** Page Life Expectancy no debe interpretarse de forma aislada. Un valor bajo puede ser normal durante operaciones de mantenimiento (rebuilds, cargas masivas) o en servidores con múltiples instancias compartiendo memoria. Siempre correlacionar con: presión de memoria (`Available MBytes`), tasa de page faults, y comportamiento de las queries (aumento repentino de lecturas físicas). Un PLE "bajo" con queries rápidas y sin esperas de I/O no tiene por qué ser un problema.

> 💡 **Frecuencias adaptativas:** Las recomendaciones de captura son puntos de partida. Ajustar según los **RPO** (Recovery Point Objective: datos máximos tolerables a perder) y **RTO** (Recovery Time Objective: tiempo máximo tolerable de parada) contractuales de cada sistema. Un entorno con RPO de 1 minuto requerirá monitorización más frecuente que uno con RPO de 24 horas.
---

## 🗂️ Índice

1. [Rendimiento del Servidor](#1--rendimiento-del-servidor)
   - [1.1 CPU y Throughput](#11-cpu-y-throughput)
   - [1.2 Memoria: Page Life Expectancy (PLE)](#12-memoria-page-life-expectancy-ple)
   - [1.3 Wait Statistics](#13-wait-statistics)
2. [Salud de Almacenamiento](#2--salud-de-almacenamiento)
   - [2.1 Latencias de I/O por Fichero](#21-latencias-de-io-por-fichero)
   - [2.2 Crecimiento de Ficheros y Espacio](#22-crecimiento-de-ficheros-y-espacio)
3. [Mantenimiento y Salud de Objetos](#3--mantenimiento-y-salud-de-objetos)
   - [3.1 Fragmentación de Índices](#31-fragmentación-de-índices)
   - [3.2 Estadísticas Desactualizadas](#32-estadísticas-desactualizadas)
   - [3.3 Índices: Uso y Sugerencias](#33-índices-uso-y-sugerencias)
4. [Operaciones Programadas](#4--operaciones-programadas)
   - [4.1 Estado de SQL Agent Jobs](#41-estado-de-sql-agent-jobs)
   - [4.2 Cadenas de Backup Completas](#42-cadenas-de-backup-completas)
   - [4.3 Integridad de Datos (CHECKDB)](#43-integridad-de-datos-checkdb)
5. [Alta Disponibilidad y Sincronización](#5--alta-disponibilidad-y-sincronización)
   - [5.1 Always On Availability Groups](#51-always-on-availability-groups-on-prem-mi)
   - [5.2 Azure SQL: Failover Groups y Geo-replicación](#52-azure-sql-failover-groups-y-geo-replicación)
6. [Herramientas y Automatización](#6--herramientas-y-automatización)
   - [6.1 sp_WhoIsActive](#61-sp_whoisactive-adam-machanic)
   - [6.2 First Responder Kit](#62-first-responder-kit-brent-ozar-unlimited)
   - [6.3 Azure Monitor y Log Analytics](#63-azure-monitor-y-log-analytics-azure-sql)
7. [Plantilla de Registro de Baseline](#7--plantilla-de-registro-de-baseline)
8. [Referencias](#8--referencias)

---

## 1 · Rendimiento del Servidor

**Por qué importa:** Estas métricas responden la pregunta "¿El servidor está ocupado o libre?" y "¿Dónde está el cuello de botella?".

### 1.1 Throughput de Instancia (On-Premises/MI)

Mide cuántas operaciones por segundo ejecuta la instancia. Indicador de carga de trabajo.

> ⚠️ **Nota técnica:** Requiere captura de dos muestras temporales para cálculo correcto de rates. Ver documentación Microsoft sobre `PERF_COUNTER_BULK_COUNT`.

```sql
DECLARE @sample1 TABLE 
    (
        counter_name NVARCHAR(128),
        cntr_value BIGINT,
        sample_time DATETIME2 DEFAULT SYSUTCDATETIME()
    );

DECLARE @sample2 TABLE 
    (
        counter_name NVARCHAR(128),
        cntr_value BIGINT,
        sample_time DATETIME2 DEFAULT SYSUTCDATETIME()
    );

-- Primera muestra
INSERT INTO @sample1 (counter_name, cntr_value)
    SELECT 
        pc.counter_name,
        pc.cntr_value
    FROM 
        sys.dm_os_performance_counters pc
    WHERE 
        pc.object_name LIKE '%SQL Statistics%'
        AND pc.counter_name IN 
            (
                'Batch Requests/sec',
                'SQL Compilations/sec',
                'SQL Re-Compilations/sec'
            )
        AND pc.cntr_type = 272696576;  -- PERF_COUNTER_BULK_COUNT

-- Esperar 10 segundos (ajustar según necesidad de precisión)
WAITFOR DELAY '00:00:10';

-- Segunda muestra
INSERT INTO @sample2 (counter_name, cntr_value)
    SELECT 
        pc.counter_name,
        pc.cntr_value
    FROM 
        sys.dm_os_performance_counters pc
    WHERE 
        pc.object_name LIKE '%SQL Statistics%'
        AND pc.counter_name IN 
            (
                'Batch Requests/sec',
                'SQL Compilations/sec',
                'SQL Re-Compilations/sec'
            )
        AND pc.cntr_type = 272696576;

-- Calcular rate real
SELECT 
    s1.counter_name,
    s1.cntr_value AS value_start,
    s2.cntr_value AS value_end,
    DATEDIFF(MILLISECOND, s1.sample_time, s2.sample_time) / 1000.0 AS seconds_elapsed,
    CAST((s2.cntr_value - s1.cntr_value) / 
         NULLIF(DATEDIFF(MILLISECOND, s1.sample_time, s2.sample_time) / 1000.0, 0) 
         AS DECIMAL(10,2)) AS rate_per_second
FROM 
    @sample1 s1
        INNER JOIN 
    @sample2 s2 ON s1.counter_name = s2.counter_name;
```
> ⚠️ **Cálculo de rates en `sys.dm_os_performance_counters`:** Los contadores 
> de tipo `PERF_COUNTER_BULK_COUNT` (272696576) son acumuladores desde el 
> inicio de la instancia. Para obtener "por segundo" se requieren **dos 
> muestras con intervalo de tiempo conocido** y calcular la diferencia. 
> 
> Alternativa: Usar Performance Monitor (PerfMon) o Extended Events para 
> captura continua de rates.
>
> 📚 **Referencia técnica:** 
> - [ System dynamic management views | SQL Server Operating System | dm_os_performance_counters](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-os-performance-counters-transact-sql)
> - [About Performance Counters | Microsoft Learn](https://learn.microsoft.com/en-us/windows/win32/perfctrs/about-performance-counters)

#### Baseline a capturar:
- Batch requests/sec en horas pico vs. valle (establecer patrón diario)
- Ratio recompilaciones/compilaciones (objetivo: <10%)
- Tendencia semanal: ¿aumenta el throughput con el mismo volumen de datos? (posible degradación de planes)
### 1.2 Utilización de Recursos (Azure SQL Database)

Mide qué porcentaje de los recursos asignados consume la base de datos. Indicador de saturación.

> 💡 **Limitación:** Retención de 1 hora. Para histórico mayor, usar Azure Monitor.

```sql
-- Azure SQL Database (PaaS)
SELECT 
    AVG(avg_cpu_percent) AS avg_cpu_percent,
    MAX(avg_cpu_percent) AS max_cpu_percent,
    AVG(avg_data_io_percent) AS avg_data_io_percent,
    MAX(avg_data_io_percent) AS max_data_io_percent,
    AVG(avg_log_write_percent) AS avg_log_write_percent,
    MAX(avg_log_write_percent) AS max_log_write_percent,
    AVG(avg_memory_usage_percent) AS avg_memory_percent,
    MAX(avg_memory_usage_percent) AS max_memory_percent,
    AVG(xtp_storage_percent) AS avg_xtp_storage_percent  -- In-Memory OLTP si aplica
FROM 
    sys.dm_db_resource_stats
WHERE 
    end_time > DATEADD(HOUR, -1, GETDATE());
```
> 📚 **Referencia técnica:** 
> - [ System dynamic management views | Database | dm_db_resource_stats](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-db-resource-stats-azure-sql-database)

#### Nota:
> **Diferencia de modelos:** On-Premises y Managed Instance permiten medir 
> **throughput** (trabajo realizado). Azure SQL Database expone 
> **utilización de recursos asignados** (porcentaje de capacidad consumida). 
> Son métricas complementarias, no sustitutas.

#### Baseline a capturar:
- CPU % promedio y máximo por ventana horaria (identificar picos predecibles)
- I/O % correlacionado con operaciones de mantenimiento (rebuilds, backups)
- Memory % estable vs. creciente (indicador de memory pressure en PaaS)

### 1.3 Memoria: Page Life Expectancy (PLE)

> ⚠️ **Corrección de umbral desactualizado:** La regla antigua de `PLE > 300` es obsoleta para los servidores actuales. La fórmula `(Buffer Pool GB / 4) * 300` es la referencia estándar de la comunidad. Esta query se refina adicionalmente calculando el umbral por nodo NUMA con las páginas reales cargadas en cada uno, ya que unos nodos pueden estar bajo presión mientras otros disponen de más holgura.
```sql
-- PLE por NUMA node (si aplica) o instancia
SELECT 
    CAST(bp.instance_name AS INT) AS [NUMA Node],
    bp.cntr_value AS [Buffer Pool (Pages)],
    CAST(bp.cntr_value * 8.0 / 1024 / 1024 AS DECIMAL(10,2)) AS [Buffer Pool (GB)],
    CAST(bp.cntr_value * 8.0 / 1024 / 1024 / 4 * 300 AS DECIMAL(10,0)) AS [Suggested Threshold],
    pc.cntr_value AS [Current PLE]
FROM 
    sys.dm_os_performance_counters bp
        INNER JOIN
    sys.dm_os_performance_counters pc ON pc.object_name = bp.object_name
                                      AND pc.instance_name = bp.instance_name
WHERE 
    bp.object_name   LIKE '%Buffer Node%'
    AND bp.counter_name  = 'Database pages'
    AND pc.counter_name  = 'Page Life Expectancy'
ORDER BY
	bp.instance_name;
```
#### Resultado de ejemplo


| NUMA Node | Buffer Pool (Pages) | Buffer Pool (GB) | Suggested Threshold | Current PLE |
| --- | --- | --- | --- | --- |
| 0 | 577.880 | 4,43 | 3.632 | 5.436 |
| 1 | 547.127 | 4,98 | 3.899 | 6.215 |

> **Notas:** 
> - La documentación oficial de Microsoft no establece umbrales específicos para el PLE. La fórmula aquí utilizada es una heurística de la comunidad, no un estándar oficial.
> - Esta query recoge el PLE por `Buffer Node`, es decir, por nodo NUMA. Si se consulta sin filtrar por nodo — usando `Buffer Manager` en lugar de `Buffer Node` — se obtiene un único valor para toda la instancia que corresponde con la media armónica.
>
> **Mejor práctica:** Establece tu propio baseline de PLE cuando el sistema rinde correctamente y configura alertas si cae más de un porcentaje determinado para ese valor de referencia.

---

### 1.4 Wait Statistics: Qué espera el servidor
> 📝 Los waits son sintomáticos, no causales. Un wait alto indica dónde está el tiempo, no necesariamente el problema raíz.

```sql
-- Top waits acumulados desde el último reinicio
-- Excluir waits benignos de sistema
SELECT TOP 20
    ws.wait_type,
    ws.waiting_tasks_count,
    ws.wait_time_ms,
    ws.wait_time_ms / NULLIF(ws.waiting_tasks_count, 0) AS avg_wait_ms,
    ws.signal_wait_time_ms,
    ws.wait_time_ms - ws.signal_wait_time_ms AS resource_wait_ms,
    -- Clasificación útil para análisis
    CASE 
        WHEN ws.wait_type LIKE 'PAGEIOLATCH%' THEN 'Storage I/O'
        WHEN ws.wait_type LIKE 'PAGELATCH%' THEN 'Buffer/memory'
        WHEN ws.wait_type LIKE 'LCK%' THEN 'Locking'
        WHEN ws.wait_type LIKE 'SOS_SCHEDULER%' THEN 'CPU/Scheduler'
        WHEN ws.wait_type LIKE 'CXPACKET%' OR ws.wait_type LIKE 'CXCONSUMER%' THEN 'Parallelism'
        WHEN ws.wait_type LIKE 'ASYNC_NETWORK_IO%' THEN 'Network/Client'
        WHEN ws.wait_type LIKE 'WRITELOG%' THEN 'Transaction Log I/O'
        ELSE 'Other'
    END AS wait_category
FROM 
    sys.dm_os_wait_stats ws
WHERE 
    ws.wait_type NOT IN 
        (
            'BROKER_EVENTHANDLER', 'BROKER_RECEIVE_WAITFOR', 'BROKER_TASK_STOP', 
            'BROKER_TO_FLUSH', 'BROKER_TRANSMITTER', 'CHECKPOINT_QUEUE',             
            'CHKPT', 'CLR_AUTO_EVENT', 'CLR_MANUAL_EVENT', 'CLR_SEMAPHORE', 'CXCONSUMER', 
            'DBMIRROR_DBM_EVENT', 'DBMIRROR_EVENTS_QUEUE', 'DBMIRROR_WORKER_QUEUE',         
            'DBMIRRORING_CMD', 'DIRTY_PAGE_POLL', 'DISPATCHER_QUEUE_SEMAPHORE', 'EXECSYNC', 
            'FSAGENT', 'FT_IFTS_SCHEDULER_IDLE_WAIT', 'FT_IFTSHC_MUTEX', 'HADR_CLUSAPI_CALL', 
            'HADR_FILESTREAM_IOMGR_IOCOMPLETION', 'HADR_LOGCAPTURE_WAIT', 
            'HADR_NOTIFICATION_DEQUEUE', 'HADR_TIMER_TASK', 'HADR_WORK_QUEUE', 'KSOURCE_WAKEUP', 
            'LAZYWRITER_SLEEP', 'LOGMGR_QUEUE', 'MEMORY_ALLOCATION_EXT', 'ONDEMAND_TASK_QUEUE', 
            'PARALLEL_REDO_DRAIN_WORKER', 'PARALLEL_REDO_LOG_CACHE', 'PARALLEL_REDO_TRAN_LIST', 
            'PARALLEL_REDO_WORKER_SYNC', 'PARALLEL_REDO_WORKER_WAIT_WORK', 
            'PREEMPTIVE_OS_FLUSHFILEBUFFERS', 'PREEMPTIVE_XE_GETTARGETSTATE', 
            'PVS_PREALLOCATE', 'PWAIT_ALL_COMPONENTS_INITIALIZED', 
            'PWAIT_DIRECTLOGCONSUMER_GETNEXT', 'PWAIT_EXTENSIBILITY_CLEANUP_TASK', 
            'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP', 'QDS_ASYNC_QUEUE', 
            'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP','QDS_SHUTDOWN_QUEUE', 
            'REDO_THREAD_PENDING_WORK', 'REQUEST_FOR_DEADLOCK_SEARCH', 'RESOURCE_QUEUE', 
            'SERVER_IDLE_CHECK', 'SLEEP_BPOOL_FLUSH', 'SLEEP_DBSTARTUP', 'SLEEP_DCOMSTARTUP', 
            'SLEEP_MASTERDBREADY', 'SLEEP_MASTERMDREADY', 'SLEEP_MASTERUPGRADED', 
            'SLEEP_MSDBSTARTUP', 'SLEEP_SYSTEMTASK', 'SLEEP_TASK', 'SLEEP_TEMPDBSTARTUP', 
            'SNI_HTTP_ACCEPT', 'SOS_WORK_DISPATCHER', 'SP_SERVER_DIAGNOSTICS_SLEEP', 
            'SQLTRACE_BUFFER_FLUSH', 'SQLTRACE_INCREMENTAL_FLUSH_SLEEP', 'SQLTRACE_WAIT_ENTRIES', 
            'VDI_CLIENT_OTHER', 'WAIT_FOR_RESULTS', 'WAITFOR', 'WAITFOR_TASKSHUTDOWN', 
            'WAIT_XTP_RECOVERY', 'WAIT_XTP_HOST_WAIT', 'WAIT_XTP_OFFLINE_CKPT_NEW_LOG', 
            'WAIT_XTP_CKPT_CLOSE', 'XE_DISPATCHER_JOIN', 'XE_DISPATCHER_WAIT', 'XE_TIMER_EVENT'
        )
    AND ws.wait_time_ms > 1000  -- Ignorar ruido menor a 1 segundo acumulado
ORDER BY 
    ws.wait_time_ms DESC;
```

> 💡 Una de las mejores referencia de los tipos de esperas podrás encontrarla en [SQLSkills](https://www.sqlskills.com/help/waits)

#### Baseline a capturar:
- Top 5 waits por tiempo acumulado en condiciones normales
- Evolución semanal: ¿aparecen nuevos waits en el top? ¿suben de posición?

## 2 · Salud de Almacenamiento
**Por qué importa:** El almacenamiento es el cuello de botella más común. Las latencias de I/O degradan todas las operaciones, no solo las consultas "lentas".
### 2.1 Latencias de I/O por Fichero
Umbrales de referencia (no dogmas):
| ms | Valoración| Medio |
| ---: | --- | --- |
| < 2 ms | Excelente | NVMe/SSD premium |
| 2–5 ms | Muy bueno | SSD Estándard |
| 6–15 ms | Bueno | HDDs RAID |
| 16–100 ms | Pobre |  |
| > 100 ms | Crítico |  |

```sql
-- Latencias acumuladas desde el último arranque de SQL Server
-- Capturar periódicamente y comparar deltas
SELECT 
    DB_NAME(vfs.database_id) AS database_name,
    f.name AS logical_name,
    f.physical_name,
    up.operation_type,
    up.io_stall_ms,
    up.num_of_operations,
    CASE WHEN up.num_of_operations = 0 THEN 0
         ELSE CAST(up.io_stall_ms AS FLOAT) / up.num_of_operations 
    END AS avg_latency_ms,
    up.avg_size_kb
FROM 
    sys.dm_io_virtual_file_stats(NULL, NULL) vfs
    INNER JOIN sys.master_files f 
        ON vfs.database_id = f.database_id
        AND vfs.file_id = f.file_id
    CROSS APPLY 
        (
            VALUES 
                (
                    'READ', 
                    vfs.io_stall_read_ms, 
                    vfs.num_of_reads, 
                    CAST(vfs.num_of_bytes_read AS FLOAT) / NULLIF(vfs.num_of_reads, 0) / 1024
                 ),
                 (
                    'WRITE', 
                    vfs.io_stall_write_ms, 
                    vfs.num_of_writes,
                    CAST(vfs.num_of_bytes_written AS FLOAT) / NULLIF(vfs.num_of_writes, 0) / 1024
                 )
        ) AS up(operation_type, io_stall_ms, num_of_operations, avg_size_kb)
WHERE 
    up.num_of_operations > 0  -- Excluir operaciones sin actividad
ORDER BY 
    operation_type,
    avg_latency_ms DESC

-- Azure SQL Database: sustituir el INNER JOIN contra sys.master_files por el siguiente:
--     INNER JOIN sys.database_files f ON vfs.file_id = f.file_id
```
### 2.2 Crecimiento de Ficheros y Espacio
```sql
-- Tendencia de crecimiento (comparar con capturas anteriores)
SELECT 
    DB_NAME(f.database_id) AS database_name, -- En Azure: DB_NAME()
    f.name AS logical_name,
    f.physical_name,
    f.type_desc,
    CAST(f.size * 8.0 / 1024 AS DECIMAL(10,2)) AS current_size_mb,
    CAST(f.max_size * 8.0 / 1024 AS DECIMAL(10,2)) AS max_size_mb,
    CASE f.is_percent_growth
        WHEN 1 THEN CAST(f.growth AS VARCHAR) + ' %'
        ELSE CAST(CAST(f.growth * 8.0 / 1024 AS DECIMAL(10,2)) AS VARCHAR) + ' MB'
    END AS autogrowth_setting,
    -- Cálculo de espacio libre interno (solo para ficheros de datos)
    CAST(ISNULL(FILEPROPERTY(f.name, 'SpaceUsed') * 8.0 / 1024, 0) 
        AS DECIMAL(10,2)) AS space_used_mb,
    CAST(ISNULL((f.size - FILEPROPERTY(f.name, 'SpaceUsed')) * 8.0 / 1024, 0) 
        AS DECIMAL(10,2)) AS free_space_mb,
    CAST(ISNULL((FILEPROPERTY(f.name, 'SpaceUsed') * 100.0 / f.size), 0) 
        AS DECIMAL(5,2)) AS percent_used
FROM 
    sys.master_files f          -- En Azure: sys.database_files
WHERE 
    f.database_id > 4           -- En Azure: DB_ID() > 4
ORDER BY 
    f.database_id, f.type_desc; -- En Azure: Omitir f.database_id

-- Azure SQL Database: 💡 Sustituir los valores indicados a lo largo de los
-- comentarios de la SELECT.
```
#### Baseline a capturar:
- Latencias promedio por fichero de datos críticos
- Tasa de crecimiento semanal de las principales bases de datos
- Número de autogrowths por día (ideal: 0, todos los crecimientos deben ser manuales planificados)

## 3 · Mantenimiento y Salud de Objetos

**Por qué importa:** Índices fragmentados y estadísticas desactualizadas generan planes de ejecución subóptimos, consumiendo más recursos de los necesarios.

### 3.1 Fragmentación de Índices

> 📝 **Fragmentación externa** (páginas desordenadas físicamente) impacta 
> operaciones que requieren lectura secuencial de rangos de datos. 
> **Fragmentación interna** (páginas semivacías) aumenta el número de páginas 
> necesarias para almacenar los mismos datos, afectando el rendimiento de 
> acceso general. Ver [Reorganize and Rebuild Indexes](https://learn.microsoft.com/en-us/sql/relational-databases/indexes/reorganize-and-rebuild-indexes).

```sql
-- Fragmentación de índices con volumen significativo
-- Ejecutar en cada base de datos de interés
SELECT 
    DB_NAME() AS database_name,
    SCHEMA_NAME(t.schema_id) AS schema_name,
    t.name AS table_name,
    i.name AS index_name,
    i.type_desc AS index_type,
    ips.index_type_desc AS alloc_unit_type,
    ips.avg_fragmentation_in_percent,
    ips.page_count,
    ips.record_count,
    -- Recomendación de acción basada en fragmentación
    CASE 
        WHEN ips.avg_fragmentation_in_percent < 5 THEN 'OK'
        WHEN ips.avg_fragmentation_in_percent < 30 THEN 'REORGANIZE'
        ELSE 'REBUILD'
    END AS suggested_action,
    -- Solo relevante para reorganizar/rebuild si tiene volumen
    CASE WHEN ips.page_count > 1000 THEN 'Significant volume'
         ELSE 'Low volume - consider if worth action'
    END AS volume_assessment
FROM 
    sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') ips
        INNER JOIN 
    sys.tables t ON ips.object_id = t.object_id
        INNER JOIN 
    sys.indexes i ON ips.object_id = i.object_id AND ips.index_id = i.index_id
WHERE 
    ips.page_count > 1000                       -- Ignorar índices pequeños (< 8 MB aprox)
    AND ips.avg_fragmentation_in_percent > 10   -- Solo problemáticos
    AND i.type > 0                              -- Excluir heaps (type = 0)
ORDER BY 
    ips.avg_fragmentation_in_percent DESC;
```

## 3.2 Estadísticas Desactualizadas

```sql
-- Estadísticas con más de 7 días sin actualizar
-- o con modificaciones significativas desde última actualización
SELECT 
    DB_NAME() AS database_name,
    SCHEMA_NAME(t.schema_id) AS schema_name,
    t.name AS table_name,
    s.name AS stats_name,
    s.auto_created,
    s.user_created,
    sp.last_updated,
    sp.rows,
    sp.rows_sampled,
    sp.modification_counter,
    -- Porcentaje de cambios desde última actualización
    CASE WHEN sp.rows > 0 
         THEN CAST(sp.modification_counter * 100.0 / sp.rows AS DECIMAL(5,2))
         ELSE 0 
    END AS percent_modified,
    -- Actualizar si > 10% de cambios o > 7 días
    CASE 
        WHEN sp.modification_counter > sp.rows * 0.1 THEN 'UPDATE (10% changes)'
        WHEN sp.last_updated < DATEADD(DAY, -7, GETDATE()) THEN 'UPDATE (stale)'
        ELSE 'OK'
    END AS status
FROM 
    sys.stats s
        INNER JOIN 
    sys.tables t ON s.object_id = t.object_id
        CROSS APPLY 
    sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
WHERE 
    s.auto_created = 0      -- Ignorar estadísticas auto (se actualizan automáticamente)
    OR s.user_created = 1   -- Incluir creadas por usuarios
ORDER BY 
    percent_modified DESC;
```
## 3.3 Índices: Uso y Sugerencias (con Advertencias)

>⚠️ Missing indexes: Son sugerencias del optimizador, no mandatos. Antes de crear:
>- ¿La query se ejecuta frecuentemente? (impacto)
>- ¿El costo de mantenimiento del índice supera el beneficio? (tablas muy volátiles)
>- ¿Ya existe un índice similar que podría ajustarse?

```sql
-- Missing indexes: impacto estimado ordenado
SELECT TOP 20
    DB_NAME(mid.database_id) AS database_name,
    OBJECT_NAME(mid.object_id, mid.database_id) AS table_name,
    -- Impacto estimado (user benefit)
    migs.avg_user_impact,
    migs.user_seeks + migs.user_scans AS estimated_uses,
    -- Columnas sugeridas
    mid.equality_columns,
    mid.inequality_columns,
    mid.included_columns,
    -- Cálculo de "peso" de la sugerencia
    migs.avg_user_impact * (migs.user_seeks + migs.user_scans) / 100.0 AS weight_score,
    -- Script de creación tentativo (revisar siempre antes de ejecutar)
    'CREATE INDEX [IX_' + LEFT(OBJECT_NAME(mid.object_id, mid.database_id) + '__' 
        + REPLACE(REPLACE(REPLACE(ISNULL(mid.equality_columns, '') 
                                + ISNULL(mid.inequality_columns, ''), '[', ''), ']', ''), ', ', '__'), 125) + '] ON ' 
       + mid.statement + ' (' + ISNULL(mid.equality_columns, '') 
       + CASE 
            WHEN mid.equality_columns IS NOT NULL AND mid.inequality_columns IS NOT NULL THEN ', ' 
            ELSE '' END 
       + ISNULL(mid.inequality_columns, '') + ')' 
       + CASE 
            WHEN mid.included_columns IS NOT NULL THEN ' INCLUDE (' + mid.included_columns + ')' 
            ELSE '' END 
       + ';' AS tentative_ddl,
    st.text,
    qp.query_plan
FROM 
    sys.dm_db_missing_index_details mid
        INNER JOIN 
    sys.dm_db_missing_index_groups mig ON mid.index_handle = mig.index_handle
        INNER JOIN 
    sys.dm_db_missing_index_group_stats migs ON mig.index_group_handle = migs.group_handle
        INNER JOIN
    -- Requiere SQL Server 2019+
    sys.dm_db_missing_index_group_stats_query migsq ON mig.index_group_handle = migsq.group_handle
        OUTER APPLY 
            (
                SELECT TOP 1 plan_handle 
                FROM sys.dm_exec_query_stats qs 
                WHERE qs.query_plan_hash = migsq.query_plan_hash AND qs.plan_handle IS NOT NULL
                ORDER BY qs.execution_count DESC
            ) qs
        OUTER APPLY 
    sys.dm_exec_sql_text(migsq.last_sql_handle) st
        OUTER APPLY
    sys.dm_exec_query_plan(qs.plan_handle) qp
ORDER BY 
    weight_score DESC;

-- Índices no utilizados (candidatos a eliminar, con cautela)
-- IMPORTANTE: Los contadores se reinician al arrancar SQL Server. 
-- No eliminar índices basándose solo en esta query sin histórico.
-- Evaluar primero cuándo se reinició SQL Server
--    SELECT sqlserver_start_time FROM sys.dm_os_sys_info;

WITH index_physical_stats AS
    (   -- Tamaño del índice para contexto
        SELECT 
            object_id, 
            index_id, 
            page_count, 
            avg_fragmentation_in_percent
        FROM 
            sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED')
        WHERE
            page_count > 0
    )
SELECT 
    DB_NAME() AS database_name,
    SCHEMA_NAME(t.schema_id) AS schema_name,
    t.name AS table_name,
    i.name AS index_name,
    i.type_desc,
    -- Información adicional útil
    ps.page_count,
    CAST(ps.avg_fragmentation_in_percent AS DECIMAL(5,2)) AS fragmentation_pct
FROM 
    sys.tables t 
        INNER JOIN 
    sys.indexes i ON i.object_id = t.object_id
        LEFT JOIN 
    index_physical_stats ps ON i.object_id = ps.object_id AND i.index_id = ps.index_id
        LEFT JOIN 
    sys.dm_db_index_usage_stats ius ON i.object_id = ius.object_id 
                                   AND i.index_id = ius.index_id
WHERE 
    i.type_desc <> 'HEAP'
    AND i.is_primary_key = 0
    AND i.is_unique = 0
    AND i.is_unique_constraint = 0
    AND ISNULL(ius.user_seeks, 0) + ISNULL(ius.user_scans, 0) + ISNULL(ius.user_lookups, 0) = 0
ORDER BY 
    -- Priorizar índices grandes que ocupan espacio
    ps.page_count DESC; 
```

## 4 · Operaciones Programadas

**Por qué importa:** Los jobs de mantenimiento son la salud preventiva de la instancia. Un job que falla silenciosamente es una bomba de tiempo.

### 4.1 Estado de SQL Agent Jobs
```sql
-- Última ejecución y estado de todos los jobs
SELECT 
    j.name AS job_name,
    j.enabled AS is_enabled,
    jh.run_status,
    CASE jh.run_status
        WHEN 0 THEN 'Failed'
        WHEN 1 THEN 'Succeeded'
        WHEN 2 THEN 'Retry'
        WHEN 3 THEN 'Cancelled'
        WHEN 4 THEN 'In Progress'
        ELSE 'Unknown'
    END AS run_status_desc,
    msdb.dbo.agent_datetime(jh.run_date, jh.run_time) AS last_run_datetime,
    -- Duración formateada
    CAST(jh.run_duration / 10000 AS VARCHAR) + ':' + 
    RIGHT('00' + CAST((jh.run_duration / 100) % 100 AS VARCHAR), 2) + ':' +
    RIGHT('00' + CAST(jh.run_duration % 100 AS VARCHAR), 2) AS run_duration_hhmmss,
    jh.message AS run_message
FROM msdb.dbo.sysjobs j
LEFT JOIN (
    -- Solo la última ejecución por job
    SELECT job_id, run_date, run_time, run_status, run_duration, message,
           ROW_NUMBER() OVER (PARTITION BY job_id ORDER BY run_date DESC, run_time DESC) AS rn
    FROM msdb.dbo.sysjobhistory
    WHERE step_id = 0  -- Solo el resultado general del job, no pasos individuales
) jh ON j.job_id = jh.job_id AND jh.rn = 1
ORDER BY j.name;

-- Jobs fallidos en las últimas 24 horas (alerta operativa)
SELECT 
    j.name AS job_name,
    msdb.dbo.agent_datetime(jh.run_date, jh.run_time) AS failed_datetime,
    jh.message AS error_message
FROM msdb.dbo.sysjobhistory jh
JOIN msdb.dbo.sysjobs j ON jh.job_id = j.job_id
WHERE jh.run_status = 0  -- Failed
  AND jh.step_id = 0
  AND msdb.dbo.agent_datetime(jh.run_date, jh.run_time) > DATEADD(HOUR, -24, GETDATE())
ORDER BY failed_datetime DESC;
```

### 4.2 Cadenas de Backup Completas

```sql
-- Últimos backups por base de datos y tipo
-- Verificar que exista FULL reciente y cadena de LOGs continua
SELECT 
    bs.database_name,
    CASE bs.type
        WHEN 'D' THEN 'Full'
        WHEN 'I' THEN 'Differential'
        WHEN 'L' THEN 'Log'
        WHEN 'F' THEN 'File/Filegroup'
        WHEN 'G' THEN 'Differential File'
        WHEN 'P' THEN 'Partial'
        WHEN 'Q' THEN 'Differential Partial'
    END AS backup_type,
    MAX(bs.backup_finish_date) AS last_backup_finish,
    DATEDIFF(HOUR, MAX(bs.backup_finish_date), GETDATE()) AS hours_since_backup,
    -- Validación de cadena
    CASE 
        WHEN bs.type = 'D' AND MAX(bs.backup_finish_date) > DATEADD(DAY, -7, GETDATE()) THEN 'OK'
        WHEN bs.type = 'I' AND MAX(bs.backup_finish_date) > DATEADD(HOUR, -25, GETDATE()) THEN 'OK'
        WHEN bs.type = 'L' AND MAX(bs.backup_finish_date) > DATEADD(HOUR, -4, GETDATE()) THEN 'OK'
        ELSE 'ALERT: Stale backup'
    END AS chain_status
FROM msdb.dbo.backupset bs
WHERE bs.is_copy_only = 0  -- Excluir backups ad-hoc
GROUP BY bs.database_name, bs.type
ORDER BY bs.database_name, 
         CASE bs.type WHEN 'D' THEN 1 WHEN 'I' THEN 2 WHEN 'L' THEN 3 ELSE 4 END;

-- Azure SQL Database: usar sys.dm_database_backups (limitado) o Azure Portal/Monitor
```

### 4.3 Integridad de Datos (CHECKDB)

```sql
-- Último CHECKDB exitoso por base de datos
-- Nota: DATABASEPROPERTYEX solo reporta si se ejecutó con CHECKDB, no con CHECKTABLE/CHECKALLOC
SELECT 
    name AS database_name,
    DATABASEPROPERTYEX(name, 'LastGoodCheckDbTime') AS last_good_checkdb,
    DATEDIFF(DAY, DATABASEPROPERTYEX(name, 'LastGoodCheckDbTime'), GETDATE()) AS days_since_checkdb,
    CASE 
        WHEN DATABASEPROPERTYEX(name, 'LastGoodCheckDbTime') IS NULL THEN 'NEVER CHECKED'
        WHEN DATABASEPROPERTYEX(name, 'LastGoodCheckDbTime') < DATEADD(DAY, -7, GETDATE()) THEN 'STALE'
        ELSE 'OK'
    END AS checkdb_status
FROM sys.databases
WHERE database_id > 4  -- Excluir sistema, o incluir si son críticas
  AND state_desc = 'ONLINE'
ORDER BY days_since_checkdb DESC;

-- Azure SQL Database: CHECKDB es gestionado por la plataforma. 
-- Usar DBCC CHECKDB manual solo en Managed Instance o IaaS.
```

## 5 · Alta Disponibilidad y Sincronización

**Por qué importa:** El lag de replicación determina tu RPO (Recovery Point Objective) real en caso de failover.

### 5.1 Always On Availability Groups (On-prem/MI)

``` sql
-- Estado de sincronización y lag de redo
SELECT 
    ag.name AS ag_name,
    ar.replica_server_name,
    ar.availability_mode_desc AS sync_mode,
    drs.database_id,
    DB_NAME(drs.database_id) AS database_name,
    drs.synchronization_state_desc AS sync_state,
    drs.synchronization_health_desc AS health,
    -- Lag en segundos (aproximado)
    CASE 
        WHEN drs.redo_rate IS NOT NULL AND drs.redo_rate > 0 
        THEN CAST(drs.redo_queue_size AS FLOAT) / drs.redo_rate 
        ELSE NULL 
    END AS estimated_redo_lag_seconds,
    drs.redo_queue_size,
    drs.log_send_queue_size,
    drs.last_redone_time,
    drs.last_hardened_time
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
LEFT JOIN sys.dm_hadr_database_replica_states drs 
    ON ar.replica_id = drs.replica_id
ORDER BY ag.name, ar.replica_server_name, database_name;

-- Primary replica específica
SELECT 
    ag.name,
    ags.primary_replica,
    ags.synchronization_health_desc AS overall_health,
    ags.primary_recovery_health_desc
FROM sys.availability_groups ag
JOIN sys.dm_hadr_availability_group_states ags ON ag.group_id = ags.group_id;
```

### 5.2 Azure SQL: Failover Groups y Geo-replicación
> 📋 En Azure SQL Database (PaaS), usar Azure Portal, CLI o PowerShell para estado de failover groups. Las DMVs anteriores no aplican.

```powershell
# Estado de failover group con Azure CLI
az sql failover-group show 
    --name <failover-group-name> 
    --server <primary-server-name> 
    --resource-group <resource-group-name>

# Listar réplicas geo
az sql db replica list-links 
    --name <database-name> 
    --server <server-name> 
    --resource-group <resource-group-name>
```

#### Baseline a capturar:
- Lag de sincronización promedio entre réplicas
- Tiempo de failover histórico (si se han hecho drills)
- Estado de routing (primaria vs. secundaria legible)

## 6 · Herramientas y Automatización

### 6.1 sp_WhoIsActive (Adam Machanic)

Procedimiento almacenado de diagnóstico en tiempo real. Capturar periódicamente en tabla para análisis histórico:

```sql
-- Ejemplo de captura automatizada
CREATE TABLE dbo.WhoIsActiveLog (
    [dd hh:mm:ss.mss] VARCHAR(20),
    [session_id] SMALLINT,
    [sql_text] XML,
    [login_name] NVARCHAR(128),
    [wait_info] NVARCHAR(4000),
    [CPU] VARCHAR(30),
    [tempdb_allocations] VARCHAR(30),
    [blocking_session_id] SMALLINT,
    [reads] VARCHAR(30),
    [writes] VARCHAR(30),
    [physical_reads] VARCHAR(30),
    [query_plan] XML,
    [collection_time] DATETIME2 DEFAULT GETDATE()
);

-- Ejecución periódica vía job
EXEC sp_WhoIsActive 
    @get_plans = 1,
    @get_outer_command = 1,
    @get_transaction_info = 1,
    @destination_table = 'dbo.WhoIsActiveLog';
```

### 6.2 First Responder Kit (Brent Ozar Unlimited)

Scripts de emergencia y diagnóstico que complementan esta baseline:

| Script | Uso |
| --- | --- |
| `sp_Blitz` | Health check general de la instancia |
| `sp_BlitzFirst` | Diagnóstico de "qué está pasando ahora" |
| `sp_BlitzCache` | Análisis de plan cache |
| `sp_BlitzIndex` | Análisis completo de índices |
| `sp_BlitzWho` | Actividad actual (alternativa a WhoIsActive) |

## 6.3 Azure Monitor y Log Analytics (Azure SQL)
Para Azure SQL Database y Managed Instance, configurar:
- Diagnostic settings → Log Analytics
- Metrics: CPU %, Data IO %, Log IO %, storage %
- Query Store como repositorio de planes y estadísticas de rendimiento

📊 Plantilla de Registro de Baseline

| Fecha/Hora | Métrica | Valor | Contexto (carga) | Umbral Alerta |
| --- | --- | --- | --- | --- |
| 2025-03-15 09:00 | Batch requests/sec | 1,250 | Inicio jornada | < 800 o > 2,000 |
| 2025-03-15 09:00 | PLE | 4,500 | Inicio jornada | < 2,250 (50% baseline) |
| 2025-03-15 09:00 | Top wait | PAGEIOLATCH\_SH | Inicio jornada | Cambio en top 3 |
| 2025-03-15 09:00 | Latencia I/O (datos) | 3.2 ms | Inicio jornada | > 10 ms |
| 2025-03-15 09:00 | Jobs fallidos 24h | 0 | Inicio jornada | > 0 |


## 🔗 Referencias
- SQL Server Wait Types Library (SQLSkills)
- First Responder Kit (Brent Ozar)
- sp_WhoIsActive Documentation (Adam Machanic)
- Azure SQL Database Monitoring (Microsoft)

--- 

**Principio rector:** "No puedes mejorar lo que no mides, y no puedes diagnosticar lo que no documentaste."