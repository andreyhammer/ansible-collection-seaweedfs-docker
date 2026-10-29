# Installation

## What you need

On the machine that runs Ansible (the controller):

- `ansible-core` 2.17 or newer (the minimum of the `community.docker` 5 dependency).
- The collections from `requirements.yml` (`community.docker` >= 5.0.0, `ansible.posix` >= 1.5.0).
- SSH access to every node with a user that can use `docker` (root in the examples).

On every SeaweedFS node (tested on Debian 12 and Rocky Linux 9.8, see "Supported systems" below):

- Docker Engine and the `docker compose` plugin, **installed beforehand**. The collection never installs Docker.
  The `common` role checks for both and stops with an explicit error if they are missing.
- Python 3 (Ansible modules need it).
- Every data disk used by a volume server mounted at the path you list in `volume_data_dirs`.
- Network access between nodes on the ports in `CONFIGURATION.md` (masters 9333, filer 8888, admin 23646,
  volume servers 8081-80NN, plus the gRPC ports SeaweedFS derives from them).

Keepalived, nginx and certificates are outside the collection.

### Supported systems

| System | What was checked |
|---|---|
| Debian 12 | The whole integration test (`tests/integration/run.sh test`) and production use. |
| Rocky Linux 9.8, SELinux enforcing, Docker CE 29.9, Compose 5.6, ansible-core 2.21.5 | Three virtual machines, by hand, with SeaweedFS 4.48: `prepare_disks` on virtual disks; `site` (3 masters, filer with S3 enabled, admin, 2 workers, 6 volume servers in 3 racks, replication `010`), `--check` on empty nodes, a second run with no changes; data written through the filer and read back; one volume erasure coded (14 shards); `rolling_update` of every group (4.48 to 4.47 and back, EC shards came back after each volume restart); the variant guard; a node reboot (disks, containers and cluster came back by themselves); adding two masters (3 to 5) and removing them again, with the other services refreshed. Not run: PostgreSQL filer, S3 requests with credentials, an erasure coding task actually run by a worker, wrong-password and ownership checks. |
| Ubuntu 24.04.5, Docker CE, ansible-core 2.21.5 | Three virtual machines, by hand, with SeaweedFS 4.48: `prepare_disks` (the second run changes nothing), `site --check`, `site` with the same components and layout as on Rocky, a second run with no changes, data written through the filer and read back, one volume erasure coded (14 shards), `rolling_update` of every group (4.48 to 4.47, EC shards came back), adding two masters (3 to 5) and removing them again with the other services refreshed, the variant guard, a node reboot. No Python setting was needed. Not run: the items listed for Rocky. The image already contained `xfsprogs`, so the package was not installed during the run. |
| Other Debian/Ubuntu releases, other Red Hat family systems | Not tested. Nothing in the roles is specific to one distribution. |

Notes for the Red Hat family:

- **SELinux.** Containers wrote to the data disks with SELinux enforcing and no denials, because Docker CE does not
  confine containers with SELinux unless `"selinux-enabled": true` is set in `/etc/docker/daemon.json`. With that
  setting the data and compose directories would need an SELinux label (`:z`); this is **not tested** and the
  collection does not do it for you.
- **Ansible configuration.** If the first task fails with `The module interpreter 'auto_legacy' was not found`, your
  `ansible.cfg` sets `interpreter_python = auto_legacy`, which ansible-core 2.21.5 treats as a path. Use `auto` (the
  default) or remove the line; this is not specific to any distribution.
- **Firewall.** The collection does not open ports (see the list above); do it with `firewalld` yourself.

## Install the collection

From Ansible Galaxy (this also installs the dependencies from `galaxy.yml`):

```bash
ansible-galaxy collection install andreyhammer.seaweedfs_docker
```

Or install the archive attached to a GitHub release (replace the version as needed):

```bash
ansible-galaxy collection install \
  https://github.com/andreyhammer/ansible-collection-seaweedfs-docker/releases/download/v0.1.4/andreyhammer-seaweedfs_docker-0.1.4.tar.gz
ansible-galaxy collection install -r requirements.yml   # dependencies (community.docker, ansible.posix)
```

Or build it from a checkout and install the archive:

