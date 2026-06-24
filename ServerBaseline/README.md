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

> 📝 Algunas DMVs son específicas de Azure SQL y no existen on-prem (ej: `sys.dm_db_resource_stats`), por el contrario, hay DMVs como `sys.dm_os_process_memory` que no están disponibles en PaaS. Las queries de este documento indican alternativas donde aplique.

---

## 📅 Frecuencia de Captura

| Métrica | Frecuencia | Contexto |
|:---|:---|:---|
| Métricas de rendimiento (CPU, waits, throughput) | Cada 5–15 minutos durante horario laborable | Establecer patrón diario/semanal |
| Page Life Expectancy (PLE) | Cada hora | Tendencia de presión de memoria |
| Latencias de I/O | Diaria (promedio) y horas pico (máximo) | Detectar degradación de storage |
| Salud resumida (fragmentación, stats, tempdb, bloqueos) | Diaria | Señales de alerta temprana |
| Jobs y backups | Tras cada ejecución | Alertas inmediatas de fallo |
| Alta disponibilidad / sincronización | Cada 5 minutos (si aplica) | Detectar lag antes de failover |

> 💡 **Frecuencias adaptativas:** Las recomendaciones de captura son puntos de partida. Ajustar según los **RPO** (Recovery Point Objective: datos máximos tolerables a perder) y **RTO** (Recovery Time Objective: tiempo máximo tolerable de parada) contractuales de cada sistema. Un entorno con RPO de 1 minuto requerirá monitorización más frecuente que uno con RPO de 24 horas.

---

## 🗂️ Índice

