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
| Compose file of a container | `<docker_compose_dir>/<container_name>/compose.yaml` (service name = container name) |
| Node compose file | `<docker_compose_dir>/compose.yaml`: includes every container of the node, see "Manage by hand" in INSTALL.md |
| Volume index dir | `<docker_compose_dir>/<container_name>/index/` |
| Worker working dir | `<docker_compose_dir>/<container_name>/data/` |

Ports: master 9333, filer 8888 (S3 8333 if enabled), admin 23646, volume `8080 + <MM>` (dg01 is 8081).

## Cluster address (all roles)

Every container announces itself to the cluster (`-ip`), and the roles check registration, ports and raft membership,
using the address `seaweed_ip`. When it is not set, `ansible_host` is used, so a single network needs no extra
variable. Set it per alias (or per node) when SSH uses another network than the cluster:

```yaml
volume05-dg01: {ansible_host: 10.0.0.15, seaweed_ip: 192.168.50.15, ...}
```

`masters_list` must use the cluster addresses. The port and registration checks run on the managed node itself, so
only that node needs to reach the cluster network; the control machine does not (except for the master leader lookup in
`rolling_update`, which queries the first entry of `masters_list` from the control machine).

## Image (all roles)

| Variable | Default | Notes |
|---|---|---|
| `seaweed_large_disk` | none, **required** | `true` or `false`; selects the `_large_disk` tag suffix |
| `seaweed_version` | `latest` | Pin a real version in production |
| `seaweed_image_repo` | `chrislusf/seaweedfs` | Mirror or private registry |
| `seaweed_image` | derived | Overriding it requires a matching `seaweed_large_disk` |
| `seaweed_allow_variant_change` | `false` | See MIGRATION.md before touching it |

## Extra options (all roles)

Any flag, environment variable, mount or config file that has no dedicated variable can still be set. Replace
`<role>` with `master`, `filer`, `admin`, `volume` or `worker`; the settings can be given per group or per alias.

| Variable | Default | Notes |
|---|---|---|
| `<role>_extra_args` | `[]` | Appended to the `weed` command, e.g. `["-readMode=proxy"]` or `["-options=/etc/seaweedfs/opts.conf"]` |
| `<role>_environment` | `{}` | Merged over `seaweed_environment` (set it once for gRPC tuning on every container) |
| `<role>_extra_volumes` | `[]` | `"host:container[:mode]"` strings |
| `<role>_config_files` | `[]` | Files deployed to the node and mounted, see below |
| `<role>_logging` | `seaweed_logging` | Compose `logging:` block, e.g. `{driver: json-file, options: {max-size: 10m, max-file: "3"}}` |
| `seaweed_localtime` | `false` | Mount `/etc/localtime` read-only into every container |
| `admin_user` | `""` | `-adminUser` |
| `worker_id` | container name | `-id` |
| `filer_s3_idle_timeout` | `""` | `-s3.idleTimeout` |

A config file entry is `{src or content, dest, container_path, mode: "0644", read_only: true, secret: false}`:
`src` is a file on the control node, `dest` the path on the managed node. `secret: true` hides the content from the
log. Files are owned by root, so a file the container must read needs `mode: "0644"` (the image drops to uid 1000).
When a config file changes, the container is recreated on that run. Values containing `$` are escaped for Compose
automatically.

There are two different kinds of config files, and they are easy to mix up:

- **SeaweedFS TOML configs** (`master.toml`, `filer.toml`, `security.toml`, ...). SeaweedFS finds them by name in
  `/etc/seaweedfs/`, so mount them there and add nothing to the command: `container_path: /etc/seaweedfs/filer.toml`.
  The official image ships its own `/etc/seaweedfs/filer.toml` with the built-in `leveldb2` store enabled; mounting
  yours replaces it (remember `[leveldb2] enabled = false` next to another store). **A TOML file with a syntax error is
  not an error for SeaweedFS**: it logs `Skipping optional configuration` and starts without the file, so check
  `docker logs <container>` for `Reading ...: While parsing config` after changing one.
- **Options files** for `-options=<file>`: a plain list of `optionName=optionValue` lines (one flag per line), not
  TOML. Mount the file and add `-options=<path>` to `<role>_extra_args`. Setting the same flag through a variable and
  through the options file at once is not tested; use one of them.

Tested: `master.toml`, a `filer.toml` that puts the filer on PostgreSQL, and an options file that sets `dataCenter`
(the master reports it). Not tested: `security.toml` contents (JWT, TLS), `admin` and `worker` options files.

