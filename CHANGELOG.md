# Changelog

## 1.0.0 (unreleased)

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
