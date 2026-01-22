-- Convert clustered PKs to NONCLUSTERED and add clustered columnstore indexes.
-- Foreign keys are dropped and recreated to preserve constraints.

USE [g-naf_2020];
GO
SET NOCOUNT ON;
GO

DECLARE @fk_drop nvarchar(max) = N'';
DECLARE @fk_create nvarchar(max) = N'';
DECLARE @fk_post nvarchar(max) = N'';

;WITH fk AS (
    SELECT
        fk.object_id,
        fk.name AS constraint_name,
        fk.parent_object_id,
        fk.referenced_object_id,
        fk.delete_referential_action,
        fk.update_referential_action,
        fk.is_not_for_replication,
        fk.is_disabled,
        fk.is_not_trusted,
        ps.name AS parent_schema,
        pt.name AS parent_table,
        rs.name AS ref_schema,
        rt.name AS ref_table
    FROM sys.foreign_keys fk
    JOIN sys.tables pt ON fk.parent_object_id = pt.object_id
    JOIN sys.schemas ps ON pt.schema_id = ps.schema_id
    JOIN sys.tables rt ON fk.referenced_object_id = rt.object_id
    JOIN sys.schemas rs ON rt.schema_id = rs.schema_id
    WHERE fk.is_ms_shipped = 0
)
SELECT
    @fk_drop = @fk_drop +
        N'ALTER TABLE ' + QUOTENAME(parent_schema) + N'.' + QUOTENAME(parent_table) +
        N' DROP CONSTRAINT ' + QUOTENAME(constraint_name) + N';' + CHAR(13) + CHAR(10),
    @fk_create = @fk_create +
        N'ALTER TABLE ' + QUOTENAME(parent_schema) + N'.' + QUOTENAME(parent_table) +
        N' WITH ' + CASE WHEN is_not_trusted = 1 OR is_disabled = 1 THEN N'NOCHECK' ELSE N'CHECK' END +
        N' ADD CONSTRAINT ' + QUOTENAME(constraint_name) + N' FOREIGN KEY (' +
            STUFF((
                SELECT N', ' + QUOTENAME(pc.name)
                FROM sys.foreign_key_columns fkc
                JOIN sys.columns pc ON fkc.parent_object_id = pc.object_id
                    AND fkc.parent_column_id = pc.column_id
                WHERE fkc.constraint_object_id = fk.object_id
                ORDER BY fkc.constraint_column_id
                FOR XML PATH(''), TYPE
            ).value('.', 'nvarchar(max)'), 1, 2, N'') +
        N') REFERENCES ' + QUOTENAME(ref_schema) + N'.' + QUOTENAME(ref_table) + N' (' +
            STUFF((
                SELECT N', ' + QUOTENAME(rc.name)
                FROM sys.foreign_key_columns fkc
                JOIN sys.columns rc ON fkc.referenced_object_id = rc.object_id
                    AND fkc.referenced_column_id = rc.column_id
                WHERE fkc.constraint_object_id = fk.object_id
                ORDER BY fkc.constraint_column_id
                FOR XML PATH(''), TYPE
            ).value('.', 'nvarchar(max)'), 1, 2, N'') +
        N')' +
        CASE WHEN is_not_for_replication = 1 THEN N' NOT FOR REPLICATION' ELSE N'' END +
        CASE delete_referential_action
            WHEN 1 THEN N' ON DELETE CASCADE'
            WHEN 2 THEN N' ON DELETE SET NULL'
            WHEN 3 THEN N' ON DELETE SET DEFAULT'
            ELSE N''
        END +
        CASE update_referential_action
            WHEN 1 THEN N' ON UPDATE CASCADE'
            WHEN 2 THEN N' ON UPDATE SET NULL'
            WHEN 3 THEN N' ON UPDATE SET DEFAULT'
            ELSE N''
        END +
        N';' + CHAR(13) + CHAR(10),
    @fk_post = @fk_post +
        CASE
            WHEN is_disabled = 1 THEN
                N'ALTER TABLE ' + QUOTENAME(parent_schema) + N'.' + QUOTENAME(parent_table) +
                N' NOCHECK CONSTRAINT ' + QUOTENAME(constraint_name) + N';' + CHAR(13) + CHAR(10)
            WHEN is_not_trusted = 0 THEN
                N'ALTER TABLE ' + QUOTENAME(parent_schema) + N'.' + QUOTENAME(parent_table) +
                N' CHECK CONSTRAINT ' + QUOTENAME(constraint_name) + N';' + CHAR(13) + CHAR(10)
            ELSE N''
        END
