# gnaf_importer

Scripts to load Australian G-NAF PSV data into Microsoft SQL Server and optionally tune tables for analytics (nonclustered PKs + clustered columnstore indexes).

## What's here
- `import_psv_sqlserver.sql` — bulk loads G-NAF PSV files (Standard + Authority Code) into existing tables.
- `convert_pk_to_nonclustered_add_cci.sql` — converts clustered PKs to nonclustered, then adds a clustered columnstore index (CCI) to each table.

## Prerequisites
- Microsoft SQL Server (local or remote).
- A G-NAF data download in PSV format that includes the `Standard` and `Authority Code` folders.
- Tables created in your target database using the official G-NAF table-creation scripts.
- SQLCMD mode enabled (or the `sqlcmd` CLI) so `$(BasePath)` is expanded.
- SQL Server service account access to the file path used for `BasePath`.

## Load the data
1) Create a database (example: `g-naf_2020`).
2) Create tables using the official G-NAF table creation scripts.
3) Run the import script in SQLCMD mode:

```sql
-- In SSMS with SQLCMD mode enabled
:setvar BasePath "C:\\data\\G-NAF NOVEMBER 2025"
```

```bash
# Using sqlcmd
sqlcmd -S . -d "g-naf_2020" -v BasePath="C:\\data\\G-NAF NOVEMBER 2025" -i import_psv_sqlserver.sql
```

## Optional: add columnstore indexes
After loading completes, you can convert clustered PKs to nonclustered and add a CCI to each table:

```bash
sqlcmd -S . -d "g-naf_2020" -i convert_pk_to_nonclustered_add_cci.sql
```

## Notes
- `import_psv_sqlserver.sql` does not truncate tables; re-running it will duplicate data unless you clear tables first.
- The import script assumes CRLF line endings (`ROWTERMINATOR = 0x0d0a`). Adjust if your files use a different line ending.
- The scripts target `USE [g-naf_2020];` by default; update if your database name differs.
- G-NAF data files are not included unless you have added them locally.

## License
G-NAF data and scripts are subject to their respective licenses. Ensure you comply with the terms from your data source.
