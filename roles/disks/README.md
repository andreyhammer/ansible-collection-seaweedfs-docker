# disks

Formats blank disks with XFS, mounts them by label and writes `/etc/fstab`. Formatting is off by default (`disks_format: false`) and any disk that already has a signature stops the run. Used by the `prepare_disks` playbook.

Main variables: `disks_filesystems` (device by stable name, label, mount), `disks_format`, `disks_mount_options`.

All options with their defaults are in `defaults/main.yml`; see `docs/CONFIGURATION.md` in the collection for the full
reference and `docs/INSTALL.md` for how to run it. The role is meant to be used through the collection's playbooks
(`site`, `rolling_update`, `add_node`, ...).
