# Configuration reference

Defaults live in each role's `defaults/main.yml`; set values in `group_vars` or `host_vars`. Variables that the
roles share (`seaweed_*`, `docker_compose_dir`, `container_prefix`, `masters_list`, ...) must be identical for all
hosts, so put them in `group_vars/all.yml`.

## Naming and layout

Container name: `<container_prefix><role><NN>[-<sub><MM>]`, with every number two digits and zero-padded.

| Role | Format | Example |
|---|---|---|
| master / filer / admin | `<role><NN>` | `master01` |
| volume | `volume<NN>-dg<MM>` | `volume01-dg03` |
| worker | `worker<NN>-<job><MM>` | `worker01-ec02` |

With `container_prefix: "seaweed-"`: `seaweed-master01`, `seaweed-volume01-dg03`. Gaps in numbering are fine.

| Artifact | Path |
|---|---|
| Project and compose file | `<docker_compose_dir>/<container_name>/compose.yaml` |
| Volume index dir | `<docker_compose_dir>/index-<container_name>/` |
| Worker working dir | `<docker_compose_dir>/<container_name>/data/` |

Ports: master 9333, filer 8888 (S3 8333 if enabled), admin 23646, volume `8080 + <MM>` (dg01 is 8081).

## Image (all roles)

| Variable | Default | Notes |
|---|---|---|
| `seaweed_large_disk` | none, **required** | `true` or `false`; selects the `_large_disk` tag suffix |
| `seaweed_version` | `latest` | Pin a real version in production |
| `seaweed_image_repo` | `chrislusf/seaweedfs` | Mirror or private registry |
| `seaweed_image` | derived | Overriding it requires a matching `seaweed_large_disk` |
| `seaweed_allow_variant_change` | `false` | See MIGRATION.md before touching it |

## Common

| Variable | Default | Notes |
|---|---|---|
| `docker_compose_dir` | `/opt/seaweed` | Base directory for all projects |
| `container_prefix` | `""` | |
| `health_check_timeout` | `60` | Seconds to wait for ports and cluster registration |
| `common_sysctl` | `vm.swappiness: 10`, `net.core.somaxconn: 4096` | Applied by `common`; set `{}` to leave the kernel alone |
| `common_base_dirs` | `docker_compose_dir`, `/data` | Created on every node |
| `common_min_free_gb` | `10` | Free space required on each volume data dir (needs gathered facts) |
| `common_seaweed_user` | `""` | When set, a system user with this name is created (containers do not use it yet) |

## Master

| Variable | Default | Notes |
|---|---|---|
| `masters_list` | `[]`, **required** | `["10.0.0.11:9333", ...]` |
| `node_num` | required per alias | Node number |
| `master_port` | `9333` | |

The container is started with `-peers` set to the full list, so every master must be in `masters_list`.

## Filer

| Variable | Default | Notes |
|---|---|---|
| `node_num` | required per alias | |
| `filer_port` | `8888` | |
| `filer_s3_enabled` / `filer_s3_port` | `false` / `8333` | Optional S3 gateway |
| `filer_postgres_enabled` | `false` | Metadata store in PostgreSQL, configured through `WEED_POSTGRES2_*` |
| `filer_postgres_host`, `_port`, `_db`, `_user` | `""`, `5432`, `seaweedfs`, `seaweedfs` | |
| `filer_postgres_password` | env `SEAWEED_FILER_POSTGRES_PASSWORD` | `compose.yaml` is written with mode 0600 |

## Admin

| Variable | Default | Notes |
|---|---|---|
| `node_num` | required per alias | |
| `admin_port` | `23646` | |
| `admin_password` | env `SEAWEED_ADMIN_PASSWORD` | When set, the server listens on all interfaces |
| `admin_bind_ip` | `""` | Explicit listen address |
| `admin_allow_insecure_bind` | `false` | Binds the node IP **without authentication**; isolated networks only |

Without a password the admin server listens on loopback only, so workers on other nodes cannot reach it. The role
fails early if the inventory has workers but the admin server would not be reachable.

## Volume

Per alias: `volume_node_num`, `volume_dg`, `volume_data_dirs` (list of mounted directories), optional `volume_rack`
and `volume_disk_type`.

| Variable | Default | Notes |
|---|---|---|
| `volume_disk_type_default` | `hdd` | Used when an alias has no `volume_disk_type` |
| `volume_max_volumes` | `0` | `0` leaves `-max` unset (SeaweedFS derives it from free space) |
| `volume_container_uid` / `_gid` | `1000` / `1000` | Owner of the data and index directories on the host, matching the image's `seaweed` user |
| `volume_index_dir_pattern` | `<docker_compose_dir>/index-<container_name>` | Index directory on the host |

The data directories are mounted as `/data/disk1`, `/data/disk2`, ... and the index directory as `/cache`.

## Worker

Per alias: `worker_node_num`, `worker_job_suffix`, `worker_job_index`, `worker_job_type`.

| Variable | Default | Notes |
|---|---|---|
| `worker_jobs` | see below | Valid suffixes, their job types and instances per node; used to validate aliases |
| `worker_admin_address` | first `admin` host, port 23646 | |
| `worker_max_execute` | `1` | |
| `worker_metrics_port` | `0` | `0` disables metrics; set per alias to give each worker its own port |

Default `worker_jobs`: `ec` (`erasure_coding`, 2), `balance` (`ec_balance`, 1), `lifecycle` (`s3_lifecycle`, 1),
`vacuum` (`vacuum`, 1). The worker id is the container name.
