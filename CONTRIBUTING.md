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

You need Docker, `ansible-core` 2.17 or newer, `ansible-lint` and `yamllint`.

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

The nodes are **privileged** containers, so use a development machine: the loop devices created by the disks test
and any kernel setting that is not namespaced are shared with your host. The roles never change kernel parameters.

## Continuous integration

Pull requests run `yamllint`, `ansible-lint` (production profile), `shellcheck`, `ansible-test sanity` and a syntax check
of every playbook on `ansible-core` 2.17, 2.18 and the latest release (`.github/workflows/ci.yml`). The integration test
(`.github/workflows/integration.yml`) is slow and starts privileged containers, so it runs weekly and on request
(Actions, "Integration", "Run workflow"), not on every pull request. Run it locally before you open a pull request.

Add a check to `tests/integration/` for every behavior you change or add, and say in the pull request what you ran.

## Pull requests

- One logical change per pull request, with a clear description of what changes for a cluster operator.
- Update `docs/` and `CHANGELOG.md` when behavior or variables change.
- Lint and the integration tests must pass.
