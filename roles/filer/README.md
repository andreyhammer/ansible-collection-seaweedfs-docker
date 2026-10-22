# filer

SeaweedFS filer, optionally with the S3 gateway and a PostgreSQL metadata store.

Main variables: `masters_list`, `seaweed_large_disk` (required), `filer_postgres_enabled`, `filer_s3_enabled`.

All options with their defaults are in `defaults/main.yml`; see `docs/CONFIGURATION.md` in the collection for the full
reference and `docs/INSTALL.md` for how to run it. The role is meant to be used through the collection's playbooks
(`site`, `rolling_update`, `add_node`, ...).
