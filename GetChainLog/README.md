# 🔗 Cadena de Restauración a un Punto en el Tiempo

Script que determina la **cadena completa de backups necesaria** para restaurar una base de datos a un momento exacto, consultando el historial almacenado en `msdb`. Devuelve el FULL, el DIFFERENTIAL (si existe) y todos los LOG backups necesarios en el orden exacto en que deben aplicarse, validando la continuidad estricta de la cadena de LSN.

---

## ¿Para qué sirve?

Cuando necesitas hacer un **Point-in-Time Restore** (PITR), SQL Server requiere aplicar los backups en un orden específico sin gaps. Identificar manualmente qué backups usar — especialmente con múltiples ciclos de FULL y DIFF conviviendo en el historial — es propenso a errores. Este script lo determina automáticamente y de forma segura.

---

## Parámetros

```sql
DECLARE @database NVARCHAR(128);
DECLARE @target_datetime DATETIME;

SET @database = '<TuBaseDeDatos>';
SET @target_datetime = '2026-02-26 14:08:01.000';
```

| Parámetro | Descripción |
|---|---|
| `@database` | Nombre de la base de datos a restaurar |
| `@target_datetime` | Momento exacto al que se quiere restaurar — se usará como `STOPAT` en el último `RESTORE LOG` |

---

## Script

