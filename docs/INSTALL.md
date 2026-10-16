# Installation

## What you need

On the machine that runs Ansible (the controller):

- `ansible-core` 2.15 or newer.
- The collections from `requirements.yml` (`community.docker` >= 5.0.0, `ansible.posix` >= 1.5.0).
- SSH access to every node with a user that can use `docker` (root in the examples).

On every SeaweedFS node (Debian in Stage 1):

- Docker Engine and the `docker compose` plugin, **installed beforehand**. The collection never installs Docker.
  The `common` role checks for both and stops with an explicit error if they are missing.
- Python 3 (Ansible modules need it).
- Every data disk used by a volume server mounted at the path you list in `volume_data_dirs`.
- Network access between nodes on the ports in `CONFIGURATION.md` (masters 9333, filer 8888, admin 23646,
  volume servers 8081-80NN, plus the gRPC ports SeaweedFS derives from them).

Keepalived, nginx and certificates are outside the collection.

## Install the collection

```bash
ansible-galaxy collection install andreyhammer.seaweedfs_docker
ansible-galaxy collection install -r requirements.yml   # dependencies, if not pulled automatically
```

From a checkout of the repository the playbooks are run by file path instead
(`ansible-playbook playbooks/site.yml`), but the repository must then be reachable under
`ansible_collections/andreyhammer/seaweedfs_docker` (a symlink is enough and `ANSIBLE_COLLECTIONS_PATH`
pointing at its parent) because roles are referenced by their FQCN.

## Prepare the inventory

Copy `inventory/production/` and adapt it. The essentials:

1. One inventory alias **per container**, with `ansible_host` set to the node IP (see "Inventory model" in the README).
2. `masters_list` in `group_vars/all.yml`: every master as `IP:PORT`.
3. **`seaweed_large_disk: true|false` in `group_vars/all.yml`.** It is required and has no default, because the regular
   and the large_disk builds of the image are not interchangeable for existing data. Decide once for a cluster.
4. `seaweed_version`, and optionally `container_prefix` if the node also runs other containers.

## Secrets

Secrets are read from environment variables on the controller; nothing secret is stored in the repository.
See `inventory/production/secrets.env.example`:

```bash
export SEAWEED_FILER_POSTGRES_PASSWORD=...   # only when filer_postgres_enabled is true
export SEAWEED_ADMIN_PASSWORD=...            # needed if workers must reach the admin server
```

## First deployment

```bash
ansible-playbook -i inventory/production andreyhammer.seaweedfs_docker.site
```

Roles run in this order: `common` (pre-flight), master, filer, admin, volume, worker. Run one part with tags
(`--tags common,master`). Each role waits for its port and, for masters and volume servers, checks that the node
joined the cluster.

Dry run: add `--check` to `site` or `rolling_update` to see what would change without changing anything.
On nodes where nothing is deployed yet it shows the files and directories that would be created, but not the
container start-up or the waits (they need the files to exist). Both cases are covered by the integration tests.

## Verify

- Masters: `http://<master-ip>:9333/cluster/status` shows a leader and the other masters.
- Volume servers: `http://<master-ip>:9333/dir/status` lists every `ip:port`.
- Containers on a node: `docker ps` shows names such as `master01`, `volume01-dg03`, `worker01-ec01`.

## Try it safely first

`tests/integration/run.sh test` builds three disposable Docker-in-Docker nodes on your workstation and runs the whole
flow (dry run, deploy, idempotence, variant guard, rolling update) against them. Use it before touching real hosts. It needs
Docker and runs privileged containers, so use a development machine.
