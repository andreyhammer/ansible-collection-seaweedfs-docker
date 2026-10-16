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

The collection is not published on Ansible Galaxy yet, so `ansible-galaxy collection install
andreyhammer.seaweedfs_docker` does not work. Build it from a checkout and install the archive:

```bash
ansible-galaxy collection build
ansible-galaxy collection install andreyhammer-seaweedfs_docker-*.tar.gz
ansible-galaxy collection install -r requirements.yml   # dependencies (community.docker, ansible.posix)
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

## Add a node (new hardware)

1. Prepare the machine: Debian, SSH access, Docker Engine and the `docker compose` plugin, data disks mounted at the
   paths you will list in `volume_data_dirs`.
2. Add **every alias that will run on it** to the inventory (filer, volume servers, workers, ...), each with the new
   node's IP in `ansible_host` and the next node number (for example `volume05-dg01`, `worker05-ec01`, `filer05`).
3. Put those aliases into one group named after the node, so that you can address the whole node by one name:

   ```yaml
   all:
     children:
       node05:
         hosts:
           filer05:
           volume05-dg01:
           volume05-dg02:
           worker05-ec01:
   ```

4. Check what would happen, then add the node:

   ```bash
   ansible-playbook -i inventory/production andreyhammer.seaweedfs_docker.add_node -e target_node=node05 --check
   ansible-playbook -i inventory/production andreyhammer.seaweedfs_docker.add_node -e target_node=node05
   ```

   `target_node` is any Ansible host pattern: the group above, a single alias, or a comma-separated list. Do not use
   wildcards such as `*05*`: they also match aliases like `volume01-dg05`.
5. Verify as described in "Verify" above. A second `site` run must report no changes.

What `add_node` does and does not do:

- It runs the pre-flight checks and then the roles for the aliases you name; existing nodes are not touched.
- New volume servers receive new writes at once. **Existing data is not moved**: redistribute volumes with SeaweedFS's
  own tools (for example `volume.balance` in `weed shell`), which is outside this collection and not covered by the
  tests.
- Adding a **master** needs extra steps, see the next section.

## Add masters

SeaweedFS refuses to start masters with an **even** list (`Only odd number of masters are supported`), so masters are
added **in pairs** (3 to 5). The roles reject an even `masters_list` before touching anything.

1. Prepare the new nodes as above and add two aliases to the `master` group, each with `node_num` and the node's IP
   (for example `master04` and `master05`).
2. Extend `masters_list` with both (`IP:9333`), so that it lists all five masters.
3. Start the new masters:

   ```bash
   ansible-playbook -i inventory/production andreyhammer.seaweedfs_docker.add_node -e target_node=master04,master05
   ```

   They find the running leader and join the raft group by themselves; no manual raft commands are needed.
   `http://<master-ip>:9333/cluster/status` now lists five masters.
4. Make the existing services use the new list. Every service carries the masters list in its `compose.yaml`
   (`-peers` for masters, `-master` for the rest), so refresh them one group at a time with the version that is
   already deployed; the leader is restarted last:

   ```bash
   for group in master filer admin volume worker; do
     ansible-playbook -i inventory/production andreyhammer.seaweedfs_docker.rolling_update \
       -e seaweed_version=<current version> -e target_group=$group
   done
   ```
5. Run `site` once more: it must report no changes.

Going from three masters to five was tested end to end. **Removing or replacing a master is not covered** by the
collection and has not been tested; every intermediate state must keep an odd number of masters.

## Try it safely first

`tests/integration/run.sh test` builds three disposable Debian 12 nodes (each with its own Docker daemon) on your workstation and runs the whole
flow (dry run, deploy, idempotence, variant guard, rolling update) against them. Use it before touching real hosts. It needs
Docker and runs privileged containers, so use a development machine.