```sql
DECLARE @database NVARCHAR(128);
DECLARE @target_datetime DATETIME;

SET @database = '<TuBaseDeDatos>';
SET @target_datetime = '2026-03-04 18:54:32.000';

WITH
-- FULL más reciente anterior a la fecha objetivo
full_backup AS 
    (
        SELECT TOP 1
            'FULL' AS backup_type,
            1 AS apply_order,
            bs.backup_set_id,
            bs.media_set_id,
            bs.backup_start_date,
            bs.backup_finish_date,
            bs.first_lsn,
            bs.last_lsn,
            bs.checkpoint_lsn,
            bs.backup_size,
            bs.compressed_backup_size,
            bs.has_backup_checksums,
            0 AS dummy
        FROM 
            msdb.dbo.backupset bs            
        WHERE 
            bs.database_name = @database
            AND bs.type = 'D'
            AND bs.backup_finish_date <= @target_datetime
        ORDER BY 
            bs.backup_finish_date DESC
    ),
-- DIFF más reciente basado en ese FULL y anterior a la fecha objetivo si existe
diff_backup AS 
    (
        SELECT TOP 1
            'DIFFERENTIAL' AS backup_type,
            2 AS apply_order,
            bs.backup_set_id,
            bs.media_set_id,
            bs.backup_start_date,
            bs.backup_finish_date,
            bs.first_lsn,
            bs.last_lsn,
            bs.checkpoint_lsn,
            bs.backup_size,
            bs.compressed_backup_size,
            bs.has_backup_checksums,
            0 AS dummy
        FROM 
            msdb.dbo.backupset bs
                CROSS JOIN 
            full_backup fb
        WHERE 
            bs.database_name = @database
            AND bs.type = 'I'
            AND bs.backup_finish_date <= @target_datetime
            AND bs.database_backup_lsn = fb.checkpoint_lsn
        ORDER BY 
            bs.backup_finish_date DESC
    ),
-- LSN de inicio de la cadena de logs: last_lsn del DIFF si existe, si no del FULL
start_lsn AS 
    (
        SELECT COALESCE((SELECT last_lsn FROM diff_backup), (SELECT last_lsn FROM full_backup)) AS lsn
    ),
-- Cadena de LOGs validando continuidad estricta de LSN mediante recursión
log_chain AS 
    (
        -- Primer LOG que cubre el punto de inicio
            -- first_lsn <= start_lsn porque el LOG puede solapar ligeramente el DIFF/FULL
            -- last_lsn  >  start_lsn para garantizar que avanza más allá del punto de inicio
        SELECT
            'LOG'AS backup_type,
            3 AS apply_order,
            bs.backup_set_id,
            bs.media_set_id,
            bs.backup_start_date,
            bs.backup_finish_date,
            bs.first_lsn,
            bs.last_lsn,
            bs.checkpoint_lsn,
            bs.backup_size,
            bs.compressed_backup_size,
            bs.has_backup_checksums,
            -- Flag para detener la recursión tras incluir el LOG que contiene el STOPAT
            CASE WHEN bs.backup_finish_date >= @target_datetime THEN 1 ELSE 0 END AS reached_target
        FROM 
            msdb.dbo.backupset bs
                CROSS JOIN 
            start_lsn sl
        WHERE 
            bs.database_name = @database
            AND bs.type = 'L'
            AND bs.first_lsn <= sl.lsn
            AND bs.last_lsn >= sl.lsn

        UNION ALL

        -- Siguiente/s LOG cuyo first_lsn = last_lsn del anterior (continuidad estricta)
        -- La condición lc.reached_target = 0 detiene la recursión una vez considerado el LOG del STOPAT
        SELECT
            'LOG',
            3,
            bs.backup_set_id,
            bs.media_set_id,
            bs.backup_start_date,
            bs.backup_finish_date,
            bs.first_lsn,
            bs.last_lsn,
            bs.checkpoint_lsn,
            bs.backup_size,
            bs.compressed_backup_size,
            bs.has_backup_checksums,
            CASE WHEN bs.backup_finish_date >= @target_datetime THEN 1 ELSE 0 END
        FROM 
            msdb.dbo.backupset bs
                INNER JOIN 
            log_chain lc ON bs.first_lsn = lc.last_lsn   -- Continuidad estricta de LSN
                            AND lc.reached_target = 0    -- Para cuando consideramos el LOG que contiene el STOPAT
        WHERE 
            bs.database_name = @database
            AND bs.type = 'L'
    ),
Src AS
    (
        -- Resultado final
        SELECT * FROM full_backup
          UNION ALL
        SELECT * FROM diff_backup
          UNION ALL
        SELECT * FROM log_chain
    )    
SELECT 
    backup_type AS [Type],
    ROW_NUMBER() OVER (ORDER BY apply_order,backup_start_date) AS [Apply Order],
    backup_set_id AS [Id],
    backup_start_date AS [Start Date],
    backup_finish_date AS [Finish Date],
    first_lsn AS [First LSN],
    last_lsn AS [Last LSN],
    checkpoint_lsn as [Checkpoint LSN],
    CAST(backup_size / 1024.0 / 1024 AS DECIMAL(10,2)) AS [Backup Size (Mb)],
    CAST(compressed_backup_size / 1024.0 / 1024 AS DECIMAL(10,2)) AS [Compressed Size (Mb)],
    has_backup_checksums AS [Has Checksum],
    physical_device_name AS [Files]
FROM 
    Src
        CROSS APPLY
    (   -- Todos los ficheros posibles de "stripe" separados por punto y coma
        SELECT STRING_AGG(mf.physical_device_name, '; ')
               WITHIN GROUP (ORDER BY mf.family_sequence_number)        AS physical_device_name
        FROM msdb.dbo.backupmediafamily mf
        WHERE mf.media_set_id = Src.media_set_id
          AND mf.device_type  IN (2, 9)
    ) mf
ORDER BY 
    apply_order, backup_start_date;
```

---

## Cómo funciona internamente

### Estructura de CTEs

```
full_backup
    └── diff_backup (basado en full_backup.checkpoint_lsn)
            └── start_lsn (last_lsn de DIFF o FULL)
                    └── log_chain (recursiva desde start_lsn)
                            └── Src (UNION ALL de los tres)
```

### `full_backup`

>Localiza el FULL más reciente completado antes de `@target_datetime`. Es el punto de partida obligatorio de cualquier cadena de restauración — siempre hay exactamente uno en el resultado.

### `diff_backup`

>Localiza el DIFF más reciente completado antes del objetivo **y vinculado al FULL concreto** mediante `database_backup_lsn = fb.checkpoint_lsn`. Este filtro es crítico: garantiza que no se mezclan DIFFs de ciclos de backup distintos. Si no existe DIFF, esta CTE devuelve vacío y la cadena de LOGs arranca directamente desde el FULL.

