# 🔒 Transacciones Activas Más Antiguas

Script de diagnóstico para identificar las **10 transacciones activas más antiguas** en la instancia, incluyendo todas las bases de datos y tanto sesiones activas como sesiones en estado *idle* que mantienen una transacción abierta.

> ⚠️ Debe ejecutarse en el contexto de **master** para tener visibilidad sobre todas las bases de datos de la instancia.

---

## ¿Por qué es importante?

Las transacciones de larga duración son una de las causas más habituales de problemas en SQL Server:

- **Bloquean** a otras sesiones que necesitan acceder a los mismos recursos
- **Impiden la reutilización del log de transacciones**, provocando crecimiento descontrolado del fichero `.ldf`
- **Degradan el rendimiento general** del servidor al mantener locks durante periodos prolongados
- En entornos con **Always On** o **replicación**, pueden generar lag en las réplicas secundarias

---

## Script

```sql
USE master;

use master
--use test

SELECT TOP 10 
	 s.session_id AS [Session ID]
	,DB_NAME(t.database_id) as [DB]
	,e.login_name AS [Login Name]
	,e.host_name AS [Host Name]
	,c.client_net_address [Client IP]
	,e.program_name AS [Program Name]
	,e.login_time AS [Login Time]
	,t.database_transaction_begin_time AS [Transaction Begin Time]
	,DATEDIFF(SECOND, t.database_transaction_begin_time, GETDATE()) AS [Open Seconds]
	,t.database_transaction_log_record_count AS [Log Record Count]
	,t.database_transaction_log_bytes_used AS [Log Bytes Used]
	,t.database_transaction_log_bytes_reserved AS [Log Bytes Reserved]
	,st.text AS [Most Recent SQL Text]
	,qp.query_plan AS [Query Plan]
FROM
	sys.dm_tran_database_transactions t 
		INNER JOIN
	sys.dm_tran_session_transactions s ON t.transaction_id = s.transaction_id 
		INNER JOIN
	sys.dm_exec_sessions e ON s.session_id = e.session_id 
		LEFT JOIN										-- INNER JOIN para excluir sesiones idle sin request activa
	sys.dm_exec_requests r ON e.session_id = r.session_id 
		INNER JOIN
	sys.dm_exec_connections c ON e.session_id = c.session_id 
		CROSS APPLY  
	sys.dm_exec_sql_text(c.most_recent_sql_handle) AS st 
		OUTER APPLY										-- CROSS APPLY para excluir sesiones idle sin request activa
	sys.dm_exec_query_plan(r.plan_handle) AS qp
ORDER BY
	[Transaction Begin Time];
```

---

## Decisiones de diseño — Por qué cada JOIN es como es

La combinación de tipos de join no es arbitraria — cada una responde a un caso concreto:

| Join | Vista | Tipo | Motivo |
|---|---|:---:|---|
| `dm_tran_session_transactions` | Enlace transacción → sesión | `INNER` | Toda transacción debe tener sesión asociada |
| `dm_exec_sessions` | Datos de la sesión | `INNER` | Toda transacción debe tener sesión asociada |
| `dm_exec_requests` | Request activa | `LEFT` | Las sesiones idle no tienen request activa — un `INNER` las excluiría |
| `dm_exec_connections` | Conexión física | `INNER` | Toda sesión activa tiene conexión — proporciona `most_recent_sql_handle` y `client_net_address` |
| `dm_exec_sql_text` | Texto SQL | `CROSS APPLY` | `most_recent_sql_handle` siempre disponible en la conexión, aunque la sesión esté idle |
| `dm_exec_query_plan` | Plan de ejecución | `OUTER APPLY` | `r.plan_handle` es NULL en sesiones idle — un `CROSS APPLY` las excluiría |

Una sesión **idle** (`status = 'sleeping'`) no está ejecutando nada en este momento pero tiene una transacción abierta sin `COMMIT` ni `ROLLBACK`. Es el escenario más peligroso porque no hay actividad visible que llame la atención, pero el daño (locks retenidos, log sin poder reutilizarse) es exactamente el mismo que en una transacción activa. Para estas sesiones `Query Plan` será `NULL`, pero `Most Recent SQL Text` sigue disponible a través de `most_recent_sql_handle` en `dm_exec_connections` y es la pista más útil para identificar la causa.

---

## Interpretación de campos

| Campo | Descripción | Cuándo preocuparse |
|---|---|---|
| `Session ID` | Identificador de la sesión — útil para `KILL` si fuera necesario | |
| `DB` | Base de datos sobre la que opera la transacción | |
| `Login Name` | Login de SQL Server o Windows que abrió la sesión | |
| `Host Name` | Nombre del equipo cliente | |
| `Client IP` | Dirección IP del cliente — útil para localizar el origen de la conexión | |
| `Program Name` | Aplicación que abrió la conexión | Útil para identificar el sistema o proceso causante |
| `Login Time` | Momento en que se estableció la sesión | |
| `Transaction Begin Time` | Momento en que se abrió la transacción | Cuanto más antiguo, mayor el riesgo |
| `Open Seconds` | Segundos transcurridos desde que se abrió la transacción | > 30s en OLTP merece revisión; > 300s es una alerta seria |
| `Log Record Count` | Número de entradas generadas en el log por esta transacción | |
| `Log Bytes Used` | Espacio de log consumido actualmente | |
| `Log Bytes Reserved` | Espacio de log reservado para el posible rollback | Valores altos indican que un rollback sería costoso |
| `Most Recent SQL Text` | Último statement ejecutado en la conexión | En sesiones idle es la pista principal para identificar la causa |
| `Query Plan` | Plan de ejecución XML — clickable en SSMS | `NULL` en sesiones idle |

---

## Vistas del sistema utilizadas

| Vista | Propósito |
|---|---|
| `sys.dm_tran_database_transactions` | Transacciones activas a nivel de base de datos con métricas de log |
| `sys.dm_tran_session_transactions` | Relación entre transacciones y sesiones |
| `sys.dm_exec_sessions` | Información de cada sesión: login, host, programa, estado |
| `sys.dm_exec_connections` | Conexión física — proporciona `most_recent_sql_handle` y `client_net_address` |
| `sys.dm_exec_requests` | Request activa en la sesión — `NULL` si la sesión está idle |
| `sys.dm_exec_sql_text` | Texto SQL a partir de un handle |
| `sys.dm_exec_query_plan` | Plan de ejecución XML a partir de un plan handle |