FROM fk;

IF @fk_drop <> N''
BEGIN
    PRINT 'Dropping foreign keys...';
    EXEC sp_executesql @fk_drop;
END

DECLARE @sql nvarchar(max) = N'';

;WITH pk AS (
    SELECT
        t.object_id,
        s.name AS schema_name,
        t.name AS table_name,
        kc.name AS constraint_name,
        i.index_id
    FROM sys.key_constraints kc
    JOIN sys.tables t ON kc.parent_object_id = t.object_id
    JOIN sys.schemas s ON t.schema_id = s.schema_id
    JOIN sys.indexes i ON kc.parent_object_id = i.object_id
        AND kc.unique_index_id = i.index_id
    WHERE kc.type = 'PK'
      AND i.type = 1 -- clustered
)
SELECT @sql = @sql +
    N'PRINT ''Converting PK on ' + REPLACE(schema_name + N'.' + table_name, '''', '''''') + N''';' + CHAR(13) + CHAR(10) +
    N'ALTER TABLE ' + QUOTENAME(schema_name) + N'.' + QUOTENAME(table_name) +
    N' DROP CONSTRAINT ' + QUOTENAME(constraint_name) + N';' + CHAR(13) + CHAR(10) +
    N'ALTER TABLE ' + QUOTENAME(schema_name) + N'.' + QUOTENAME(table_name) +
    N' ADD CONSTRAINT ' + QUOTENAME(constraint_name) +
    N' PRIMARY KEY NONCLUSTERED (' +
        STUFF((
            SELECT N', ' + QUOTENAME(c.name) + CASE WHEN ic.is_descending_key = 1 THEN N' DESC' ELSE N' ASC' END
            FROM sys.index_columns ic
            JOIN sys.columns c ON ic.object_id = c.object_id
                AND ic.column_id = c.column_id
            WHERE ic.object_id = pk.object_id
              AND ic.index_id = pk.index_id
              AND ic.is_included_column = 0
            ORDER BY ic.key_ordinal
            FOR XML PATH(''), TYPE
        ).value('.', 'nvarchar(max)'), 1, 2, N'') +
    N');' + CHAR(13) + CHAR(10) + CHAR(13) + CHAR(10)
FROM pk;

IF @sql <> N''
BEGIN
    EXEC sp_executesql @sql;
END

DECLARE @sql2 nvarchar(max) = N'';

;WITH tbl AS (
    SELECT s.name AS schema_name, t.name AS table_name, t.object_id
    FROM sys.tables t
    JOIN sys.schemas s ON t.schema_id = s.schema_id
    WHERE t.is_ms_shipped = 0
)
SELECT @sql2 = @sql2 +
    N'IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = ' + CAST(object_id AS nvarchar(20)) + N' AND type = 5)' + CHAR(13) + CHAR(10) +
    N'BEGIN' + CHAR(13) + CHAR(10) +
    N'    PRINT ''Creating CCI on ' + REPLACE(schema_name + N'.' + table_name, '''', '''''') + N''';' + CHAR(13) + CHAR(10) +
    N'    CREATE CLUSTERED COLUMNSTORE INDEX ' + QUOTENAME(N'CCI_' + table_name) + N' ON ' +
        QUOTENAME(schema_name) + N'.' + QUOTENAME(table_name) + N';' + CHAR(13) + CHAR(10) +
    N'END' + CHAR(13) + CHAR(10) + CHAR(13) + CHAR(10)
FROM tbl;

IF @sql2 <> N''
BEGIN
    EXEC sp_executesql @sql2;
END

IF @fk_create <> N''
BEGIN
    PRINT 'Recreating foreign keys...';
    EXEC sp_executesql @fk_create;
END

IF @fk_post <> N''
BEGIN
    EXEC sp_executesql @fk_post;
END
GO
