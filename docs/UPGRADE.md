# Upgrades and migrations

## Upgrading SeaweedFS

Use the rolling update. It changes the image tag one container at a time and stops at the first failure. An instance whose
container already runs the requested image (and is running) is skipped, so a run that stopped half way can be repeated
without going through the servers that are done again; `-e rolling_update_force=true` goes through them anyway. Changing
settings is the job of `site`, not of the rolling update.

### Step by step

Everything below runs from the control node. `<new>` is the release you are moving to, for example `4.53`.

**1. Prepare**

- Read the release notes of every release between the running one and `<new>` (GitHub releases page of
  seaweedfs/seaweedfs). Look for changed flags, changed defaults and anything that changes what the EC, vacuum or
  balance workers do on their own after the restart.
- Make sure the collection on the control node is the version you intend to use and that the secrets are exported
  exactly as for `site` (`SEAWEED_ADMIN_PASSWORD` and so on; see `docs/INSTALL.md`).
- Check the cluster before touching it: every master and volume server is listed (the master UI, or `cluster.check`
  in `weed shell`), no server is already in maintenance mode, and the EC and replication jobs in the admin UI are not
  failing. An upgrade of a cluster that is already unhealthy makes it harder to tell what the upgrade broke.
- Take backups of the data you cannot lose (the collection does not).
- Optional: pause the EC encoding and balance jobs in the admin UI for the time of the upgrade, so that a volume
  server is not restarted in the middle of a shard move. This is not done by the collection.

**2. Dry run**

```bash
ansible-playbook -i <inventory> andreyhammer.seaweedfs_docker.rolling_update \
  -e seaweed_version=<new> -e target_group=master --check
```

Expect only the image tag to differ. Any other difference means the inventory and the running cluster have drifted
apart: find out why before going on. `seaweed_large_disk` must be the same as for the running containers; the run
stops before changing anything if it is not.

**3. Upgrade, one group per run**

Order: `master`, `filer`, `admin`, `volume`, `worker`. Check the result of each group before starting the next one.

```bash
ansible-playbook -i <inventory> andreyhammer.seaweedfs_docker.rolling_update \
  -e seaweed_version=<new> -e target_group=master
```

Repeat with `-e target_group=filer`, `admin`, `volume` and `worker`. What to look at:

| Group | What the run does | What to check afterwards |
|---|---|---|
| `master` | one master at a time, the leader last | `http://<master>:9333/cluster/status` lists all masters and one leader |
| `filer` | one filer at a time | the filer and S3 ports answer; a test upload and download work |
| `admin` | the admin server | the admin UI opens and lists all workers |
| `volume` | before the first server is touched, every data and index directory is read (a disk that does not answer stops the run); then per server: maintenance mode on, upgrade, wait for the port, the registration and the EC shards, maintenance mode off, next server | the master lists every volume server; no volume is read-only that was not before |
| `worker` | one worker at a time | the workers reconnect to the admin server |

The volume group is the slow one: each server waits until the master lists its EC shards again
(`volume_ec_register_timeout`, `volume_ec_settle_seconds`) before the next one is touched. Do not interrupt it.

**4. If a run fails**

The run stops at the first failed instance and the others are not touched. Read the message: it says what failed, including the directory or item that failed. A
volume server stays in maintenance mode after a failure, and the message gives the command to switch it off. Fix the
cause and run the same command again; the roles are idempotent, so instances that are already on `<new>` are not
recreated. Do not start the next group while a previous one is half done.

**5. Finish**

- Set `seaweed_version: "<new>"` in the inventory (or `group_vars`). The playbook reminds you, because the version
  came from the command line.
- Run `site --check`. It must report no changes.
- Check the running versions, for example with `docker exec <container> weed version` or the version column of the
  admin UI, and look at the logs of the first servers that were restarted.
- Resume the jobs you paused. After an upgrade the EC balance and vacuum workers may start moving data, so watch the
  load and the memory of the volume servers for the first hours.

**Rolling back.** There is no tested downgrade procedure. The collection refuses to replace a container with an older
release (`seaweed_allow_downgrade: false`), because a stale `seaweed_version` must not roll a cluster back. Whether a
newer release has changed the on-disk formats is stated in its release notes, so read them before upgrading. Only
set `seaweed_allow_downgrade: true` for a rollback you have tested on a copy of the data.

### How it works

- **Masters:** the current leader is detected through `/cluster/status` and upgraded last.
- **Volume servers:** maintenance mode is switched on before and off after each upgrade, using
  `volumeServer.state` through `weed shell` in a master container. While it is on, the master stops assigning new
  writes to that server (verified: a server that received about a third of the writes received none) and brings it back
  into the rotation when the mode is switched off. It is not a hard write block: a write sent directly to the server
  for a volume it already holds is still accepted. Reads are not affected.
- If an upgrade fails, the run stops at the first instance and the others are not touched. The failed instance keeps
  running its previous container, but a volume server stays in maintenance mode; the error message says so and gives
  the command. Re-running the update (same or new version) switches it off again, or do it by hand:
  `volumeServer.state -nodes <ip:port> -maintenanceOff` in `weed shell`. Both the stop and the recovery are covered
  by the integration tests.
- Each step waits for the node to be back in the cluster before moving on. For a volume server that also means its
  erasure coding shards: after the restart the role waits until the master has stopped listing more EC shards for the server (the
  number is not zero and did not change for `volume_ec_settle_seconds`, 60 s). The shards are registered by the
  server's heartbeat, which can come minutes after the server itself appears. The number before the restart is not the
  target, because the cluster moves and expires shards while the server is down. If the registration is not over within
  `volume_ec_register_timeout` (300 s) the update stops before the next server is touched, so two servers holding
  shards of the same EC volume are never down at once. The server stays in maintenance mode, as after any other
  failure. Covered by an integration test (a server that lost a shard still comes back and the run reports the lower number).
- Keep `seaweed_large_disk` unchanged. Take backups of the data you cannot lose before the first production upgrade;
  the collection does not do it for you.

Rehearse the upgrade on the test stand first (`tests/integration/run.sh test` upgrades a throwaway cluster).

## Switching between the regular and the large_disk image

The two builds are not interchangeable for existing data, so the collection refuses to do it:

- `seaweed_large_disk` must be set explicitly.
- Before any container is created or recreated, the roles compare the running image with the requested one and fail
  if the variant would change. The rolling update therefore stops on the first host, before anything is modified.

Setting `seaweed_allow_variant_change: true` disables the check. Only do it for a migration you have designed and
tested on a copy of the data: no migration procedure is provided or tested here.

## Taking over a cluster that was deployed by hand

Not tested. If you try it, do it on a copy first and note the following:

- Container names must follow the naming scheme (`master01`, `volume01-dg01`, ...). `docker compose` will not adopt
  an existing container with the same name that it did not create, so the old containers have to be stopped and
  removed first. That means downtime for the instance, one instance at a time.
- Data and index directories keep their contents, but they must be owned by the container user
  (`volume_container_uid` / `volume_container_gid`, 1000 for the official image). The volume role checks this before
  starting a container and stops at the first offending file; `-e volume_fix_ownership=true` repairs it with a
  recursive chown (tested on a tiny disk only, it can take long on full ones).
- The ports and the master `-peers` list must match what the roles generate, or the cluster will not re-form.
- Use the same image build the data was written with (`seaweed_large_disk`).

## Upgrading the collection itself

Follow `CHANGELOG.md`. Re-run `site` afterwards: it is idempotent, so on an unchanged cluster it reports no changes.
A run that reports changes shows exactly what the new version would alter in the generated `compose.yaml` files;
changed files recreate the affected containers.
