# andreyhammer.seaweedfs_docker

[![CI](https://github.com/andreyhammer/ansible-collection-seaweedfs-docker/actions/workflows/ci.yml/badge.svg)](https://github.com/andreyhammer/ansible-collection-seaweedfs-docker/actions/workflows/ci.yml)
[![Integration](https://github.com/andreyhammer/ansible-collection-seaweedfs-docker/actions/workflows/integration.yml/badge.svg)](https://github.com/andreyhammer/ansible-collection-seaweedfs-docker/actions/workflows/integration.yml)
[![License](https://img.shields.io/github/license/andreyhammer/ansible-collection-seaweedfs-docker)](LICENSE)
[![ansible-core](https://img.shields.io/badge/ansible--core-%E2%89%A5%202.17-blue)](#requirements)

Ansible collection that deploys, upgrades and scales a [SeaweedFS](https://github.com/seaweedfs/seaweedfs) cluster
with Docker Compose: masters, filers, one volume server per disk group, and erasure coding (EC) workers, with
rolling updates and disk preparation. Tested on Debian 12, Ubuntu 24.04 and Rocky Linux 9.

## What you get

- Roles for masters, filers, admin, volume servers and EC workers, one container per inventory alias, with the
  official `chrislusf/seaweedfs` image.
- Safe changes: a dry run (`--check`), a guard against switching the image variant on existing data, a guard against
  starting a volume server on a missing index directory, and a rolling update that stops at the first failure (masters
  first, the raft leader last).
- Checks after every start: the port answers, the server is registered in the masters, and a volume server's EC shards
  come back after a restart.
- Day-two tools: add a node, add or remove masters (in pairs), prepare blank data disks (XFS, mounted by label).
- Every node also gets one `docker compose` project, so you can look at it and restart things by hand without Ansible
  (see `docs/INSTALL.md`, "Manage by hand").

## Why this approach

SeaweedFS already does the hard parts of a storage cluster: replication, erasure coding and rebalancing between
servers. What it does not do is decide **which disks each server owns** and **which address it announces**. That
shapes the design:

- **One container per disk group, one inventory alias per container.** The group size is yours to choose: one disk per
  server gives the smallest failure domain (a crash, hang or restart of a volume server affects one disk), one server
  for all disks gives the fewest processes. A node with eight HDDs can run, for example, four servers with two disks
  each: half as many servers as one per disk, and a restart or upgrade of a server touches only two disks instead of
  eight. Smaller servers also load their volumes and indexes faster after a restart, because each has fewer to scan
  (not measured here). A failed disk is the clearest case: the server cannot keep running with it, so the disk is
  removed from `-dir` and the server restarted, and the replacement is added with another restart. With one server for
  eight disks all eight go offline for each of those restarts, with four servers only two. The cost is more containers
  and ports (`8080 + NN`) than a single server per node, which the
  collection derives for you, and the group layout is fixed in the inventory.
- **Docker Compose and Ansible, not Docker Swarm or Kubernetes.** The containers need host networking, a fixed cluster
  address and bind mounts of specific disks. That is the normal way to run Docker on a bare-metal host, and it is
  awkward to express in Swarm. Kubernetes can do it (SeaweedFS has an official Helm chart and an operator), but it
  needs a cluster to run on; if you already operate one, use those, not this collection. Here the machines are plain
  servers managed with Ansible, and a failed container is restarted by Docker while data safety comes from
  SeaweedFS's own replication and erasure coding, not from an orchestrator.
- **Plain Compose files you can read.** Each container has a `compose.yaml` generated from one template per role, and
  the roles never touch the kernel, the host's `/data` or software you did not ask for (Docker, keepalived and nginx are
  yours). You can stop using the collection at any time and keep the files.
- **Guards where mistakes are expensive.** The regular and `large_disk` builds are not interchangeable for existing
  data, so the variant is a required choice; a changed or missing index directory would hide the EC indexes, so the
  volume role refuses it; even numbers of masters are rejected before anything changes.

What you give up: no automatic failover of a whole node (you restart it; the data stays available through
replication or EC), no autoscaling, and rebalancing after adding servers is still `volume.balance` in `weed shell`.

## Status and limits

Stage 1. The roles pass `ansible-lint` (production profile) and an integration test on disposable nodes (see
[Testing on disposable nodes](#testing-on-disposable-nodes)). On real hardware it has so far been used to add a
node of four volume servers to an existing, hand-made cluster; it has not seen wide use, so expect rough
edges and read the dry run (`--check`) before every change. Not done or not verified:

- Tested on Debian 12 (the full integration test), Rocky Linux 9.8 with SELinux enforcing and Ubuntu 24.04 (manual runs
  on three virtual machines each: deployment of every component, rolling updates, adding and removing
  masters, a reboot; the lists are in `docs/INSTALL.md`). The roles use nothing distribution-specific, so other
  distributions with Docker should work, but they are untested.
- `security.toml` contents (JWT, TLS) and the `admin` and `worker` options files are not tested. CI checks syntax on
  `ansible-core` 2.17 (the minimum), 2.18 and the latest release; the playbooks have only been run on the latest.
- Removing a master whose server is already dead is manual; there is no automatic rebalance after adding volumes.
- With a separate index directory (`volume_index_dir`), SeaweedFS 4.48 keeps part of the `.ecx`/`.ecj` files in the data
  directories as well (see `docs/CONFIGURATION.md`). Without it, everything stays together.

Maintained on a best-effort basis; issues and pull requests are welcome.

## Requirements

- Ansible core >= 2.17 (the minimum of `community.docker` 5) and the collections in `requirements.yml`:
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
ansible-galaxy collection install andreyhammer.seaweedfs_docker   # other ways: docs/INSTALL.md
# Adapt examples/inventory/ from this repository, then export secrets:
export SEAWEED_FILER_POSTGRES_PASSWORD=...
ansible-playbook -i examples/inventory andreyhammer.seaweedfs_docker.site --check
ansible-playbook -i examples/inventory andreyhammer.seaweedfs_docker.site
```

| Task | Command |
|---|---|
| Upgrade volumes | `ansible-playbook andreyhammer.seaweedfs_docker.rolling_update -e seaweed_version=4.49` |
| Upgrade masters (leader last) | `... rolling_update -e seaweed_version=4.49 -e target_group=master` |
| Remove masters (in pairs) | `ansible-playbook andreyhammer.seaweedfs_docker.remove_masters -e target_masters=master04,master05` (see `docs/INSTALL.md`) |
| Prepare data disks (XFS, mount by label) | `ansible-playbook andreyhammer.seaweedfs_docker.prepare_disks -e target_node=<host>` (formats only with `-e disks_format=true`; see `docs/INSTALL.md`) |
| Add a node | `ansible-playbook andreyhammer.seaweedfs_docker.add_node -e target_node=node05` (a group with all aliases of the new node; see `docs/INSTALL.md`) |

### Minimal example

Three nodes (`10.0.0.11-13`), each with a master and two volume servers of two disks each. The disks are already
formatted and mounted at `/mnt/disk1` to `/mnt/disk4` on every node (see `prepare_disks` above for blank ones).

`inventory/hosts.yml`:

```yaml
all:
  children:
    seaweed:
      children:
        master:
          hosts:
            master01: {ansible_host: 10.0.0.11, node_num: 1}
            master02: {ansible_host: 10.0.0.12, node_num: 2}
            master03: {ansible_host: 10.0.0.13, node_num: 3}
        volume:
          hosts:
            volume01-dg01: {ansible_host: 10.0.0.11, volume_node_num: 1, volume_dg: 1, volume_rack: rack1, volume_data_dirs: [/mnt/disk1, /mnt/disk2]}
            volume01-dg02: {ansible_host: 10.0.0.11, volume_node_num: 1, volume_dg: 2, volume_rack: rack1, volume_data_dirs: [/mnt/disk3, /mnt/disk4]}
            volume02-dg01: {ansible_host: 10.0.0.12, volume_node_num: 2, volume_dg: 1, volume_rack: rack2, volume_data_dirs: [/mnt/disk1, /mnt/disk2]}
            volume02-dg02: {ansible_host: 10.0.0.12, volume_node_num: 2, volume_dg: 2, volume_rack: rack2, volume_data_dirs: [/mnt/disk3, /mnt/disk4]}
            volume03-dg01: {ansible_host: 10.0.0.13, volume_node_num: 3, volume_dg: 1, volume_rack: rack3, volume_data_dirs: [/mnt/disk1, /mnt/disk2]}
            volume03-dg02: {ansible_host: 10.0.0.13, volume_node_num: 3, volume_dg: 2, volume_rack: rack3, volume_data_dirs: [/mnt/disk3, /mnt/disk4]}
```

`inventory/group_vars/all.yml`:

```yaml
seaweed_version: "4.48"
seaweed_large_disk: false      # required: decide once, the two image builds are not interchangeable
masters_list: ["10.0.0.11:9333", "10.0.0.12:9333", "10.0.0.13:9333"]
```

Deploy and check:

```bash
ansible-playbook -i inventory andreyhammer.seaweedfs_docker.site --check   # preview, nothing changes
ansible-playbook -i inventory andreyhammer.seaweedfs_docker.site
curl http://10.0.0.11:9333/cluster/status        # a leader and the other masters
curl http://10.0.0.11:9333/dir/status            # volume servers 10.0.0.1x:8081 and :8082 on three racks
ssh 10.0.0.11 'cd /opt/seaweed && docker compose ps'   # master01, volume01-dg01, volume01-dg02
```

Each container gets `/opt/seaweed/<name>/compose.yaml`, and `/opt/seaweed/compose.yaml` on every node includes all
of them, so `docker compose ps|logs|restart` works there without Ansible. Filers, the admin server and EC workers are
added the same way (more aliases in the `filer`, `admin` and `worker` groups); `examples/inventory/` shows all of them.
To add a volume server later, add an alias and run `add_node -e target_node=<alias>`.

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

`tests/integration/run.sh` builds three throwaway Debian 12 nodes with a Docker-in-Docker daemon (reached over SSH like real
hosts, no ports published on your machine), deploys the full cluster and checks it. Production hosts are never touched.

```bash
tests/integration/run.sh test                          # up, dry run, deploy, verify, idempotence, variant guard, rolling update, down
SEAWEED_TEST_LARGE_DISK=1 tests/integration/run.sh test  # same with the large_disk build
tests/integration/run.sh up|deploy|verify|idempotence|dryrun|guard|update|down    # individual steps; KEEP=1 keeps nodes after `test`
```

Requires Docker on the machine running the tests. The nodes are privileged containers, so run them only on a
development machine.

## Inventory model

Each container instance is its own inventory alias (`master01`, `volume01-dg03`, `worker01-ec02`, ...) whose
`ansible_host` is the node IP (set `seaweed_ip` when the cluster network differs from the SSH one). Container names are `<container_prefix><role><NN>[-<sub><MM>]` with two-digit numbers.
Volume ports are `8080 + <MM>`. See `examples/inventory/` for a complete example and `docs/CONFIGURATION.md` for every variable.

## Secrets

Secrets are read from environment variables (`SEAWEED_FILER_POSTGRES_PASSWORD`, `SEAWEED_ADMIN_PASSWORD`).
See `examples/secrets.env.example`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md): ground rules, how to run lint and the integration tests, pull request checklist.

## License

Apache License 2.0.
