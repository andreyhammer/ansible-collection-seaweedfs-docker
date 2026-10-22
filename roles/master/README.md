# master

SeaweedFS master servers (raft). One container per inventory alias; an odd number of masters is required.

Main variables: `masters_list` (required, `IP:PORT` for every master), `seaweed_large_disk` (required), `seaweed_version`, `master_default_replication`.

All options with their defaults are in `defaults/main.yml`; see `docs/CONFIGURATION.md` in the collection for the full
reference and `docs/INSTALL.md` for how to run it. The role is meant to be used through the collection's playbooks
(`site`, `rolling_update`, `add_node`, ...).
