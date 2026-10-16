# Contributing

Thanks for helping. This collection deploys SeaweedFS with Docker Compose, so a change that looks harmless can
affect a cluster that holds data. Please keep that in mind and test accordingly.

## Ground rules

- **English only** in code, comments, documentation, variable and file names, and commit messages.
- Use **FQCN** for every module and role (`ansible.builtin.file`, `andreyhammer.seaweedfs_docker.master`).
- Prefer modules over `command`/`shell`. When a command is unavoidable, set `changed_when` / `failed_when`.
- Keep runs **idempotent** and keep `--check` working.
- **Never give `seaweed_large_disk` a default** and keep the image variant guard (`roles/common/tasks/image_guard.yml`)
  called by every role that creates a container. The regular and the large_disk builds are not interchangeable for
  existing data.
- Secrets come from environment variables. Never commit values, only `.example` files.

## Development setup

You need Docker, `ansible-core` 2.15 or newer, `ansible-lint` and `yamllint`.

```bash
ansible-galaxy collection install -r requirements.yml
ansible-lint            # profile: production, must report no findings
yamllint .
```

## Testing

Test on the disposable nodes, never on real hosts:

```bash
tests/integration/run.sh test                            # full run, about 5 minutes
SEAWEED_TEST_LARGE_DISK=1 tests/integration/run.sh test  # the same with the large_disk build
tests/integration/run.sh up|deploy|verify|idempotence|dryrun|guard|update|down   # single steps
```

The nodes are **privileged** containers, so use a development machine. Do not relax `common_sysctl` in the test
inventory: sysctls that are not network-namespaced (such as `vm.swappiness`) would change your host.

Add a check to `tests/integration/` for every behavior you change or add, and say in the pull request what you ran.

## Pull requests

- One logical change per pull request, with a clear description of what changes for a cluster operator.
- Update `docs/` and `CHANGELOG.md` when behavior or variables change.
- Lint and the integration tests must pass.
