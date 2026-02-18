# 🔍 usp_QueryResourceHistory

Stored procedure para **análisis histórico de consumo de recursos en SQL Server**, basado en la caché de planes de ejecución. Permite identificar las queries que más impacto han tenido sobre el servidor en un intervalo de tiempo dado.

---

## 📋 Requisitos

- SQL Server 2016 o superior
- Permisos: `VIEW SERVER STATE` sobre la instancia
- Esquema destino: `dbo` (modificable según convención del entorno)

---

## ⚙️ Parámetros

Todos los parámetros son **opcionales**. Si no se indica ninguno, el SP devuelve las queries ejecutadas en la **última hora**, ordenadas por mayor consumo de CPU acumulado.

| Parámetro | Tipo | Por defecto | Descripción |
|---|---|---|---|
| `@database_name` | `NVARCHAR(128)` | `NULL` | Filtra por nombre de base de datos. Si es `NULL`, devuelve todas. |
| `@date_from` | `DATETIME` | Hace 1 hora | Inicio del intervalo de análisis. |
| `@date_to` | `DATETIME` | Momento actual | Fin del intervalo de análisis. |
| `@order_by` | `NVARCHAR(128)` | `total_worker_time DESC` | Campo por el que ordenar el resultado (ver lista de valores válidos más abajo). |

### Valores válidos para `@order_by`

```
execution_count       plan_cached_at        avg_grant_kb
total_cpu_ms          last_execution_time   last_cpu_ms 
total_logical_reads   avg_cpu_ms            max_cpu_ms
total_physical_reads  avg_logical_reads     max_logical_reads
total_logical_writes  avg_physical_reads    max_elapsed_ms
total_elapsed_ms      avg_logical_writes    max_grant_kb
total_grant_kb        avg_elapsed_ms
```

> ⚠️ Si se indica un valor no incluido en la lista anterior, el SP lanzará un error controlado y no ejecutará la consulta.

---

## 🚀 Ejemplos de uso

```sql
-- Sin filtros: última hora, orden por defecto (mayor CPU acumulada primero)
EXEC dbo.usp_QueryResourceHistory;

-- Filtrar por base de datos
EXEC dbo.usp_QueryResourceHistory
    @database_name = 'MiBaseDeDatos';

-- Rango de fechas concreto
EXEC dbo.usp_QueryResourceHistory
    @date_from = '2026-02-17 07:00',
    @date_to   = '2026-02-18 07:00';

-- Ordenar por tiempo medio de respuesta
EXEC dbo.usp_QueryResourceHistory
    @order_by = 'avg_elapsed_ms';

-- Combinación completa
EXEC dbo.usp_QueryResourceHistory
    @database_name = 'MiBaseDeDatos',
    @date_from     = '2026-02-17 08:00',
    @date_to       = '2026-02-18 08:00',
    @order_by      = 'avg_cpu_ms';
```

---

## 📊 Interpretación de campos

### Identificación

| Campo | Descripción |
|---|---|
| `execution_count` | Número de veces que el plan fue ejecutado desde que entró en caché. Un valor muy alto puede indicar una query frecuente que conviene optimizar aunque su coste unitario sea bajo. |
| `last_execution_time` | Última vez que se ejecutó. Útil para confirmar que la query sigue activa y no es un residuo antiguo en caché. |
| `database_name` | Base de datos sobre la que se compiló el plan, extraída de los atributos del plan (`dm_exec_plan_attributes`). Más fiable que `DB_NAME()` sobre el texto de la query. |
| `object_name` | Nombre del objeto (stored procedure, función, trigger) al que pertenece la query. `NULL` si es un batch ad-hoc. |
| `plan_cached_at` | Momento en que el plan entró en caché. Si es muy reciente puede indicar que el plan fue recompilado, lo cual tiene coste. |

---

### CPU

| Campo | Descripción | Cuándo preocuparse |
|---|---|---|
| `total_cpu_ms` | CPU acumulada de todas las ejecuciones. Principal indicador de impacto global sobre el servidor. | Valores altos respecto al resto de queries. |
| `avg_cpu_ms` | CPU media por ejecución. Refleja el coste unitario real. | > 1.000 ms en queries OLTP; > 10.000 ms en batch. |
| `last_cpu_ms` | CPU de la última ejecución. | Divergencia alta respecto a `avg_cpu_ms` puede indicar variación en el volumen de datos. |
| `max_cpu_ms` | Peor ejecución registrada en caché. | Útil para detectar picos puntuales. |

---

### Lecturas

