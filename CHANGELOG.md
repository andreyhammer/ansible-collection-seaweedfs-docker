# Changelog

## Unreleased

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
