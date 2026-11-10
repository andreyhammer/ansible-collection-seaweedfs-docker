# Changelog

## Unreleased

- `rolling_update` and `volume_rolling_restart` read every volume server's data and index directories before the
  first server is touched (`volume_preflight_timeout`). A disk that dropped out or a file system that was shut down
  after I/O errors used to be found only when the run reached that server, after others had been restarted; now the
  run stops before anything is changed. The stop message of a failed server also lists the failed item and its error
  instead of only "One or more items failed".
- `volume`: the wait for a restarted server's EC shards no longer compares the master's count with the number before
  the restart. It failed on healthy servers when the cluster moved or expired shards in the meantime (an EC worker
  moving shards, TTL). The wait now ends when the number the master lists is not zero and has not changed for
  `volume_ec_settle_seconds` (new, default 60); `volume_ec_register_timeout` is still the limit. A server that comes
  back with fewer shards than before is no longer stopped on that alone: the run prints both numbers.

## 0.1.7 (2026-11-04)

- New playbook `volume_rolling_restart`: restarts the volume servers one at a time without an upgrade. Each server is put
  in maintenance mode, its container is restarted (`docker compose restart`, not recreated, so configuration and image
  stay as they are), and the play waits for its port, its registration in the master and its EC shards before the next
  server (`volume_ec_check`, `volume_ec_register_timeout`, as in `rolling_update`); it stops at the first failure. Use
  `--limit` for a single server. The wait steps moved from `main.yml` into `wait_ready.yml`, shared by the start and
  the restart. The integration test restarts two servers with `--limit` and checks that a third one is left alone
  (SeaweedFS 4.52).

## 0.1.6 (2026-11-04)

- `worker`: new job suffix `adminscript` (job type `admin_script`, one per cluster). With an admin server connected the
  masters skip their `[master.maintenance]` scripts and a worker of type `admin_script` runs them instead; without one
  nothing runs `fs.log.purge`, so the filer metadata log (`/topics/.system/log`) grows without limit (about 0.5 GiB a
  day on a cluster with 10 million files). The docs explain that the script is set in the admin UI, that its default
  includes `volume.fix.replication -apply` and `volume.deleteEmpty -apply` and must be reviewed first, and recommend
  `fs.log.purge -daysAgo=30`. The integration test deploys the worker and checks that it registers (SeaweedFS 4.52).
- Removed a trailing blank line in `playbooks/rolling_update.yml` that failed yamllint in CI for 0.1.5.

## 0.1.5 (2026-11-03)

- Downgrade guard: every role refuses to replace an existing container with an older release (numeric tags such as
  `4.52` are compared; `latest` and custom tags are not). `rolling_update -e seaweed_version=X` takes the version from
  the command line, so a stale `seaweed_version` in the inventory would otherwise roll the cluster back on the next
  `site` run. `seaweed_allow_downgrade: true` allows a deliberate rollback.
- `rolling_update`: the master leader is looked up from the first master host instead of the control node, which cannot
  always reach the cluster network.
- `rolling_update` ends with a reminder to set `seaweed_version` in the inventory, because the version came from `-e`.
- Integration test: also runs the downgrade guard and passes on SeaweedFS 4.52.

## 0.1.4 (2026-10-29)

- `admin`: new `admin_require_password` (default `false`). With `true` the role fails when the admin password is empty,
  instead of silently recreating a protected admin server without a password after a run in a shell that lacks
  `SEAWEED_ADMIN_PASSWORD`. The integration test enables it and checks the refusal.