| Campo | Descripción | Cuándo preocuparse |
|---|---|---|
| `total_logical_reads` | Total de páginas leídas desde el buffer pool. El indicador más representativo del trabajo realizado por el motor. | Proporcional a la carga; comparar entre queries. |
| `avg_logical_reads` | Media de páginas leídas por ejecución. | > 1.000 en OLTP suele indicar falta de índice o plan subóptimo. |
| `max_logical_reads` | Peor caso de lecturas lógicas. | — |
| `total_physical_reads` | Páginas leídas desde disco (no estaban en buffer). | Cualquier valor relevante indica presión de memoria o datos fríos. |
| `avg_physical_reads` | Media de lecturas físicas por ejecución. | Idealmente debe tender a 0 en queries frecuentes. |

---

### Escrituras

| Campo | Descripción | Cuándo preocuparse |
|---|---|---|
| `total_logical_writes` | Total de páginas modificadas (INSERT, UPDATE, DELETE, operaciones de trabajo en tempdb). | Valores altos en queries de lectura pueden indicar uso intensivo de tempdb (sorts, spools). |
| `avg_logical_writes` | Media de escrituras por ejecución. | — |

---

### Tiempo de respuesta (Elapsed Time)

| Campo | Descripción | Cuándo preocuparse |
|---|---|---|
| `total_elapsed_ms` | Tiempo de reloj total acumulado. Incluye esperas (I/O, locks, etc.), a diferencia de `cpu_time`. | — |
| `avg_elapsed_ms` | Tiempo medio de respuesta percibido por el cliente. | El más relevante desde la perspectiva del usuario final. |
| `max_elapsed_ms` | Peor tiempo de respuesta registrado. | Divergencia alta vs `avg_elapsed_ms` apunta a bloqueos o contención puntual. |

> 💡 **`avg_elapsed_ms` >> `avg_cpu_ms`** indica que la query pasa mucho tiempo esperando (locks, I/O, red). Revisar `wait_stats` en esos momentos.

---

### Memoria (Memory Grants)

| Campo | Descripción | Cuándo preocuparse |
|---|---|---|
| `total_grant_kb` | Memoria total concedida a todas las ejecuciones. | — |
| `avg_grant_kb` | Memoria media reservada por ejecución por el optimizador. | Valores altos indican queries con ordenaciones, agregaciones o joins en memoria. |
| `max_grant_kb` | Mayor reserva puntual realizada. | Si es muy superior a `avg_grant_kb`, hay alta variabilidad en los datos procesados. |

---

### Texto y plan

| Campo | Descripción |
|---|---|
| `statement_text` | Extracto exacto del statement dentro del batch que fue ejecutado. Más preciso que `full_query_text` para localizar el problema. |
| `full_query_text` | Texto completo del batch o procedimiento. |
| `query_plan` | Plan de ejecución en XML. En SSMS, al hacer clic sobre el valor se abre el **plan gráfico interactivo**, donde se pueden identificar operadores costosos, *missing indexes*, estimaciones incorrectas de filas, etc. |
| `plan_handle` | Referencia interna al plan en caché. Permite consultas adicionales sobre `dm_exec_query_plan`. |
| `sql_handle` | Referencia al texto SQL en caché. |

---

## ⚠️ Limitaciones y consideraciones

**Dependencia de la caché de planes.** El SP trabaja sobre `sys.dm_exec_query_stats`, que solo contiene planes actualmente en caché. Si SQL Server sufrió presión de memoria y expulsó planes, esas queries no aparecerán en los resultados. Para histórico persistente se recomienda activar **Query Store**.

**Fechas en UTC.** `last_execution_time` en las DMVs de SQL Server se almacena en **UTC**. Si el servidor tiene zona horaria distinta a UTC, los parámetros `@date_from` y `@date_to` deben pasarse también en UTC, o ajustar el SP para hacer la conversión internamente.

**`object_name` puede ser NULL.** Para queries ad-hoc o batches sin objeto asociado este campo no se puede resolver.

**Ordenación siempre descendente.** El SP ordena el campo indicado en `@order_by` siempre de mayor a menor, priorizando los casos de mayor impacto.

---

## 🔗 Vistas del sistema utilizadas

| Vista | Propósito |
|---|---|
| `sys.dm_exec_query_stats` | Estadísticas acumuladas por plan cacheado |
| `sys.dm_exec_sql_text` | Texto de la query asociada al `sql_handle` |
| `sys.dm_exec_query_plan` | Plan de ejecución XML asociado al `plan_handle` |
| `sys.dm_exec_plan_attributes` | Atributos de compilación del plan (incluye `dbid`) |
