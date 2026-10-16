# andreyhammer.seaweedfs_docker

Ansible collection that deploys, upgrades and scales a [SeaweedFS](https://github.com/seaweedfs/seaweedfs) cluster
with Docker Compose. Stage 1 targets Debian.

## Requirements

- Ansible core >= 2.15 and the collections in `requirements.yml`:
  `ansible-galaxy collection install -r requirements.yml`
- Docker Engine and the `docker compose` plugin installed on every node **before** running playbooks.
  Pre-flight checks fail with an explicit error if they are missing.
- Keepalived and nginx are external and not managed here.

## Documentation

- [Installation](docs/INSTALL.md): requirements, inventory, secrets, first deployment.
- [Configuration reference](docs/CONFIGURATION.md): every variable by role, naming, ports.
- [Upgrades and migrations](docs/MIGRATION.md): rolling update, image variant rules, taking over a hand-made cluster.

## Quick start

```bash
ansible-galaxy collection install andreyhammer.seaweedfs_docker
# Adapt inventory/production/ from this repository, then export secrets:
export SEAWEED_FILER_POSTGRES_PASSWORD=...
ansible-playbook -i inventory/production andreyhammer.seaweedfs_docker.site --check
ansible-playbook -i inventory/production andreyhammer.seaweedfs_docker.site
```

| Task | Command |
|---|---|
| Upgrade volumes | `ansible-playbook andreyhammer.seaweedfs_docker.rolling_update -e seaweed_version=4.49` |
| Upgrade masters (leader last) | `... rolling_update -e seaweed_version=4.49 -e target_group=master` |
| Add a node | `ansible-playbook andreyhammer.seaweedfs_docker.add_node -e target_node=volume06-dg01` |

## Image selection

The collection uses the official SeaweedFS image, which comes in two builds that are **not interchangeable for
existing data**: the regular one and the `large_disk` one (volumes above 32 GB). You must choose explicitly:

| Variable | Default | Meaning |
|---|---|---|
| `seaweed_large_disk` | **none, required** | `false` = regular build, `true` = `<version>_large_disk` tag |
| `seaweed_version` | `latest` | Image tag |
| `seaweed_image_repo` | `chrislusf/seaweedfs` | Repository, e.g. a mirror or private registry |
| `seaweed_image` | derived from the three above | Override only together with a matching `seaweed_large_disk` |

Safeguards (run before any container is created or recreated, so `site`, `add_node` and `rolling_update` are all covered):

- Playbooks fail immediately if `seaweed_large_disk` is not set.
- They fail if `seaweed_image` and `seaweed_large_disk` disagree (a `large_disk` image must have a tag ending in `_large_disk`).
- They fail if an existing container runs the other build than the one requested, so an update can never silently
  turn a large_disk cluster into a regular one or the reverse. With `serial: 1` the rolling update stops on the first host.
  `seaweed_allow_variant_change: true` disables this check; use it only for a deliberate, tested migration.

## Testing on disposable nodes

`tests/integration/run.sh` builds three throwaway Docker-in-Docker nodes (reached over SSH like real hosts,
no ports published on your machine), deploys the full cluster and checks it. Production hosts are never touched.

```bash
tests/integration/run.sh test                          # up, dry run, deploy, verify, idempotence, variant guard, rolling update, down
SEAWEED_TEST_LARGE_DISK=1 tests/integration/run.sh test  # same with the large_disk build
tests/integration/run.sh up|deploy|verify|idempotence|dryrun|guard|update|down    # individual steps; KEEP=1 keeps nodes after `test`
```

Requires Docker on the machine running the tests. The nodes are privileged containers, so run them only on a
development machine.

## Inventory model

Each container instance is its own inventory alias (`master01`, `volume01-dg03`, `worker01-ec02`, ...) whose
`ansible_host` is the node IP. Container names are `<container_prefix><role><NN>[-<sub><MM>]` with two-digit numbers.
Volume ports are `8080 + <MM>`. See `inventory/production/` for a complete example and `docs/CONFIGURATION.md` for every variable.

## Secrets

Secrets are read from environment variables (`SEAWEED_FILER_POSTGRES_PASSWORD`, `SEAWEED_ADMIN_PASSWORD`).
See `inventory/production/secrets.env.example`.

## License

Apache License 2.0.