```bash
ansible-galaxy collection build
ansible-galaxy collection install andreyhammer-seaweedfs_docker-*.tar.gz
ansible-galaxy collection install -r requirements.yml
```

From a checkout of the repository the playbooks are run by file path instead
(`ansible-playbook playbooks/site.yml`), but the repository must then be reachable under
`ansible_collections/andreyhammer/seaweedfs_docker` (a symlink is enough and `ANSIBLE_COLLECTIONS_PATH`
pointing at its parent) because roles are referenced by their FQCN.

## Prepare the inventory

Copy `examples/inventory/` and adapt it. The essentials:

1. One inventory alias **per container**, with `ansible_host` set to the node IP (see "Inventory model" in the README). When SSH uses a different network than
   the cluster, keep the SSH address in `ansible_host` and put the cluster address in `seaweed_ip` (see CONFIGURATION.md).
2. `masters_list` in `group_vars/all.yml`: every master as `IP:PORT`.
3. **`seaweed_large_disk: true|false` in `group_vars/all.yml`.** It is required and has no default, because the regular
   and the large_disk builds of the image are not interchangeable for existing data. Decide once for a cluster.
4. `seaweed_version`, and optionally `container_prefix` if the node also runs other containers.

Every `group_vars/*.yml` file in the example also lists, commented out and with their defaults, all the options of
that component (replication, racks, logging, extra flags, config files, ...). `docs/CONFIGURATION.md` explains them.

## Secrets

Secrets are read from environment variables on the controller; nothing secret is stored in the repository.
See `examples/secrets.env.example`:

```bash
export SEAWEED_FILER_POSTGRES_PASSWORD=...   # only when filer_postgres_enabled is true
export SEAWEED_ADMIN_PASSWORD=...            # protects the admin web UI (workers also need admin_bind_ip, see CONFIGURATION.md)
```

## First deployment

```bash
ansible-playbook -i examples/inventory andreyhammer.seaweedfs_docker.site
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
- Workers: open the admin UI and check that every worker is listed. A worker registers itself when it connects to the
  admin server (`-admin=<ip>:23646`), and the collection does not verify that: it only checks that the container is
  running and that the admin port was reachable before it started. A worker that cannot connect (wrong address, broken
  gRPC, incompatible version) still shows as a running container.

## Prepare data disks (optional)

The roles only check that the data directories are mounted. For new hardware with blank disks, the `prepare_disks`
playbook formats them with XFS, mounts them by label and writes `/etc/fstab`. Describe the disks on the **node** (a
host variable, not on the container aliases), by their stable names:

```yaml
seaweed01-05.in.example.com:
  disks_filesystems:
    - {device: /dev/disk/by-id/ata-EXAMPLE_MODEL_SERIAL0001, label: disk1, mount: /mnt/disk1}
    - {device: /dev/disk/by-id/ata-EXAMPLE_MODEL_SERIAL0002, label: disk2, mount: /mnt/disk2}
