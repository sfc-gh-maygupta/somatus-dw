# Somatus Data Warehouse

Everything that defines the Somatus warehouse, in one repo.

| Folder | What it holds |
|---|---|
| `ddl/` | Databases, schemas, warehouses, stages, pipes, dynamic tables, tasks, alerts |
| `somatus_dbt/` | dbt project, deployed and run inside Snowflake |
| `notebooks/` | Snowflake notebooks for ingestion, pipelines, data quality |
| `.github/workflows/` | CI/CD: deploy to Snowflake on merge to `main` |

**Flow:** branch, change, pull request, review, merge. GitHub Actions deploys to Snowflake.

Synthetic demo data.
