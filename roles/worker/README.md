# worker

SeaweedFS workers that run erasure coding (and other maintenance) tasks given out by the admin server.

Main variables: `worker_job_type`, `node_num`, `seaweed_large_disk` (required).

All options with their defaults are in `defaults/main.yml`; see `docs/CONFIGURATION.md` in the collection for the full
reference and `docs/INSTALL.md` for how to run it. The role is meant to be used through the collection's playbooks
(`site`, `rolling_update`, `add_node`, ...).