### `start_lsn`

>Materializa en una CTE auxiliar el LSN de inicio de la cadena de logs — `last_lsn` del DIFF si existe, o del FULL si no.

### `log_chain` (recursiva)

>Es el núcleo del script. Funciona en dos partes:

>**Primer LOG:** localiza el primer LOG cuyo rango de LSN cubre el punto de inicio usando `first_lsn <= start_lsn AND last_lsn > start_lsn`.

>**Parte recursiva:** cada iteración añade el siguiente LOG exigiendo `bs.first_lsn = lc.last_lsn` — continuidad estricta. Si en algún punto no existe ningún LOG que cumpla esta condición (gap real en la cadena), la recursión se detiene y el resultado quedará incompleto, lo que es la señal de que la restauración al punto objetivo no es posible con los backups disponibles.

>**`reached_target`:** flag que se activa cuando `backup_finish_date >= @target_datetime`. El LOG que activa este flag es el que contiene el punto `STOPAT` y debe incluirse en el resultado. La condición `lc.reached_target = 0` en el JOIN de la parte recursiva detiene la recursión en el siguiente ciclo, evitando incluir LOGs innecesarios posteriores al objetivo.

---

---

### Soporte para backups con stripe (múltiples ficheros)

Cuando un backup se distribuye en múltiples ficheros (*striped backup*), `backupmediafamily` contiene una fila por cada fichero del mismo `media_set_id`. Sin tratamiento especial, el JOIN estándar multiplicaría las filas del resultado devolviendo una línea por fichero en lugar de una por backup.

La solución es agregar los ficheros en un único campo separado por `;` usando `STRING_AGG` ordenado por `family_sequence_number`, que garantiza que los ficheros aparecen en el orden de stripe correcto — el mismo orden que debe usarse en las instrucciones `RESTORE`.

```sql
CROSS APPLY (
    SELECT STRING_AGG(mf.physical_device_name, '; ')
           WITHIN GROUP (ORDER BY mf.family_sequence_number) AS physical_device_name
    FROM msdb.dbo.backupmediafamily mf
    WHERE mf.media_set_id = Src.media_set_id
      AND mf.device_type  IN (2, 9)
) mf
```

> ⚠️ `STRING_AGG` requiere **SQL Server 2017 o superior**. En versiones anteriores debe sustituirse por `FOR XML PATH`:
> ```sql
> CROSS APPLY (
>     SELECT STUFF(
>         (SELECT '; ' + mf2.physical_device_name
>          FROM msdb.dbo.backupmediafamily mf2
>          WHERE mf2.media_set_id = Src.media_set_id
>            AND mf2.device_type  IN (2, 9)
>          ORDER BY mf2.family_sequence_number
>          FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)')
>     , 1, 2, '') AS physical_device_name
> ) mf
> ```

---

## Por qué la cadena de LOGs es válida aunque existan FULLs intermedios

Un aspecto no obvio del script es que puede incluir LOGs generados **después** de un FULL o DIFF posterior al que usamos como base, y aun así la cadena es correcta. El motivo es que SQL Server valida la aplicabilidad de un LOG **exclusivamente por la continuidad de LSN**, no por los metadatos de qué FULL o DIFF estaba activo cuando se generó.

El campo `database_backup_lsn` de un LOG es simplemente metadato informativo que indica cuál era el último FULL activo en el momento de generarse ese LOG — no afecta a si el LOG puede aplicarse en una cadena de restauración distinta siempre que la continuidad de LSN sea correcta.

---

## Uso del resultado — instrucciones RESTORE

Con el resultado del script, las instrucciones de restauración quedan así:

