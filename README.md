# 🛠️ Admin-T-SQL

Colección de scripts de administración, procedimientos y utilidades para **SQL Server**, escritos en T-SQL.

Cada utilidad se organiza en su propia carpeta, que contiene el script de creación y un documento detallando su uso, parámetros e interpretación de resultados.

---

## 📌 Objetivo

Centralizar herramientas reutilizables para tareas habituales de administración, monitorización y diagnóstico de instancias SQL Server, con documentación suficiente para que cualquier DBA pueda usarlas sin necesidad de conocer su implementación interna.

---

## 📁 Contenido

| Carpeta | Descripción |
|---|---|
| [`Query Resource History`](./QueryResourceHistory/README.md) | Stored procedure para análisis histórico de consumo de recursos (CPU, lecturas, escrituras, memoria y tiempo de respuesta) a partir de la caché de planes de ejecución. Permite filtrar por base de datos e intervalo de tiempo, y ordenar por cualquier métrica de salida. |
| [`Baseline SQL Server`](./ServerBaseline/README.md) | Una baseline es una fotografía del estado normal y saludable de tu servidor SQL Server y sus bases de datos. Sirve como punto de referencia para detectar degradaciones de rendimiento, planificar capacidad y diagnosticar incidencias. Sin ella, es imposible saber si algo ha empeorado o cuánto. |
| [`SQL Server Backups`](./Backups/README.md) | Guía de referencia que compara las opciones de backup disponibles en el asistente gráfico de SSMS con su equivalente en T-SQL. Al final se incluye la recomendación de validación con **dbatools** y el uso de los scripts de Ola Hallengren. |
| [`Oldest Active Trans`](./OldestActiveTransactions/README.md) | Script de diagnóstico para identificar las 10 transacciones activas más antiguas en la instancia, incluyendo todas las bases de datos y tanto sesiones activas como sesiones en estado idle que mantienen una transacción abierta. |
| [`Log File Info`](./LogFileInfo/README.md) | Script de diagnóstico que recopila información general y de espacio de los ficheros de log (.ldf) de todas las bases de datos en línea de la instancia, incluyendo el espacio libre real calculado dinámicamente. |
| [`Get Chain Log`](./GetChainLog/README.md) | Script que determina la cadena completa de backups necesaria para restaurar una base de datos a un momento exacto, consultando el historial almacenado en msdb. Devuelve el FULL, el DIFFERENTIAL (si existe) y todos los LOG backups necesarios. |

---

## 🧾 Licencia y Aviso Legal

Estos scripts son de dominio público, siéntete libre de:

- Usarlos en tu propio trabajo o proyectos
- Modificarlos para adaptarlos a tus necesidades
- Compartirlos con otros

> ⚠️ **Úsalos bajo tu propia responsabilidad.**
> Estos scripts se proporcionan "tal cual", sin ningún tipo de garantía. Pruébalos siempre en entornos locales o de desarrollo antes de ejecutarlos en producción.

---

## 📬 Feedback y Sugerencias

Si encuentras algún error o quieres proponer una mejora, puedes:

- Abrir un *issue*
- Enviar un *pull request*

Gracias por visitar mi repositorio.

---

> 📅 Repositorio en construcción — se irán añadiendo utilidades de forma progresiva.