```

Find the names with `ls -l /dev/disk/by-id/` and `lsblk -o NAME,SIZE,SERIAL,MODEL,FSTYPE,MOUNTPOINT`; `/dev/sdX`
names are refused because they change between boots. Then:

1. `ansible-playbook andreyhammer.seaweedfs_docker.prepare_disks -e target_node=<host>`: lists what it found and
   stops, because formatting is off by default.
2. Review the list, then preview with `--check -e disks_format=true`.
3. Run it with `-e disks_format=true`. Formatting cannot be undone.

Safeguards: a disk that already has any signature (a filesystem, a RAID member, a partition table), has partitions or
is mounted elsewhere stops the whole run before anything is changed (wipe it yourself if that is intended); `mkfs.xfs`
is never forced; the filesystem label (at most 12 characters) is what `/etc/fstab` uses, so the mapping survives
device renaming. Re-running is safe: disks that are already formatted with the right label are only mounted.
The package `xfsprogs` is installed with the system's package manager (`apt`, `dnf`, ...) unless
`disks_install_packages: false`; set that variable and install it yourself when the package has another name.

## Manage by hand

Every node has `/opt/seaweed/compose.yaml` (written by the roles, do not edit) that includes the compose file of every
container the collection manages on it. All of them belong to one Compose project (`compose_project_name`, `seaweed`),
so Ansible is not needed for day-to-day work:

```bash
cd /opt/seaweed
docker compose ps
docker compose logs -f --tail 100 volume05-dg01
docker compose restart volume05-dg01     # one container
docker compose restart                   # every container of the node
docker compose up -d                     # start everything that is stopped
```

The service name is the container name. `docker compose up -d` after changing a `compose.yaml` by hand recreates the
container, and the next Ansible run overwrites such a change. A removed master (`remove_masters`) has its
`compose.yaml` renamed to `compose.yaml.removed` and disappears from the list, so a manual `up -d` does not start it
again. Only files with the collection's header are listed; compose files that you keep in other directories there
are left alone.

Containers created by an earlier layout (one Compose project per directory) are stopped and removed on the next run
of a role and started again in the shared project; the data directories are reused as they are, but the container is
restarted once. Dry runs (`--check`) do not report this move.

## Add a node (new hardware)

1. Prepare the machine: SSH access, Docker Engine and the `docker compose` plugin, data disks mounted at the
   paths you will list in `volume_data_dirs` (blank disks: see "Prepare data disks" above).
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
   ansible-playbook -i examples/inventory andreyhammer.seaweedfs_docker.add_node -e target_node=node05 --check
   ansible-playbook -i examples/inventory andreyhammer.seaweedfs_docker.add_node -e target_node=node05
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
   ansible-playbook -i examples/inventory andreyhammer.seaweedfs_docker.add_node -e target_node=master04,master05
   ```

   They find the running leader and join the raft group by themselves; no manual raft commands are needed.
   `http://<master-ip>:9333/cluster/status` now lists five masters.
4. Make the existing services use the new list. Every service carries the masters list in its `compose.yaml`
   (`-peers` for masters, `-master` for the rest), so refresh them one group at a time with the version that is
   already deployed; the leader is restarted last:

   ```bash
   for group in master filer admin volume worker; do
     ansible-playbook -i examples/inventory andreyhammer.seaweedfs_docker.rolling_update \
       -e seaweed_version=<current version> -e target_group=$group
   done
   ```
5. Run `site` once more: it must report no changes.

## Remove or replace masters

Removal also happens **in pairs** (5 to 3, 3 to 1), because the list that remains must stay odd. To replace one
master, add two new ones first and then remove the old one together with one of the new ones.

1. Remove the masters from the raft cluster and stop their containers, one at a time:

   ```bash
   ansible-playbook -i examples/inventory andreyhammer.seaweedfs_docker.remove_masters -e target_masters=master04,master05
   ```

   For each master the playbook checks that it is a raft member, runs `cluster.raft.remove` from a master that stays,
   waits until `cluster.raft.ps` no longer lists it and then removes its container. The project directory (compose file
   and raft data) is kept: delete it by hand once you are sure. A single master, or any number that would leave an
   even list, is rejected before anything changes. A **leader cannot remove itself**, so when the master being removed
   is the current leader, the playbook stops it first (the others elect a new leader) and then removes it from the
   list; this needs at least three raft members, otherwise it stops with an explanation and changes nothing.
2. Delete the aliases from the inventory and from `masters_list`.
3. Refresh the other services, as in step 4 of "Add masters" (same version; the leader is restarted last), and run
   `site` once more: it must report no changes.

Tested: going from three masters to five and back to three, with every service refreshed afterwards. **Not tested:**
removing a master whose server is already dead (in a manual probe `cluster.raft.remove` worked for a member whose
container had been stopped, but the playbook cannot reach a dead host to stop its container, so it would fail on that
step; remove the member by hand with `cluster.raft.remove -id <ip>:9333.19333` in `weed shell`). Removing the leader
of a three-or-more-member cluster is tested; the two-member case is only refused.

## Try it safely first

`tests/integration/run.sh test` builds three disposable Debian 12 nodes (each with its own Docker daemon) on your workstation and runs the whole
flow (dry run, deploy, idempotence, variant guard, rolling update) against them. Use it before touching real hosts. It needs
Docker and runs privileged containers, so use a development machine.
