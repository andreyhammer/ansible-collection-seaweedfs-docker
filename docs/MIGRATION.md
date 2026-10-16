# Upgrades and migrations

## Upgrading SeaweedFS

Use the rolling update. It changes the image tag one container at a time and stops at the first failure.

```bash
# Order (one group per run): master, filer, admin, volume, worker
for group in master filer admin volume worker; do
  ansible-playbook -i inventory/production andreyhammer.seaweedfs_docker.rolling_update \
    -e seaweed_version=<new> -e target_group=$group
done
```

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
- Each step waits for the node to be back in the cluster before moving on.
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