- `volume`: with `volume_entrypoint` set, the check for files that belong to another user is skipped, but the two tasks
  that read its result still evaluated their loop and failed on the skipped results ("object of type 'dict' has no
  attribute 'stdout'"), so such a volume server could not be deployed.

## 0.1.3 (2026-10-26)

- `admin`: the check "workers must reach the admin server" now requires `admin_bind_ip` (or `admin_allow_insecure_bind`
  without a password). A password alone opens only the web UI: SeaweedFS binds the worker gRPC port to `-ip`, which is
  `127.0.0.1` by default, so with a password only no worker could connect (seen on 4.48 to 4.50). The example inventory
  sets `admin_bind_ip`.
- Documented that SeaweedFS 4.49 and later accept workers on other hosts only with `jwt.filer_signing.key` (the same
  `security.toml` in the admin and the workers) and how to set it up.
- Integration test: checks that every worker registers with the admin server, deploys the JWT key, runs against 4.50, and
  calls `ec.encode` with `-shardReplicaPlacement=000` (4.50 enforces the master's default replication for shards and
  refuses to encode a volume when three racks cannot satisfy `010`).

## 0.1.2 (2026-10-23)

- `disks`: `xfsprogs` is installed with `ansible.builtin.package` (apt, dnf, ...) instead of `apt`, after detecting the
  package manager, so `prepare_disks` works on the Red Hat family too.
- Documented the systems checked so far (Debian 12 and Rocky Linux 9.8) and what the Red Hat family needs
  (SELinux). Rocky Linux 9.8 was run on three virtual machines through
  deployment, rolling updates, a reboot and the 3 -> 5 -> 3 masters procedure; no change to the roles was needed.
- Ubuntu 24.04 was run the same way on three virtual machines (deployment, rolling updates of every group, masters
  3 -> 5 -> 3, a reboot); no change to the roles was needed.
- Documented that the admin server of SeaweedFS 4.47 listens on `127.0.0.1` only unless `admin_bind_ip` is set.

## 0.1.1 (2026-10-22)

- Documentation only: the README introduction mentions volume servers and erasure coding, states that the project is
  maintained on a best-effort basis, and `docs/INSTALL.md` describes installing the release archive.
- Every role has a `README.md` (Ansible Galaxy refuses to import a collection whose roles have none).
- First version published on Ansible Galaxy.

## 0.1.0 (2026-10-22)

- Initial implementation: roles `common`, `master`, `filer`, `admin`, `volume`, `worker`.
- Playbooks `site`, `rolling_update`, `add_node`.
- Explicit image variant (`seaweed_large_disk`, no default) with a guard against switching it on an existing container.
- Dry run (`--check`) support, including on nodes where nothing is deployed yet.
- Filer: PostgreSQL mode disables the built-in `leveldb2` store; waits for the S3 gateway port when S3 is enabled.
- Admin: password / insecure-bind handling and an early error when workers cannot reach the admin server.
- Integration tests on disposable nodes covering deploy, idempotence, dry run, variant guard, rolling update order
  (masters: leader last), admin authentication, filer with PostgreSQL and S3, for both image variants.
- `CONTRIBUTING.md` and issue templates.
- Early rejection of an even number of masters; documented and tested procedure for adding two masters to a running
  cluster, and for adding a brand-new node with `add_node` by its inventory group.
- Role `disks` and playbook `prepare_disks`: formats blank disks with XFS (only with `disks_format=true`), mounts them by
  label and writes `/etc/fstab`; refuses disks that carry any signature.
- `remove_masters` handles the raft leader (stops it first; a leader cannot remove itself).
- One Compose project (`compose_project_name`, default `seaweed`) per node, service name = container name, and a node
  file `<docker_compose_dir>/compose.yaml` that includes every container, for `docker compose ps|restart|up -d` by
  hand. Containers from the earlier per-directory layout are moved into the project on the next run.
- `/data` is no longer created on the host (only `docker_compose_dir`).
- The roles do not change kernel parameters (no sysctl); `common_sysctl` does not exist.
- `seaweed_ip`: cluster address that may differ from `ansible_host` (defaults to it).
- Configurable extra options: `<role>_extra_args`, `<role>_environment` (plus global `seaweed_environment`),
  `<role>_extra_volumes`, `<role>_config_files`, `<role>_logging`, `seaweed_localtime`, and dedicated variables for
  `-defaultReplication`, `-volumeSizeLimitMB`, `-index`, `-dataCenter`, `-preStopSeconds`, `-minFreeSpace`,
  `-s3.idleTimeout`, `-adminUser`, worker `-id` and the volume entrypoint. Volume servers now always get `-max`
  (`0` is passed explicitly instead of omitted). `compose.yaml` files are written with mode `0600`.
- Volume: pre-start check that data and index dirs hold no files owned by someone else (`volume_check_ownership`),
  with an optional repair (`volume_fix_ownership`).
- Removed the unused `common_seaweed_user` variable and the unused sysctl handler. Worker metrics (`worker_metrics_port`)
  are covered by the integration tests.
- Documented that worker registration in the admin server is not verified by the collection (check the admin UI).
- Volume: after every start the role waits until the master lists the erasure coding shards the server had before
  (`volume_ec_check`, `volume_ec_register_timeout`); a rolling update stops if they do not come back.
- Example inventory moved to `examples/inventory/` (five nodes: 3 masters, 3 filers with PostgreSQL, admin, 3 EC workers,
  15 volume servers over five racks in one data center) and lists every option of each component, commented out with
  its default, in `group_vars/`. `secrets.env.example` moved out of the inventory directory, where Ansible parsed it.
- Playbook `remove_masters`: removes masters from the raft cluster in pairs (one at a time) and stops their containers;
  tested together with adding them (3 -> 5 -> 3).
- Test: default replication `010` across racks (two copies in different racks), a real `filer.toml` (PostgreSQL), a
  `master.toml` and an `-options` file. Documentation corrected: `-options` takes `name=value` lines, while TOML configs
  are mounted into `/etc/seaweedfs/`; SeaweedFS silently skips a TOML file with a syntax error.
- Volume containers get a `stop_grace_period` (`volume_stop_grace_seconds`, default `-preStopSeconds` + 30 s). Docker's
  default of 10 s killed the server while it was still in its pre-stop sleep, before it closed its files and indexes.
- `volume_index_dir` is empty by default: no `-dir.idx`, the index files stay next to the data. When set, the host
  directory (for example `<container dir>/idx`) is mounted at `/idx` in the container (earlier the fixed `index` and
  `/cache`; `/idx` is the name the official Helm chart uses). The volume role refuses to run when an `index` or `idx`
  directory with files exists in the container directory and is not the configured one, so an empty or missing index is
  never started by accident.
- CI: lint, syntax and sanity checks on every push and pull request; the integration test runs on pushes that change
  the code, weekly and on demand. Status badges in the README.
- The minimum `ansible-core` is 2.17 (the minimum of `community.docker` 5), not 2.15 as stated earlier.
