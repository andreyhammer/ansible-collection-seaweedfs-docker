# common

Pre-flight checks for every node: Docker and the `docker compose` plugin are present, the data mounts exist, and the per-node Compose project file (`<docker_compose_dir>/compose.yaml`) lists every container the collection manages. It also holds the image-variant guard shared by the other roles. It installs nothing and changes no kernel parameters.

Main variables: `seaweed_large_disk` (required, no default), `seaweed_version`, `docker_compose_dir`, `compose_project_name`.

All options with their defaults are in `defaults/main.yml`; see `docs/CONFIGURATION.md` in the collection for the full
reference and `docs/INSTALL.md` for how to run it. The role is meant to be used through the collection's playbooks
(`site`, `rolling_update`, `add_node`, ...).
