DROP PROCEDURE IF EXISTS dbo.usp_QueryResourceHistory
GO

CREATE PROCEDURE dbo.usp_QueryResourceHistory
    @database_name  NVARCHAR(128) = NULL,
    @date_from      DATETIME      = NULL,
    @date_to        DATETIME      = NULL,
    @order_by       NVARCHAR(128) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- Valores por defecto si no se pasan fechas
    SET @date_from = ISNULL(@date_from, DATEADD(HOUR, -1, GETDATE()));
    SET @date_to   = ISNULL(@date_to,   GETDATE());

    print @date_from
    print @date_to

    -- Validación del campo de ordenación contra un whitelist para evitar SQL injection
    IF @order_by IS NOT NULL AND @order_by NOT IN (
        'execution_count', 'last_execution_time',
        'total_cpu_ms', 'avg_cpu_ms', 'last_cpu_ms', 'max_cpu_ms',
        'total_logical_reads', 'avg_logical_reads', 'max_logical_reads',
        'total_physical_reads', 'avg_physical_reads',
        'total_logical_writes', 'avg_logical_writes',
        'total_elapsed_ms', 'avg_elapsed_ms', 'max_elapsed_ms',
        'total_grant_kb', 'avg_grant_kb', 'max_grant_kb',
        'plan_cached_at'
    )
    BEGIN
        RAISERROR('El campo de ordenación indicado no es válido.', 16, 1);
        RETURN;
    END

    DECLARE @sql NVARCHAR(MAX);

    SET @sql = N'
    SELECT
        qs.execution_count,
        qs.last_execution_time,

        DB_NAME(TRY_CAST(pa.value AS INT))                              AS database_name,
        OBJECT_NAME(qt.objectid, qt.dbid)                               AS object_name,

        qs.total_worker_time / 1000                                     AS total_cpu_ms,
        qs.total_worker_time / qs.execution_count / 1000                AS avg_cpu_ms,
        qs.last_worker_time  / 1000                                     AS last_cpu_ms,
        qs.max_worker_time   / 1000                                     AS max_cpu_ms,

        qs.total_logical_reads,
        qs.total_logical_reads / qs.execution_count                     AS avg_logical_reads,
        qs.max_logical_reads,

        qs.total_physical_reads,
        qs.total_physical_reads / qs.execution_count                    AS avg_physical_reads,

        qs.total_logical_writes,
        qs.total_logical_writes / qs.execution_count                    AS avg_logical_writes,

        qs.total_elapsed_time / 1000                                    AS total_elapsed_ms,
        qs.total_elapsed_time / qs.execution_count / 1000               AS avg_elapsed_ms,
        qs.max_elapsed_time   / 1000                                    AS max_elapsed_ms,

        qs.total_grant_kb,
        qs.total_grant_kb / qs.execution_count                          AS avg_grant_kb,
        qs.max_grant_kb,

        SUBSTRING(
            qt.text,
            (qs.statement_start_offset / 2) + 1,
            (CASE qs.statement_end_offset
                WHEN -1 THEN DATALENGTH(qt.text)
                ELSE qs.statement_end_offset
             END - qs.statement_start_offset) / 2 + 1
        )                                                               AS statement_text,
        qt.text                                                         AS full_query_text,

        qp.query_plan,
        qs.plan_handle,
        qs.sql_handle,
        qs.creation_time                                                AS plan_cached_at

    FROM sys.dm_exec_query_stats qs
    CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle)    qt
    CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) qp
    CROSS APPLY sys.dm_exec_plan_attributes(qs.plan_handle) pa

    WHERE
        qs.last_execution_time BETWEEN @date_from AND @date_to
        AND qt.text NOT LIKE ''%dm_exec_query_stats%''
        AND pa.attribute = ''dbid''
    ';

    -- Filtro opcional de base de datos
    IF @database_name IS NOT NULL
        SET @sql = @sql + N'
        AND DB_NAME(TRY_CAST(pa.value AS INT)) = @database_name
        ';

    -- Ordenación: por defecto total_worker_time DESC si no se indica nada
    IF @order_by IS NULL
        SET @sql = @sql + N'
        ORDER BY qs.total_worker_time DESC, qs.total_logical_reads DESC, qs.total_grant_kb DESC;
        ';
    ELSE
        SET @sql = @sql + N'
        ORDER BY ' + @order_by + N' DESC;
        ';

    EXEC sp_executesql
        @sql,
        N'@date_from DATETIME, @date_to DATETIME, @database_name NVARCHAR(128)',
        @date_from      = @date_from,
        @date_to        = @date_to,
        @database_name  = @database_name;

END
GO