```sql
-- 1. Restaurar el FULL (siempre con NORECOVERY)
RESTORE DATABASE [<TuBaseDeDatos>]
FROM DISK = '<backup_file del FULL>'
WITH NORECOVERY, STATS = 10;

-- 2. Restaurar el DIFF si existe (con NORECOVERY)
RESTORE DATABASE [<TuBaseDeDatos>]
FROM DISK = '<backup_file del DIFF>'
WITH NORECOVERY, STATS = 10;

-- 3. Aplicar cada LOG en orden con NORECOVERY, excepto el último
RESTORE LOG [<TuBaseDeDatos>]
FROM DISK = '<backup_file LOG 1>'
WITH NORECOVERY, STATS = 10;

-- ...repetir para cada LOG intermedio...

-- 4. Último LOG: usar STOPAT con la fecha objetivo y RECOVERY para dejar la BD en línea
RESTORE LOG [<TuBaseDeDatos>]
FROM DISK = '<backup_file último LOG>'
WITH RECOVERY, STOPAT = '2026-02-26 14:08:01.000';
```

> ⚠️ Todos los pasos intermedios deben usar `NORECOVERY`. Solo el último `RESTORE LOG` usa `RECOVERY` con `STOPAT`. Si se aplica `RECOVERY` antes del último paso la base de datos queda en línea en ese punto y no se pueden aplicar más backups.

---

## Interpretación de campos del resultado

| Campo | Descripción |
|---|---|
| `Type` | Tipo de backup: `FULL`, `DIFFERENTIAL` o `LOG` |
| `Apply Order` | Número de secuencia de aplicación — usar este orden en los `RESTORE` |
| `Id` | `backup_set_id` en `msdb` — referencia interna del backup |
| `Start Date` | Inicio del proceso de backup |
| `Finish Date` | Fin del proceso de backup |
| `First LSN` | Primer Log Sequence Number (LSN) cubierto por este backup |
| `Last LSN` | Último LSN cubierto por este backup |
| `Checkpoint LSN` | LSN del último checkpoint activo en el momento del backup |
| `Backup Size (Mb)` | Tamaño sin comprimir del backup |
| `Compressed Size (Mb)` | Tamaño comprimido real en disco |
| `Has Checksum` | Indica si el backup se realizó con `CHECKSUM` |
| `Files` | Ruta física del fichero de backup a usar en el `RESTORE` |

---

## Requisitos

- Recovery Model `FULL` o `BULK_LOGGED` en el momento en que se generaron los backups de log
- Historial de backups disponible en `msdb` — si se ha purgado el script no devolverá resultados
- Permisos: `VIEW DATABASE STATE` o rol `db_backupoperator` en `msdb`

---

## Vistas del sistema utilizadas

| Vista | Propósito |
|---|---|
| `msdb.dbo.backupset` | Historial de backups con LSNs, fechas y metadatos |
| `msdb.dbo.backupmediafamily` | Ruta física del fichero de backup y tipo de dispositivo |

### Valores de `device_type` en `backupmediafamily`

| Valor | Descripción |
|---|---|
| `2` | Disco — fichero `.bak` / `.trn` local o ruta UNC |
| `5` | Cinta física |
| `7` | Virtual device — soluciones de backup de terceros (Veeam, NetBackup, etc.) |
| `9` | URL — Azure Blob Storage |
| `105` | Permanent backup device (`sp_addumpdevice`) |

El filtro `device_type IN (2, 9)` excluye cintas y dispositivos virtuales de terceros, cuyas entradas en `msdb` referencian ficheros que pudieran ser no accesibles directamente mediante `RESTORE`.

---

## Alternativas nativas y herramientas de la comunidad

SQL Server no dispone de ningún procedimiento almacenado nativo capaz de construir automáticamente la cadena de restauración a un punto en el tiempo consultando el historial de `msdb`. Las únicas herramientas nativas relacionadas con el análisis de backups operan sobre ficheros físicos, no sobre el historial:

