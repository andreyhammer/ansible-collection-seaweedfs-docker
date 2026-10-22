# admin

SeaweedFS admin server (web UI and task scheduling for the erasure coding workers).

Main variables: `masters_list`, `seaweed_large_disk` (required), `SEAWEED_ADMIN_PASSWORD` in the controller environment.

All options with their defaults are in `defaults/main.yml`; see `docs/CONFIGURATION.md` in the collection for the full
reference and `docs/INSTALL.md` for how to run it. The role is meant to be used through the collection's playbooks
(`site`, `rolling_update`, `add_node`, ...).
