#!/bin/sh
set -eu

# Debian test node: ten tmpfs "disks" (so the common role sees real mount points), sshd for Ansible and a nested Docker daemon.

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

exec dind dockerd --host=unix:///var/run/docker.sock "$@"