1. [Rendimiento del Servidor](#1--rendimiento-del-servidor)
   - [1.1 Throughput de Instancia (On-Premises/MI)](#11-throughput-de-instancia-on-premisesmi)
   - [1.2 Utilización de Recursos (Azure SQL Database)](#12-utilización-de-recursos-azure-sql-database)
   - [1.3 Memoria: Page Life Expectancy (PLE)](#13-memoria-page-life-expectancy-ple)
   - [1.4 Wait Statistics](#14-wait-statistics-qué-espera-el-servidor)
2. [Salud de Almacenamiento](#2--salud-de-almacenamiento)
   - [2.1 Latencias de I/O por Fichero](#21-latencias-de-io-por-fichero)
   - [2.2 Crecimiento de Ficheros y Espacio](#22-crecimiento-de-ficheros-y-espacio)
3. [Salud Resumida de Objetos](#3--salud-resumida-de-objetos)
   - [3.1 Fragmentación: Indicador de Tendencia](#31-fragmentación-indicador-de-tendencia)
   - [3.2 Estadísticas: Indicador de Tendencia](#32-estadísticas-indicador-de-tendencia)
   - [3.3 Presión de tempdb](#33-presión-de-tempdb)
4. [Operaciones Programadas](#4--operaciones-programadas)
   - [4.1 Estado de SQL Agent Jobs](#41-estado-de-sql-agent-jobs)
   - [4.2 Cadenas de Backup](#42-cadenas-de-backup)
   - [4.3 Integridad de Datos (CHECKDB)](#43-integridad-de-datos-checkdb)
5. [Alta Disponibilidad y Sincronización](#5--alta-disponibilidad-y-sincronización)
   - [5.1 Always On Availability Groups](#51-always-on-availability-groups-on-premmi)
   - [5.2 Azure SQL: Failover Groups y Geo-replicación](#52-azure-sql-failover-groups-y-geo-replicación)
6. [Herramientas y Automatización](#6--herramientas-y-automatización)
   - [6.1 sp_WhoIsActive (Adam Machanic)](#61-sp_whoisactive-adam-machanic)
   - [6.2 First Responder Kit (Brent Ozar Unlimited)](#62-first-responder-kit-brent-ozar-unlimited)
   - [6.3 Scripts de Diagnóstico (Glenn Berry)](#63-scripts-de-diagnóstico-glenn-berry)
   - [6.4 Azure Monitor y Log Analytics (Azure SQL)](#64-azure-monitor-y-log-analytics-azure-sql)
7. [Plantilla de Registro de Baseline](#7--plantilla-de-registro-de-baseline)
8. [Referencias](#8--referencias)

---

## 1 · Rendimiento del Servidor

**Por qué importa:** Estas métricas responden la pregunta "¿El servidor está ocupado o libre?" y "¿Dónde está el cuello de botella?".

### 1.1 Throughput de Instancia (On-Premises/MI)

Mide cuántas operaciones por segundo ejecuta la instancia. Indicador de carga de trabajo.

> ⚠️ **Nota técnica:** Los contadores de tipo `PERF_COUNTER_BULK_COUNT` (272696576) son acumuladores desde el inicio de la instancia. Para obtener "por segundo" se requieren **dos muestras con intervalo de tiempo conocido** y calcular la diferencia. Ver documentación Microsoft: [`sys.dm_os_performance_counters`](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-os-performance-counters-transact-sql).
> 
>"Para entornos de producción, considera capturar las dos muestras mediante un trabajo programado con un intervalo fijo, en lugar de usar WAITFOR DELAY, para evitar mantener una conexión abierta."

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

> 📚 **Referencia técnica:** 
> - [ System dynamic management views | SQL Server Operating System | dm_os_performance_counters](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-os-performance-counters-transact-sql)
> - [About Performance Counters | Microsoft Learn](https://learn.microsoft.com/en-us/windows/win32/perfctrs/about-performance-counters)

#### Baseline a capturar
- Batch requests/sec en horas pico vs. valle (establecer patrón diario)
- Ratio recompilaciones/compilaciones (objetivo: < 10%)
- Tendencia semanal: ¿aumenta el throughput con el mismo volumen de datos? (posible degradación de planes)

---

### 1.2 Utilización de Recursos (Azure SQL Database)

Mide qué porcentaje de los recursos asignados consume la base de datos. Indicador de saturación del tier contratado.

> 💡 **Limitación:** `sys.dm_db_resource_stats` retiene datos de aproximadamente 1 hora. Para histórico mayor, usar Azure Monitor. Referencia: [`sys.dm_db_resource_stats`](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-db-resource-stats-azure-sql-database).

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

> 📝 **Diferencia de modelos:** On-Premises y Managed Instance permiten medir **throughput** (trabajo realizado). Azure SQL Database expone **utilización de recursos asignados** (porcentaje de capacidad consumida). Son métricas complementarias, no sustitutas.
>
> 📚 **Referencia técnica:** 
> - [ System dynamic management views | Database | dm_db_resource_stats](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-db-resource-stats-azure-sql-database)

#### Baseline a capturar
- CPU % promedio y máximo por ventana horaria (identificar picos predecibles)
- I/O % correlacionado con operaciones de mantenimiento (rebuilds, backups)
- Memory % estable vs. creciente (indicador de memory pressure en PaaS)

---

### 1.3 Memoria: Page Life Expectancy (PLE)

> ⚠️ **Umbral desactualizado:** La regla antigua de `PLE > 300` es obsoleta para los servidores actuales. La fórmula `(Buffer Pool GB / 4) * 300` es la referencia estándar de la comunidad. Esta query la refina calculando el umbral por nodo NUMA con las páginas reales cargadas en cada uno, ya que unos nodos pueden estar bajo presión mientras otros disponen de más holgura.
>
> 📝 **PLE en contexto:** No interpretar de forma aislada, ya que este no mide rendimiento si no comportamiento del Buffer Pool. Un valor bajo puede ser normal durante operaciones de mantenimiento (rebuilds, cargas masivas). Interpretar siempre junto a la presión de memoria y las lecturas físicas: un PLE bajo no es crítico si no hay esperas de I/O ni impacto en el rendimiento.

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

| NUMA Node | Buffer Pool (Pages) | Buffer Pool (GB) | Suggested Threshold | Current PLE 
|---|---|---|---|---|
| 0	| 11111070	| 84.77	| 6358	| 133319 | 
| 0	| 5716120	| 43.61	| 3271	| 132931 | 
| 1	| 5394950	| 41.16	| 3087	| 133710 | 

> **Notas:**
> - La documentación oficial de Microsoft no establece umbrales específicos para el PLE. La fórmula aquí utilizada es una heurística de la comunidad, no un estándar oficial.
> - Esta query recoge el PLE por `Buffer Node`, es decir, por nodo NUMA. Si se consulta sin filtrar por nodo — usando `Buffer Manager` en lugar de `Buffer Node` — se obtiene un único valor para toda la instancia que corresponde con la media armónica.
>
> **Mejor práctica:** Establece tu propio baseline de PLE cuando el sistema rinde correctamente y configura alertas si cae más de un porcentaje determinado respecto a ese valor de referencia.

#### Baseline a capturar
- PLE por NUMA node en horas pico y valle
- Porcentaje sobre el umbral sugerido como tendencia
- Correlacionar caídas de PLE con picos de `PAGEIOLATCH%` en wait stats

---

### 1.4 Wait Statistics: Qué espera el servidor

> 📝 Los waits son **sintomáticos, no causales**. Un wait alto indica dónde está el tiempo, no necesariamente el problema raíz.

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
        -- Capa de almacenamiento (Disco)
        WHEN ws.wait_type LIKE 'PAGEIOLATCH%' THEN 'Storage I/O'
        WHEN ws.wait_type LIKE 'WRITELOG%' THEN 'Transaction Log I/O'
        WHEN ws.wait_type LIKE 'BACKUP%' THEN 'Backup/Restore'
        -- Capa de memoria (Buffer Pool)
        WHEN ws.wait_type LIKE 'PAGELATCH%' THEN 'Buffer/memory'
        -- Capa de concurrencia (Bloqueos)
        WHEN ws.wait_type LIKE 'LCK%' THEN 'Locking'
        -- Capa de procesamiento (CPU)
        WHEN ws.wait_type LIKE 'SOS_SCHEDULER%' THEN 'CPU/Scheduler'
        WHEN ws.wait_type LIKE 'CXPACKET%' OR ws.wait_type LIKE 'CXCONSUMER%' THEN 'Parallelism'
        -- Capa de red/comunicación
        WHEN ws.wait_type LIKE 'ASYNC_NETWORK_IO%' THEN 'Network/Client'
        WHEN ws.wait_type LIKE 'HADR%' THEN 'Availability Groups'
        WHEN ws.wait_type LIKE 'OLEDB%' THEN 'Linked Servers'
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

> 💡 Referencia completa de tipos de espera con descripción y diagnóstico: [SQLSkills Wait Types Library](https://www.sqlskills.com/help/waits/)

#### Desglose de la clasificación para el análisis

1 - **Storage I/O** (`PAGEIOLATCH%`)
- **Se da cuando:** una query necesita una página de datos que no está en el buffer pool y hay que leerla del disco. SQL Server pide la lectura al SO y espera a que llegue. Es espera física de I/O. Si es alto: el buffer pool es insuficiente para la carga de trabajo o el almacenamiento es lento.
- **Causa común:** Discos lentos (IOPS insuficientes para la carga de trabajo), falta de Memoria RAM (que obliga a leer más en disco) o consultas que leen tablas gigantescas sin utilizar índices.

2 - **Buffer/Memory** (`PAGELATCH%`)
- **Se da cuando:** la página ya está en el buffer pool (no hay I/O de disco) pero otra sesión la está modificando en ese momento. Es contención en memoria entre sesiones concurrentes. Típico en `tempdb` con mucha concurrencia o en tablas muy calientes. El problema es CPU/memoria, no disco.
- **Causa común:** tablas con muchísimas inserciones simultáneas en una misma página (frecuente en índices con claves secuenciales), contención en `tempdb`, contenciones en las páginas PFS (Page Free Space), GAM (Global Allocation Map) y SGAM (Shared Global Allocation Map).

3 - **Locking** (`LCK%`)
- **Se da cuando:** una sesión espera porque otra tiene un lock incompatible sobre un recurso (fila, página, tabla). La sesión A quiere leer/escribir algo que la sesión B tiene bloqueado. 
- **Causa común:** Transacciones que tardan demasiado tiempo abiertas o falta de índices que hace que se bloqueen tablas enteras en lugar de una sola página o fila.

4 - **CPU/Scheduler** (`SOS_SCHEDULER_YIELD`)
- **Se da cuando:** un worker tiene trabajo listo para ejecutar pero no hay un scheduler de CPU disponible para asignárselo. Indica presión de CPU — más tareas ejecutables que núcleos disponibles. Si es alto: CPU saturada o configuración de `MAXDOP` inadecuada.
- **Causa común:** consultas muy pesadas matemáticamente, exceso de carga de trabajo o simplemente que el servidor se quedó corto de procesadores (CPU).

5 - **Parallelism** (`CXPACKET` / `CXCONSUMER`)
- **Se da cuando:** una query se ejecuta en múltiples threads en paralelo y los threads no terminan al mismo tiempo. `CXPACKET` es el productor esperando al consumidor, `CXCONSUMER` el inverso. No siempre es un problema — el paralelismo es normal. Sí es problema si aparece con queries cortas o OLTP donde el paralelismo es contraproducente.
- **Causa común:** configuración de `MAXDOP` inadecuada o consultas que el optimizador cree que son pesadas pero están mal diseñadas o utiliza estadísticas incorrectas.

6 - **Network/Client** (`ASYNC_NETWORK_IO`)
- **Se da cuando:** SQL Server terminó de procesar y tiene resultados listos, pero el cliente no los está consumiendo tan rápido como se generan. No tiene por qué ser un problema de red en sí — puede ser debido a que el cliente procesa fila a fila en lugar de en bulk, o la red tiene latencia. Típico en aplicaciones que iteran resultados lentamente.
- **Causa común:** no es problema de SQL Server, es de la red  (latencia alta, ancho de banda limitado), la aplicación que consume los datos (procesando datos fila por fila a través de cursores) o `Result sets` enormes enviados a la aplicación.

7 - **Transaction Log I/O** (`WRITELOG`)
- **Se da cuando:** una transacción ha hecho COMMIT y espera a que el Log Manager escriba físicamente al fichero de log antes de confirmar. Es la garantía de durabilidad (la D de ACID). Si es alto: el disco del log es lento, el log está en el mismo disco que los datos, o hay transacciones muy frecuentes y pequeñas que podrían agruparse.
- **Causa común:** el log en disco esta compartido (mismo disco que datos) o es muy lento, hay transacciones muy frecuentes y pequeñas en lugar de procesos que gestionen la información por lotes.

8 - **Availability Groups** (`HADR%`)
- **Se da cuando:** SQL Server está esperando sincronización con réplicas de Availability Groups (AG). Por ejemplo HADR_SYNC_COMMIT indica que una transacción en el primario está esperando confirmación de que el log ha sido endurecido en el secundario antes de confirmar el commit — esto ocurre en modo síncrono. 
- **Causa común:** Latencia de red entre nodos del cluster, secundario sobrecargado, o que el modo síncrono está penalizando el rendimiento del primario.<br>*Nota:* Existen más de 60 tipos de espera que inician con `HADR%` de las cuales solo estamos excluyendo unas pocas, por lo que habría que hacer la valoración correspondiente en base el tipo en concreto que encontremos.

9 - **Backup/Restore** (`BACKUP%`)
- **Se da cuando:** generados durante operaciones de backup y restore. `BACKUPBUFFER` indica que el proceso de backup está esperando que se llene el buffer antes de escribirlo al destino, y `BACKUPIO` que está esperando a la escritura física en el medio de backup.
- **Causa común:** al crear un backup o leerse desde una unidad lenta o si existe latencia red, coindidencia con horas pico de tráfico de red, volumenes de backup compartidos con los de datos.

10 - **Linked Servers** (`OLEDB%`)
- **Se da cuando:** aparecen cuando una query cruza un linked server — SQL Server lanza la petición al servidor remoto y espera la respuesta.
- **Causa común:** queries distribuidas lentas, linked servers a servidores sobrecargados o con alta latencia de red, o uso excesivo de linked servers donde debería haber una integración más directa.

#### Baseline a capturar
- Top 5 waits por tiempo acumulado en condiciones normales
- Evolución semanal: ¿aparecen nuevos waits en el top? ¿suben de posición?

---

## 2 · Salud de Almacenamiento

**Por qué importa:** El almacenamiento es el cuello de botella más común. Las latencias de I/O degradan todas las operaciones, no solo las consultas "lentas".

### 2.1 Latencias de I/O por Fichero

Umbrales de referencia  (no dogmas). Más detalles en [Troubleshoot SQL Server I/O performance](https://learn.microsoft.com/en-us/troubleshoot/sql/database-engine/performance/troubleshoot-sql-io-performance):

| Tiempo | Valoración| Medio |
| ---: | --- | --- |
| < 2 ms | Excelente | NVMe/SSD premium |
| 2–5 ms | Muy bueno | SSD Estándard |
| 6–15 ms | Bueno | HDDs RAID |
| 16–100 ms | Pobre |  |
| > 100 ms | Crítico |  |

> ⚠️ Asociar en esta tabla los tipos de almacenamiento a umbrales no determina el hardware subyacente real.

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
        INNER JOIN 
    sys.master_files f ON vfs.database_id = f.database_id
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
    avg_latency_ms DESC;

-- Azure SQL Database: sustituir sys.master_files por sys.database_files
--     INNER JOIN sys.database_files f ON vfs.file_id = f.file_id
```

#### Baseline a capturar
- Latencias promedio por fichero de datos en horas pico y valle
- Latencia de escritura en log (objetivo: < 2 ms)
- `avg_size_kb` — lecturas de 8 KB son aleatorias (row lookups), lecturas grandes suelen indicar scans o backups

---

### 2.2 Crecimiento de Ficheros y Espacio

```sql
-- Tendencia de crecimiento (comparar con capturas anteriores)
IF OBJECT_ID('tempdb..#FileStats') IS NOT NULL DROP TABLE #FileStats;

CREATE TABLE #FileStats 
    (
        database_name NVARCHAR(128),
        logical_name NVARCHAR(128),
        physical_name NVARCHAR(260),
        type_desc NVARCHAR(60),
        current_size_mb DECIMAL(10,2),
        max_size_mb DECIMAL(10,2),
        autogrowth_setting NVARCHAR(50),
        space_used_mb DECIMAL(10,2),
        free_space_mb DECIMAL(10,2),
        percent_used DECIMAL(5,2)
    );

-- Cursor sobre todas las BBDDs online
DECLARE @db_name NVARCHAR(128);
DECLARE @sql     NVARCHAR(MAX);

DECLARE db_cursor CURSOR FAST_FORWARD FOR
    SELECT name 
    FROM sys.databases 
    WHERE state_desc = 'ONLINE'
    AND database_id > 4;  -- Excluir sistema. Quitar condición si se quiere incluir tempdb, etc.

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @db_name;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'
        USE ' + QUOTENAME(@db_name) + N';
        INSERT INTO #FileStats
            SELECT 
                DB_NAME() AS database_name,
                f.name AS logical_name,
                f.physical_name,
                f.type_desc,
                CAST(f.size / 128.0 AS DECIMAL(10,2)) AS current_size_mb,
                CASE 
                    WHEN f.type_desc = ''LOG'' AND f.max_size = 268435456 THEN NULL
                    WHEN f.max_size = -1 THEN NULL
                    WHEN f.max_size = 0 THEN  0
                    ELSE CAST(f.max_size / 128.0  AS DECIMAL(10,2))
                END AS max_size_mb,
                CASE f.is_percent_growth
                    WHEN 1 THEN CAST(f.growth AS VARCHAR) + '' %''
                    ELSE CAST(CAST(f.growth / 128.0  AS DECIMAL(10,2)) AS VARCHAR) + '' MB''
                END AS autogrowth_setting,
                CAST(FILEPROPERTY(f.name, ''SpaceUsed'') / 128.0 AS DECIMAL(10,2)) AS space_used_mb,
                CAST((f.size - FILEPROPERTY(f.name, ''SpaceUsed'')) / 128.0 AS DECIMAL(10,2)) AS free_space_mb,
                CAST(FILEPROPERTY(f.name, ''SpaceUsed'') * 100.0 / f.size AS DECIMAL(5,2))  AS percent_used
            FROM 
                sys.database_files f;';

    EXEC sp_executesql @sql;
    FETCH NEXT FROM db_cursor INTO @db_name;
END;

CLOSE db_cursor;
DEALLOCATE db_cursor;

SELECT * 
FROM #FileStats
ORDER BY 
    database_name, type_desc;

DROP TABLE #FileStats;

-- Script válido también para Azure SQL Database
```

> 📝 `FILEPROPERTY` solo devuelve valores correctos en el contexto de la base de datos a la que pertenece el fichero. Por eso se usa `sys.database_files` con `USE` dinámico por cada base de datos, en lugar de `sys.master_files`.

#### Baseline a capturar
- Tamaño y espacio libre por fichero — comparar semana a semana para calcular tasa de crecimiento
- Número de autogrowths por día — **objetivo: 0**; todo crecimiento debe ser planificado
- Ficheros con `max_size_mb = 0` (sin crecimiento permitido) son un riesgo operativo

---

## 3 · Salud Resumida de Objetos

**Por qué importa:** Las queries de detalle (qué índice concreto está fragmentado, qué estadística en particular hay que actualizar) pertenecen al [📋 Playbook de Mantenimiento](./playbook_mantenimiento_sqlserver.md). Para el baseline, el objetivo es capturar **tendencias numéricas** que sirvan de señal de alerta.

### 3.1 Fragmentación: Indicador de Tendencia

Un número creciente de índices fragmentados de forma sostenida indica que el mantenimiento no da abasto o que la carga de escritura ha aumentado significativamente.

```sql
-- ¿Qué índices significativos tienen fragmentación problemática hoy?
-- Capturar periódicamente y comparar la tendencia
-- Ejecutar en cada base de datos de interés
SELECT 
    i.name,
    ips.index_type_desc,
    ips.alloc_unit_type_desc
FROM 
    sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') ips
        INNER JOIN 
    sys.indexes i ON ips.object_id = i.object_id AND ips.index_id = i.index_id
WHERE 
    -- Solo índices con volumen significativo (> ~8 MB)
    ips.page_count > 1000  
    AND ips.avg_fragmentation_in_percent > 10
    -- Excluir heaps
    AND i.type > 0; 
```

#### Baseline a capturar
- Número de índices con fragmentación > 10% en condiciones normales
- Evolución tras cada ventana de mantenimiento (debe bajar a 0 o cerca)

---

### 3.2 Estadísticas: Indicador de Tendencia

Cuando `AUTO_UPDATE_STATISTICS` está en `ON` (modo síncrono, valor por defecto), la actualización ocurre en el momento de compilar un plan, no durante los DML. La query que "rompe" el umbral paga el coste antes de ejecutarse. Un número creciente de estadísticas pendientes indica que el mantenimiento preventivo no da abasto con la actividad del servidor.

```sql
-- ¿Cuántas estadísticas superan el umbral dinámico del motor hoy?
-- Umbral dinámico SQL Server 2016+ (compat level 130): MIN(500 + 0.20*n, SQRT(1000*n))
-- En SQL Server 2022 se puede sustituir el CASE por la función escalar LEAST()
-- Capturar periódicamente y comparar la tendencia
SELECT 
    DB_NAME() AS [Database Name],
    SCHEMA_NAME(t.schema_id) AS [Schema Name],
    t.name AS [Table Name],
    s.name AS [Stats Name],
    s.auto_created AS [Auto Created],
    s.user_created AS [User Created],
    sp.last_updated AS [Last Updated],
    sp.rows AS [Rows],
    sp.rows_sampled AS [Rows Sampled],
    CAST(sp.rows_sampled * 100.0 / NULLIF(sp.rows, 0) AS DECIMAL(10,2)) AS [Sample Rate Pct],
    sp.modification_counter AS [Modification Counter],
    CAST(sp.modification_counter * 100.0 / NULLIF(sp.rows, 0) AS DECIMAL(10,2)) AS [Percent Modified],
    -- Umbral dinámico en número de filas (mismo criterio que el motor)
    CAST(
        CASE 
            WHEN (500 + 0.20 * sp.rows) < SQRT(1000.0 * sp.rows)
                THEN (500 + 0.20 * sp.rows)
            ELSE SQRT(1000.0 * sp.rows)
        END
    AS DECIMAL(18,0)) AS [Dynamic Threshold Rows]
FROM 
    sys.stats s
        INNER JOIN 
    sys.tables t ON s.object_id = t.object_id
        CROSS APPLY 
    sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
WHERE 
    sp.modification_counter >=
        CASE 
            WHEN (500 + 0.20 * sp.rows) < SQRT(1000.0 * sp.rows)
                THEN (500 + 0.20 * sp.rows)
            ELSE SQRT(1000.0 * sp.rows)
        END
    AND sp.rows > 0;
```

#### Baseline a capturar
- Número de estadísticas pendientes en condiciones normales
- Evolución tras las ventanas de mantenimiento (debe bajar a 0 o cerca)

---

### 3.3 Presión de tempdb

`tempdb` es el recurso compartido de toda la instancia. Su presión es frecuentemente el primer síntoma visible de problemas de concurrencia o queries mal optimizadas.

```sql
-- Uso actual de tempdb por tipo
-- Válido para On-Premises y MI
USE tempdb

SELECT 
    -- Espacio libre sin asignar
    CAST(SUM(unallocated_extent_page_count) / 128.0 AS DECIMAL(10,2)) AS free_mb,
    -- Espacio reservado para el almacén de versiones
    CAST(SUM(version_store_reserved_page_count) / 128.0 AS DECIMAL(10,2)) AS version_store_mb,
    -- Espacio reservado para objetos de usuario
    CAST(SUM(user_object_reserved_page_count) / 128.0 AS DECIMAL(10,2)) AS user_objects_mb,
    -- Espacio reservado para objetos internos
    CAST(SUM(internal_object_reserved_page_count) / 128.0 AS DECIMAL(10,2)) AS internal_objects_mb,
    -- Tamaño total del archivo (para contexto)
    CAST(SUM(total_page_count) / 128.0 AS DECIMAL(10,2)) AS total_mb,
    -- Porcentaje de espacio libre sobre el total
    CAST(SUM(unallocated_extent_page_count) * 100.0 / NULLIF(SUM(total_page_count), 0) AS DECIMAL(10,2)) AS free_percent
FROM 
    sys.dm_db_file_space_usage;

```

> 📝 **`version_store_mb`** creciente sostenidamente indica transacciones largas abiertas sin cerrar. **`internal_objects_mb`** alto indica uso intensivo de ordenaciones, spools o tablas temporales en queries complejas.

#### Baseline a capturar
- Espacio libre de tempdb en horas pico — si tiende a 0, hay riesgo de fallo
- Tamaño del version store en condiciones normales — correlacionar picos con waits de `LCK%`

---

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
FROM 
    msdb.dbo.sysjobs j
        LEFT JOIN 
        (
            -- Solo la última ejecución por job
            SELECT job_id, run_date, run_time, run_status, run_duration, message,
                ROW_NUMBER() OVER (PARTITION BY job_id ORDER BY run_date DESC, run_time DESC) AS rn
            FROM msdb.dbo.sysjobhistory
            WHERE step_id = 0  -- Solo el resultado general del job, no pasos individuales
        ) jh ON j.job_id = jh.job_id AND jh.rn = 1
ORDER BY 
    j.name;

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

#### Baseline a capturar
- Duración habitual de cada job — un job que tarda el doble de lo normal es señal de alerta
- Jobs fallidos en las últimas 24 horas — **objetivo: 0**

---

### 4.2 Cadenas de Backup

> ⚠️ Los umbrales de alerta (`-7 días`, `-25 horas`, `-4 horas`) son orientativos. **Deben ajustarse a la política de backup de cada entorno** según el RPO requerido. 

```sql
-- Últimos backups por base de datos y tipo
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
FROM 
    msdb.dbo.backupset bs
WHERE 
    bs.is_copy_only = 0  -- Excluir backups ad-hoc
GROUP BY 
    bs.database_name, 
    bs.type
ORDER BY 
    bs.database_name, 
    CASE bs.type WHEN 'D' THEN 1 WHEN 'I' THEN 2 WHEN 'L' THEN 3 ELSE 4 END;

-- Azure SQL Database: usar sys.dm_database_backups (limitado) o Azure Portal/Monitor
```

#### Baseline a capturar
- Horas desde el último backup por tipo y base de datos
- Tendencia de duración de los backups — un backup que crece semana a semana refleja crecimiento de datos

---

### 4.3 Integridad de Datos (CHECKDB)

```sql
-- Último CHECKDB exitoso por base de datos
-- DATABASEPROPERTYEX solo reporta si se ejecutó DBCC CHECKDB completo,
-- no operaciones parciales como CHECKTABLE o CHECKALLOC

SELECT 
    name AS [Database Name],
    DATABASEPROPERTYEX(name, 'LastGoodCheckDbTime') AS [Last Good Checkdb],
    DATEDIFF
        (
            DAY, 
            CAST(DATABASEPROPERTYEX(name, 'LastGoodCheckDbTime') AS DATETIME), 
            GETDATE()
        ) AS days_since_checkdb,
    CASE 
        WHEN DATABASEPROPERTYEX(name, 'LastGoodCheckDbTime') IS NULL THEN 'NEVER CHECKED'
        WHEN DATABASEPROPERTYEX(name, 'LastGoodCheckDbTime') < DATEADD(DAY, -7, GETDATE()) THEN 'STALE'
        ELSE 'OK'
    END AS checkdb_status
FROM 
    sys.databases
WHERE 
    database_id > 4       -- Excluir sistema. Quitar si son críticas.
    AND state_desc = 'ONLINE'
ORDER BY 
    days_since_checkdb DESC;

-- Usar DBCC CHECKDB manual solo en Managed Instance o IaaS.
```

#### Baseline a capturar
- Días desde el último CHECKDB exitoso — **objetivo: nunca más de 7 días**
- Bases de datos que nunca han sido verificadas — riesgo operativo inmediato

---

## 5 · Alta Disponibilidad y Sincronización

**Por qué importa:** El lag de replicación determina tu RPO real en caso de failover.

### 5.1 Always On Availability Groups (On-prem/MI)

```sql
-- ======================================================================
-- Estado de sincronización y lag de redo para Availability Groups
-- ======================================================================
-- Nota: Esta consulta funciona en SQL Server (On-Prem) y Azure SQL Managed Instance.
--       En Azure SQL Database (PaaS) esta DMV no está disponible.
-- ======================================================================

SELECT 
    ag.name AS ag_name,
    ar.replica_server_name,
    CASE drs.is_primary_replica           
        WHEN 1 THEN 'PRIMARY' 
        ELSE 'SECONDARY'      
    END AS rol,
    ar.availability_mode_desc AS sync_mode,
    drs.database_id,
    DB_NAME(drs.database_id) AS database_name, 
    drs.synchronization_state_desc AS sync_state, 
    -- Salud de la Sincronización
    drs.synchronization_health_desc AS health,  -- 'HEALTHY' (todo funciona correctamente)
                                                -- 'PARTIALLY_HEALTHY' (algún problema parcial)
                                                -- 'NOT_HEALTHY' (problema grave)

    -- Tiempo estimado (en segundos) que la secundaria tarda en aplicar los logs pendientes.
    CAST(drs.redo_queue_size AS FLOAT) / NULLIF(drs.redo_rate, 0) AS estimated_redo_lag_seconds,
    -- Cantidad de registros de log (en KB) que aún no se han aplicado en la BD secundaria.
    drs.redo_queue_size,
    -- Cantidad de registros de log (en KB) que el primario aún no ha enviado a la réplica secundaria.
    drs.log_send_queue_size,
    -- Tasa actual de envío de logs (en KB/segundo) desde el primario hacia la réplica secundaria.
    drs.log_send_rate,
    -- Fecha/hora en que el último registro de log fue aplicado en la base de datos secundaria.
    drs.last_redone_time,
    -- Fecha/hora en que el último bloque de log fue escrito de forma duradera en disco en la réplica secundaria.
    drs.last_hardened_time
FROM 
    sys.availability_groups ag
        INNER JOIN 
    sys.availability_replicas ar ON ag.group_id = ar.group_id
        LEFT JOIN 
    sys.dm_hadr_database_replica_states drs ON ar.replica_id = drs.replica_id
ORDER BY 
    drs.is_primary_replica DESC, 
    ag.name, 
    ar.replica_server_name, 
    database_name;

-- Estado global del grupo de disponibilidad (primary)
SELECT 
    ag.name,
    ags.primary_replica,
    ags.synchronization_health_desc AS overall_health,
    ags.primary_recovery_health_desc
FROM 
    sys.availability_groups ag
        INNER JOIN 
    sys.dm_hadr_availability_group_states ags ON ag.group_id = ags.group_id;
```

#### Baseline a capturar
- Lag de sincronización (`estimated_redo_lag_seconds`) promedio entre réplicas
- Estado de salud del grupo — cualquier estado distinto de `HEALTHY` es alerta inmediata
- Tiempo de failover histórico si se han hecho simulacros planificados

---

### 5.2 Azure SQL: Failover Groups y Geo-replicación

> 📋 En Azure SQL Database (PaaS) las DMVs de Always On no aplican. Usar Azure Portal, CLI o PowerShell.

```powershell
# Estado de failover group con Azure CLI
az sql failover-group show `
    --name <failover-group-name> `
    --server <primary-server-name> `
    --resource-group <resource-group-name>

# Listar réplicas geo
az sql db replica list-links `
    --name <database-name> `
    --server <server-name> `
    --resource-group <resource-group-name>
```

---

## 6 · Herramientas y Automatización

### 6.1 sp_WhoIsActive (Adam Machanic)

Diagnóstico en tiempo real de sesiones activas. Capturar periódicamente en tabla para análisis histórico.

- Descarga e instrucciones de instalación: [github: sp_whoisactive](https://github.com/amachanic/sp_whoisactive)

```sql
-- Genera el esquema para crear la tabla de captura.
DECLARE @schema VARCHAR(MAX);

EXEC sp_WhoIsActive 
        @get_plans = 1,
        @get_outer_command = 1,
        @get_transaction_info = 1,
        @return_schema = 1,
        @schema = @schema OUTPUT;

PRINT @schema;

-- La versión instalada en mi caso genera el script:
CREATE TABLE dbo.WhoIsActiveLog 
    ( 
        [dd hh:mm:ss.mss] varchar(8000) NULL,
        [session_id] smallint NOT NULL,
        [sql_text] xml NULL,
        [sql_command] xml NULL,
        [login_name] nvarchar(128) NOT NULL,
        [wait_info] nvarchar(4000) NULL,
        [tran_log_writes] nvarchar(4000) NULL,
        [CPU] varchar(30) NULL,
        [tempdb_allocations] varchar(30) NULL,
        [tempdb_current] varchar(30) NULL,
        [blocking_session_id] smallint NULL,
        [reads] varchar(30) NULL,
        [writes] varchar(30) NULL,
        [physical_reads] varchar(30) NULL,
        [query_plan] xml NULL,
        [used_memory] varchar(30) NULL,
        [status] varchar(30) NOT NULL,
        [tran_start_time] datetime NULL,
        [implicit_tran] nvarchar(3) NULL,
        [open_tran_count] varchar(30) NULL,
        [percent_complete] varchar(30) NULL,
        [host_name] nvarchar(128) NULL,
        [database_name] nvarchar(128) NULL,
        [program_name] nvarchar(128) NULL,
        [start_time] datetime NOT NULL,
        [login_time] datetime NULL,
        [request_id] int NULL,
        [collection_time] datetime NOT NULL
    );

-- Ejecución periódica vía SQL Agent Job
EXEC sp_WhoIsActive 
        @get_plans            = 1,
        @get_outer_command    = 1,
        @get_transaction_info = 1,
        @destination_table    = 'dbo.WhoIsActiveLog';
```

---

### 6.2 First Responder Kit (Brent Ozar Unlimited)

Scripts de emergencia y diagnóstico que complementan esta baseline.

- Descarga e instrucciones: [github: SQL-Server-First-Responder-Kit](https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit)

| Script | Uso |
|---|---|
| `sp_Blitz` | Health check general de la instancia |
| `sp_BlitzFirst` | Diagnóstico de "qué está pasando ahora" |
| `sp_BlitzCache` | Análisis de plan cache |
| `sp_BlitzIndex` | Análisis completo de índices |
| `sp_BlitzWho` | Actividad actual (alternativa a sp_WhoIsActive) |

---

### 6.3 Scripts de Diagnóstico (Glenn Berry)

Los [Diagnostic Information Queries](https://glennsqlperformance.com/resources/) de Glenn Berry son un conjunto de scripts T-SQL basados en DMVs que permiten obtener una visión integral del rendimiento y la configuración de tu instancia de SQL Server.

**Uso recomendado:**
Ejecuta las consultas de forma individual, en lugar de todo el script a la vez, para analizar los resultados y entender el contexto de cada métrica.

### Scripts Clave de Glenn Berry

| Nº | Nombre | Propósito | Sección Baseline |
|----|--------|-----------|------------------|
| **41** | `Top Waits` | Identifica los cuellos de botella más importantes de la instancia. | 1. Rendimiento |
| **48** | `PLE by NUMA Node` | Mide la presión de memoria a través del Page Life Expectancy. | 1. Rendimiento (Memoria) |
| **46** | `CPU Utilization History` | Muestra la evolución del uso de CPU en los últimos 256 minutos. | 1. Rendimiento (CPU) |
| **31** | `IO Latency by File` | Latencias de lectura/escritura por cada archivo de base de datos. | 2. Almacenamiento |
| **29** | `Volume Info` | Espacio libre en los volúmenes donde tienes archivos de BD. | 2. Almacenamiento |
| **76** | `Index Fragmentation` | Fragmentación de índices (solo los que superan 2500 páginas). | 3. Salud de Objetos |
| **74** | `Statistics Update` | Fecha de última actualización de estadísticas y porcentaje de muestreo. | 3. Salud de Objetos |
| **8** | `Last Backup By Database` | Últimos backups (Full, Diff, Log) y tamaño de archivos. | 4. Operaciones (Backups) |
| **10** | `SQL Server Agent Jobs` | Estado y última ejecución de los trabajos del Agente. | 4. Operaciones (Jobs) |
| **16** | `AG Status` | Estado de sincronización y lag de Availability Groups. | 5. Alta Disponibilidad |

> 💡 Estos **10 scripts** se pueden ejecutar manualmente en horas pico o automatizarlos con el módulo **dbatools** (`Invoke-DbaDiagnosticQuery`).
>
> Asegúrate de descargar la versión del script que corresponda a tu versión de SQL Server. Existen versiones específicas para Azure SQL Database y Managed Instance.
>
> La numeración de los scripts indicada en la tabla corresponden con la versión para [SQL Server 2025 Diagnostic Information Queries](https://www.dropbox.com/scl/fi/8qtdi3w5ix2bra8ytk7oy/SQL-Server-2025-Diagnostic-Information-Queries.sql?rlkey=kv1t4fdwe60nkd7fl0jukhnnq&dl=0)

### 6.4 Azure Monitor y Log Analytics (Azure SQL)

Para Azure SQL Database y Managed Instance, configurar:
- **Diagnostic settings → Log Analytics:** exportar métricas y logs de diagnóstico
- **Metrics a monitorizar:** CPU %, Data IO %, Log IO %, Storage %
- **Query Store:** repositorio integrado de planes y estadísticas de rendimiento — habilitarlo en todas las bases de datos de producción

---

## 7 · Plantilla de Registro de Baseline

Capturar en condiciones de carga representativa (horas pico de un día laborable típico) y repetir con la frecuencia indicada en la tabla de frecuencias.

| Métrica | Valor | Contexto (carga) | Umbral Alerta (según documento) |
|---|---|---|---|
| Batch requests/sec | `1.250` | Inicio jornada | `< 800` o `> 2.000` (tendencia) |
| Ratio recompilaciones/compilaciones | `5%` | Inicio jornada | `> 10%` (objetivo) |
| PLE Node 0 (actual) | `4.500` | Inicio jornada | `< 50% del valor baseline` |
| Top wait type (1º) | `PAGEIOLATCH_SH` | Inicio jornada | Cambio en top 3 (sintomático) |
| Latencia I/O datos (avg read) | `3,2 ms` | Inicio jornada | `> 15 ms` (pobre) |
| Latencia I/O log (avg write) | `0,8 ms` | Inicio jornada | `> 5 ms` (objetivo `< 2 ms`) |
| tempdb libre (MB) | `12.450 MB` | Inicio jornada | `< 20% del total` (riesgo de fallo) |
| tempdb version_store (MB) | `...` | Inicio jornada | Crecimiento sostenido (transacciones largas) |
| tempdb internal_objects (MB) | `...` | Inicio jornada | Alto sostenido (queries complejas) |
| Índices fragmentados (>10%) (count) | `12` | Post-mantenimiento | `> 30` (tendencia) |
| Stats pendientes (count) | `3` | Post-mantenimiento | `> 20` (tendencia) |
| Jobs fallidos (últimas 24h) | `0` | Diario | `> 0` (alerta inmediata) |
| Duración de job (ej. Index Maintenance) | `00:15:30` | Post-ejecución | `> 2x` duración habitual (tendencia) |
| Horas desde último backup FULL | `6 h` | Diario | `> RPO_acordado` (ej. `> 24h`) |
| Horas desde último backup LOG | `0,5 h` | Diario | `> RPO_acordado` (ej. `> 4h`) |
| Días desde último CHECKDB | `2` | Semanal | `> 7` (riesgo) |
| AG Redo Lag (seg) | `1,2` | Inicio jornada | `> 30` (alerta) |
| AG Health (global) | `HEALTHY` | Continuo | `≠ HEALTHY` (alerta inmediata) |

---

## 🔗 Referencias

### Documentación Oficial de Microsoft

- [Establish a Performance Baseline - SQL Server](https://learn.microsoft.com/en-us/SQL/relational-databases/performance/establish-a-performance-baseline?view=sql-server-linux-2017) — Guía para establecer una línea base de rendimiento en SQL Server.

- [Collect Baseline: Performance Best Practices & Guidelines - SQL Server on Azure VMs](https://learn.microsoft.com/en-us/Azure/azure-sql/virtual-machines/windows/performance-guidelines-best-practices-collect-baseline?view=azuresql) — Prácticas recomendadas para recopilar una línea base de rendimiento en SQL Server sobre Azure Virtual Machines.

- [Establish baseline metrics - Training](https://learn.microsoft.com/en-us/training/modules/describe-performance-monitoring/4-establish-baseline-metrics) — Módulo formativo sobre el establecimiento de métricas de línea base y su correlación con el rendimiento del sistema operativo.

- [Best Practices for Monitoring Workloads with Query Store - SQL Server](https://learn.microsoft.com/en-us/sql/relational-databases/performance/best-practice-with-the-query-store?view=sql-server-ver17) — Prácticas recomendadas para el uso de Query Store en la monitorización de cargas de trabajo.

- [sys.dm_os_performance_counters — Microsoft Learn](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-os-performance-counters-transact-sql) — Documentación de la DMV para contadores de rendimiento del sistema operativo.

- [sys.dm_db_resource_stats — Microsoft Learn](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-db-resource-stats-azure-sql-database) — Documentación de la DMV para estadísticas de recursos en Azure SQL Database.

### Comunidad y Herramientas de Diagnóstico

- [Wait Types Library — SQLSkills (Paul Randal)](https://www.sqlskills.com/help/waits/) — Biblioteca completa de tipos de espera con descripciones detalladas y estrategias de diagnóstico.

- [Wait Statistics, or please tell me where it hurts — Paul Randal](https://www.sqlskills.com/blogs/paul/wait-statistics-or-please-tell-me-where-it-hurts/) — Artículo fundamental sobre cómo interpretar las estadísticas de espera en SQL Server.

- [First Responder Kit — Brent Ozar Unlimited](https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit) — Conjunto de procedimientos almacenados para diagnósticos de salud, rendimiento y solución de problemas en SQL Server (incluye `sp_Blitz`, `sp_BlitzCache`, `sp_BlitzIndex`, etc.).

- [sp_WhoIsActive — Adam Machanic](https://github.com/amachanic/sp_whoisactive) — Repositorio oficial y documentación completa de `sp_WhoIsActive`.
---
<br>

> 💡 **Principio rector:** *"No puedes mejorar lo que no mides, y no puedes diagnosticar lo que no documentaste."*