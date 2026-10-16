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
