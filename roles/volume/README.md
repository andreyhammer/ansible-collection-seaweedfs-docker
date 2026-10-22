# volume

SeaweedFS volume servers: one container per disk group, with its own data directories, port (`8080` + group number) and optional index directory. Checks after every start that the server is registered and that its erasure coding shards came back.

Main variables: `volume_data_dirs`, `volume_dg`, `volume_node_num`, `volume_rack`, `volume_index_dir`, `volume_pre_stop_seconds`, `seaweed_large_disk` (required).

All options with their defaults are in `defaults/main.yml`; see `docs/CONFIGURATION.md` in the collection for the full
reference and `docs/INSTALL.md` for how to run it. The role is meant to be used through the collection's playbooks
(`site`, `rolling_update`, `add_node`, ...).