Example, covering a typical hand-written cluster:

```yaml
seaweed_environment:
  GRPC_GO_KEEPALIVE_TIME_MS: "20000"
seaweed_localtime: true
seaweed_logging: {driver: json-file, options: {max-size: 10m, max-file: "3"}}
master_default_replication: "010004"
master_volume_size_limit_mb: 30000
master_config_files:
  - {src: files/master.toml, dest: /opt/seaweed/config/master/master.toml, container_path: /etc/seaweedfs/master.toml}
volume_index_type: leveldbLarge
volume_data_center: dc1
volume_pre_stop_seconds: 30
volume_min_free_space: 5
volume_entrypoint: /usr/bin/weed
filer_config_files:
  - {src: files/filer.toml, dest: /opt/seaweed/config/filer.toml, container_path: /etc/seaweedfs/filer.toml}
filer_s3_idle_timeout: 3600
```

## Disks (`prepare_disks` playbook)

| Variable | Default | Notes |
|---|---|---|
| `disks_filesystems` | `[]` | List of `{device, label, mount}` on the node; `device` must be a `/dev/disk/by-*` name, `label` 1-12 characters |
| `disks_format` | `false` | Must be `true` to format; without it the run lists the empty disks and fails |
| `disks_mount_options` | `defaults,noatime` | Mount options in `/etc/fstab` |
| `disks_install_packages` | `true` | Install `xfsprogs` |
| `disks_allow_unstable_names` | `false` | Allow `/dev/sdX` (throwaway tests only) |

## Common

| Variable | Default | Notes |
|---|---|---|
| `docker_compose_dir` | `/opt/seaweed` | Base directory for all projects |
| `compose_project_name` | `seaweed` | Compose project shared by every container of a node (lowercase letters, digits, `-`, `_`) |
| `container_prefix` | `""` | |
| `health_check_timeout` | `60` | Seconds to wait for ports and cluster registration |
| `common_base_dirs` | `docker_compose_dir` | Created on every node |
| `common_min_free_gb` | `10` | Free space required on each volume data dir (needs gathered facts) |

## Master

| Variable | Default | Notes |
|---|---|---|
| `masters_list` | `[]`, **required** | `["10.0.0.11:9333", ...]` |
| `node_num` | required per alias | Node number |
| `master_port` | `9333` | |
| `master_default_replication` | `""` | `-defaultReplication`, e.g. `"010"`; empty = SeaweedFS default |
| `master_volume_size_limit_mb` | `""` | `-volumeSizeLimitMB`; empty = SeaweedFS default |

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

With PostgreSQL enabled the role turns the built-in `leveldb2` store off (the filer refuses to run with two stores).
The PostgreSQL mode is tested with SeaweedFS 4.48; version 4.18 fails to create its table when configured through
environment variables (`syntax error at or near "%!"`), so use a recent version.

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
| `volume_max_volumes` | `0` | Always passed as `-max`; `0` lets SeaweedFS derive it from free space |
| `volume_index_type` | `""` | `-index`, e.g. `leveldbLarge` |
| `volume_data_center` | `""` | `-dataCenter` |
| `volume_pre_stop_seconds` | `""` | `-preStopSeconds` |
| `volume_min_free_space` | `""` | `-minFreeSpace` |
| `volume_stop_grace_seconds` | `volume_pre_stop_seconds` (10 if unset) + 30 | Compose `stop_grace_period`: how long Docker waits after SIGTERM before SIGKILL. The server sleeps `-preStopSeconds` before it closes its files, so this must be longer than that |
| `volume_entrypoint` | `""` | e.g. `/usr/bin/weed` to bypass the image entrypoint (the container then runs as root) |
| `volume_container_uid` / `_gid` | `1000` / `1000` | Owner of the data and index directories on the host, matching the image's `seaweed` user |
| `volume_check_ownership` | `true` | Before starting, fail if a data or index dir holds files not owned by the container user (skipped when `volume_entrypoint` is set) |
| `volume_fix_ownership` | `false` | Recursively chown such files instead of failing; can take long on full disks |
| `volume_ec_check` | `true` | After every start, wait until the master lists the EC shards the server had registered before |
| `volume_ec_register_timeout` | `300` | Seconds to wait for them; the run fails after that |
| `volume_index_dir` | `<docker_compose_dir>/<container_name>/index` | Index directory on the host |

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
`vacuum` (`vacuum`, 1). The worker id (`-id`) is `worker_id`, by default the container name.
