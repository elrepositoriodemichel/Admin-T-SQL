# 🛠️ Admin-T-SQL

Colección de scripts de administración y utilidades para **SQL Server**, escritos en T-SQL.

Cada utilidad se organiza en su propia carpeta, que contiene el script de creación y un documento detallando su uso, parámetros e interpretación de resultados.

---

## 📌 Objetivo

Centralizar herramientas reutilizables para tareas habituales de administración, monitorización y diagnóstico de instancias SQL Server, con documentación suficiente para que cualquier DBA pueda usarlas sin necesidad de conocer su implementación interna.

---

## 📁 Contenido

| Carpeta | Descripción |
|---|---|
| [`QueryResourceHistory`](./QueryResourceHistory) | Stored procedure para análisis histórico de consumo de recursos (CPU, lecturas, escrituras, memoria y tiempo de respuesta) a partir de la caché de planes de ejecución. Permite filtrar por base de datos e intervalo de tiempo, y ordenar por cualquier métrica de salida. |

---

## 🗂️ Estructura de cada utilidad

```
Admin-T-SQL/
└── NombreUtilidad/
    ├── NombreUtilidad.sql   ← Script de creación (SP, función, vista, etc.)
    └── NombreUtilidad.md    ← Documentación: parámetros, ejemplos e interpretación
```

---

## ⚙️ Notas generales

- **Realizado con SQL Server 2022** salvo que se indique lo contrario en la documentación de cada utilidad
- Permisos mínimos habituales: `VIEW SERVER STATE` para utilidades que consulten DMVs
- Se recomienda revisar el `.md` de cada utilidad antes de ejecutar el script en producción

---

## 🤝 Contribuciones

Si quieres añadir una utilidad, sigue la misma estructura: una carpeta con el script y su `.md` de documentación.

---

> 📅 Repositorio en construcción — se irán añadiendo utilidades de forma progresiva.
