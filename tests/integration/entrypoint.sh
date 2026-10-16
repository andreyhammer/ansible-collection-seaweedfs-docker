#!/bin/sh
set -eu

# Ten tmpfs "disks" so the common role's mount checks see real mount points.
for i in 01 02 03 04 05 06 07 08 09 10; do
    mkdir -p "/mnt/disk${i}"
    mountpoint -q "/mnt/disk${i}" || mount -t tmpfs -o size=2g tmpfs "/mnt/disk${i}"
done

mkdir -p /root/.ssh
cp /tmp/authorized_key.pub /root/.ssh/authorized_keys
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys
ssh-keygen -A >/dev/null
/usr/sbin/sshd

exec dockerd-entrypoint.sh "$@"