- **`RESTORE HEADERONLY`** — devuelve los metadatos de un fichero de backup concreto: tipo, fechas, LSNs, compresión, cifrado, etc. Requiere acceso al fichero físico y no tiene capacidad de construir cadenas ni de consultar `msdb`.
- **`RESTORE FILELISTONLY`** — devuelve los ficheros lógicos de datos y log contenidos en un backup. Útil para preparar un `RESTORE` con `MOVE`, pero sin ninguna lógica de encadenamiento.
- **`RESTORE VERIFYONLY`** — comprueba que un fichero de backup es legible y estructuralmente válido. No valida que los datos sean recuperables ni que la cadena sea completa.

Ninguna de estas opciones consulta `msdb`, ninguna razona sobre LSNs de forma encadenada y ninguna tiene en cuenta el concepto de punto en el tiempo. La construcción de la cadena de restauración ha sido históricamente una tarea manual del DBA.

En el ecosistema de la comunidad, **dbatools** — la librería de PowerShell de referencia para administración de SQL Server — sí resuelve este problema a través de `Get-DbaBackupInformation`:
```powershell
Get-DbaBackupInformation -SqlInstance "<TuServidor>" `
                         -Database "<TuBaseDeDatos>" `
                         -RestoreTime (Get-Date "2026-02-26 14:08:01")
```

Esta función consulta el historial de `msdb`, valida la cadena de LSNs y determina qué backups aplicar para alcanzar el punto objetivo. Puede además encadenarse directamente con `Restore-DbaDatabase` para ejecutar la restauración completa en un único pipeline de PowerShell, generando y ejecutando las instrucciones `RESTORE` en el orden correcto y con el `STOPAT` adecuado.

| | Este script | `Get-DbaBackupInformation` |
|---|---|---|
| Validación estricta de LSN | SI -> Recursiva | SI |
| Resultado en T-SQL puro | SI | NO -> Requiere PowerShell |
| Sin dependencias externas | SI | NO -> Requiere dbatools |
| Genera y ejecuta los `RESTORE` automáticamente | NO | SI |
| Soporta backups en Azure URL | SI | SI |
| Integrable en jobs de SQL Agent | SI | SI -> Con limitaciones (Ver nota Final) |

La principal ventaja de este script frente a `Get-DbaBackupInformation` es precisamente que opera en T-SQL puro, sin dependencias externas y directamente desde cualquier cliente SQL — SSMS, Azure Data Studio o cualquier aplicación con acceso a la instancia. Esto lo hace especialmente útil en entornos donde PowerShell está restringido, donde no es posible instalar módulos externos, o simplemente cuando se necesita una validación rápida de la cadena disponible antes de iniciar un proceso de restauración.

> ⚠️ **Sobre la integración de dbatools en SQL Agent Jobs**
>
> Ejecutar PowerShell desde un job de SQL Agent tiene varias fricciones que hay que resolver explícitamente antes de que funcione de forma fiable:
>
> - **Tipo de paso:** el paso del job debe ser de tipo `PowerShell` o `CmdExec`, no T-SQL, lo que obliga a gestionar ese paso de forma diferente al resto y requiere que la política de seguridad del entorno lo permita.
> - **Ámbito de instalación del módulo:** SQL Agent se ejecuta bajo su propia cuenta de servicio, no bajo el usuario interactivo. Si dbatools se instaló con `Scope CurrentUser` — lo habitual — el módulo no estará disponible para la cuenta del servicio y el job fallará. Es necesario instalarlo con `Scope AllUsers` o configurar el `PSModulePath` explícitamente.
> - **Política de ejecución de PowerShell:** la `ExecutionPolicy` puede bloquear la ejecución de scripts en el contexto del Agent aunque funcione sin problemas en una sesión interactiva. Debe configurarse a nivel de máquina o gestionarse en el propio comando del job.
> - **Gestión de errores:** un paso T-SQL integra de forma nativa con el historial del Agent y el sistema de alertas de SQL Server. Un script de PowerShell requiere capturar y propagar los errores explícitamente para que el Agent los registre y notifique correctamente.
>
> Todo lo anterior es solucionable, pero requiere configuración adicional. Por contraste, este script en T-SQL puro se integra en cualquier job de SQL Agent como un paso estándar sin ninguna de estas consideraciones.
