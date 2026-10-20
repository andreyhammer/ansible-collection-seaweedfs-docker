#!/usr/bin/env bash
# Integration tests on disposable Docker-in-Docker nodes. Nothing here touches real hosts.
#
#   ./run.sh test     full run: up, deploy, verify, idempotence, rolling update, down
#   ./run.sh up|deploy|verify|idempotence|dryrun|addnode|masters|removemasters|ecshards|maintenance|failpath|guard|disks|compose|update|down|shell <node>
#
# Env: KEEP=1 keeps the nodes after `test`.
#      SEAWEED_TEST_LARGE_DISK=1 tests the official large_disk build instead of the regular one.
#      SEAWEED_TEST_IMAGE overrides the source image copied into the nodes.
set -euo pipefail

cd "$(dirname "$0")"
HERE=$PWD
WORK=$HERE/.work
NODES=(node01 node02 node03 node04 node05)   # node04 is "new hardware" added with add_node, node05 only hosts a master
MASTER_NODES=(node01 node02 node03)
if [[ ${SEAWEED_TEST_LARGE_DISK:-0} == 1 ]]; then
    TAG_SUFFIX=_large_disk
    EXTRA_VARS=(-e seaweed_large_disk=true)
else
    TAG_SUFFIX=
    EXTRA_VARS=(-e seaweed_large_disk=false)
fi
SEAWEED_TEST_IMAGE=${SEAWEED_TEST_IMAGE:-chrislusf/seaweedfs:latest${TAG_SUFFIX}}
COLLECTION=andreyhammer.seaweedfs_docker

# Throwaway credentials for the disposable stand only.
export SEAWEED_ADMIN_PASSWORD=${SEAWEED_ADMIN_PASSWORD:-test-admin-pass}
export SEAWEED_FILER_POSTGRES_PASSWORD=${SEAWEED_FILER_POSTGRES_PASSWORD:-test-pg-pass}
POSTGRES_TEST_IMAGE=${POSTGRES_TEST_IMAGE:-postgres:17-alpine}

export ANSIBLE_CONFIG=$HERE/ansible.cfg
export ANSIBLE_COLLECTIONS_PATH=$WORK/ac

log() { printf '\n==> %s\n' "$*"; }

prepare() {
    mkdir -p "$WORK/ac/ansible_collections/andreyhammer"
    ln -sfn "$(cd ../.. && pwd)" "$WORK/ac/ansible_collections/andreyhammer/seaweedfs_docker"
    [[ -f $WORK/id_ed25519 ]] || ssh-keygen -q -t ed25519 -N '' -f "$WORK/id_ed25519"
    if [[ ! -d $WORK/ac/ansible_collections/community/docker || ! -d $WORK/ac/ansible_collections/ansible/posix ]]; then
        ansible-galaxy collection install -r ../../requirements.yml -p "$WORK/ac"
    fi
}

# PostgreSQL metadata store for the filer, run inside node01 (published on the node IP, port 5432).
start_postgres() {
    log "Starting PostgreSQL ($POSTGRES_TEST_IMAGE) for the filer on node01"
    docker image inspect "$POSTGRES_TEST_IMAGE" >/dev/null 2>&1 || docker pull "$POSTGRES_TEST_IMAGE"
    if ! docker exec swfs-test-node01 docker image inspect "$POSTGRES_TEST_IMAGE" >/dev/null 2>&1; then
        docker save "$POSTGRES_TEST_IMAGE" | docker exec -i swfs-test-node01 docker load
    fi
    if ! docker exec swfs-test-node01 docker inspect postgres >/dev/null 2>&1; then
        docker exec swfs-test-node01 docker run -d --name postgres --restart unless-stopped -p 5432:5432 \
            -e POSTGRES_USER=seaweedfs -e POSTGRES_DB=seaweedfs -e "POSTGRES_PASSWORD=$SEAWEED_FILER_POSTGRES_PASSWORD" \
            "$POSTGRES_TEST_IMAGE" >/dev/null
    fi
    until docker exec swfs-test-node01 docker exec postgres pg_isready -U seaweedfs >/dev/null 2>&1; do sleep 1; done
    echo "  postgres ready"
}

up() {
    prepare
    log "Starting test nodes"
    docker compose up -d --build
    for n in "${NODES[@]}"; do
        printf 'waiting for dockerd on %s ' "$n"
        until docker exec "swfs-test-$n" docker info >/dev/null 2>&1; do printf '.'; sleep 2; done
        echo ok
    done
    echo "  node OS: $(docker exec swfs-test-node01 sh -c '. /etc/os-release && echo "$PRETTY_NAME"'), $(docker exec swfs-test-node01 docker version --format '{{.Server.Version}}' | sed 's/^/docker /')"
    log "Loading $SEAWEED_TEST_IMAGE into the nodes as test-a / test-b (suffix: ${TAG_SUFFIX:-none})"
    docker image inspect "$SEAWEED_TEST_IMAGE" >/dev/null 2>&1 || docker pull "$SEAWEED_TEST_IMAGE"
    for n in "${NODES[@]}"; do
        if ! docker exec "swfs-test-$n" docker image inspect chrislusf/seaweedfs:test-a${TAG_SUFFIX} >/dev/null 2>&1; then
            docker save "$SEAWEED_TEST_IMAGE" | docker exec -i "swfs-test-$n" docker load
            docker exec "swfs-test-$n" docker tag "$SEAWEED_TEST_IMAGE" "chrislusf/seaweedfs:test-a${TAG_SUFFIX}"
            docker exec "swfs-test-$n" docker tag "$SEAWEED_TEST_IMAGE" "chrislusf/seaweedfs:test-b${TAG_SUFFIX}"
        fi
    done
    start_postgres
    ansible all --list-hosts >/dev/null
    ansible seaweed -m ansible.builtin.ping | grep -c SUCCESS | sed "s/^/  reachable aliases: /"
}

deploy() {
    log "Deploy (site.yml)"
    ansible-playbook "$COLLECTION.site" "${EXTRA_VARS[@]}" "$@"
}

verify() {
    log "Verify (expect_version=${1:-test-a})"
    ansible-playbook verify.yml "${EXTRA_VARS[@]}" -e "expect_version=${1:-test-a}"
    verify_services
}

fail() { echo "FAIL: $*" >&2; return 1; }

# Checks that go beyond "the port is open": admin authentication, filer metadata in PostgreSQL, S3.
verify_services() {
    log "Verify services: admin authentication, filer + PostgreSQL, S3"
    local admin=http://172.29.14.11:23646 filer=http://172.29.14.11:8888 s3=http://172.29.14.11:8333
    local code jar html token name bucket

    # Admin: closed without a session, opens with the right password only.
    code=$(curl -s -o /dev/null -w '%{http_code}' "$admin/admin")
    [[ $code == 307 ]] || fail "admin answered $code without credentials, expected a redirect to /login" || return 1
    for pw in "$SEAWEED_ADMIN_PASSWORD" wrong-password; do
        jar=$(mktemp)
        html=$(curl -s -c "$jar" "$admin/login")
        token=$(grep -oE 'name="csrf_token"[^>]*value="[^"]+"|value="[^"]+"[^>]*name="csrf_token"' <<<"$html" \
            | grep -oE 'value="[^"]+"' | head -1 | sed 's/^value="//; s/"$//')
        curl -s -b "$jar" -c "$jar" -o /dev/null --data-urlencode username=admin --data-urlencode "password=$pw" \
            --data-urlencode "csrf_token=$token" "$admin/login"
        code=$(curl -s -b "$jar" -o /dev/null -w '%{http_code}' "$admin/admin")
        rm -f "$jar"
        if [[ $pw == "$SEAWEED_ADMIN_PASSWORD" ]]; then
            [[ $code == 200 ]] || fail "admin login with the right password failed ($code)" || return 1
        else
            [[ $code == 307 ]] || fail "admin accepted a wrong password ($code)" || return 1
        fi
    done
    echo "  OK admin: protected, right password accepted, wrong one rejected"

    # Filer: data round trip, and the metadata must really be in PostgreSQL (not in the built-in store).
    name="verify-$(date +%s%N).txt"
    curl -sf -X PUT --data-binary "filer-$name" "$filer/verify/$name" -o /dev/null || fail "filer write failed" || return 1
    [[ $(curl -sf "$filer/verify/$name") == "filer-$name" ]] || fail "filer read-back differs" || return 1
    [[ $(docker exec swfs-test-node01 docker exec postgres psql -U seaweedfs -d seaweedfs -tAc \
        "select count(*) from filemeta where name='$name'") == 1 ]] || fail "$name is not in the PostgreSQL filemeta table" || return 1
    [[ $(curl -sf "http://172.29.14.14:8888/verify/$name") == "filer-$name" ]] || fail "the filer on the new node does not see the file written through the first filer" || return 1
    echo "  OK filer: write/read, metadata row found in PostgreSQL, visible through the filer on the new node"

    # S3 gateway.
    # A fresh bucket per call: verify runs several times on the same cluster and creating an existing bucket is a 409.
    bucket="verify-$(date +%s%N)"
    curl -sf -X PUT "$s3/$bucket" -o /dev/null || fail "S3 create bucket failed" || return 1
    curl -sf -X PUT --data-binary "s3-$name" "$s3/$bucket/$name" -o /dev/null || fail "S3 put failed" || return 1
    [[ $(curl -sf "$s3/$bucket/$name") == "s3-$name" ]] || fail "S3 read-back differs" || return 1
    echo "  OK S3: bucket, put, get"

    # Default replication 010: the two copies of a volume must sit in different racks.
    local rep_fid rep_vid rep_racks
    rep_fid=$(curl -sf "http://172.29.14.11:9333/dir/assign" | python3 -c 'import sys,json;print(json.load(sys.stdin)["fid"])')
    rep_vid=${rep_fid%%,*}
    rep_racks=$(python3 - "$rep_vid" <<'PY'
import json, sys, urllib.request
vid = sys.argv[1]
get = lambda u: json.load(urllib.request.urlopen(u))
urls = [l["url"] for l in get(f"http://172.29.14.11:9333/dir/lookup?volumeId={vid}")["locations"]]
rack_of = {n["Url"]: r["Id"] for dc in get("http://172.29.14.11:9333/dir/status")["Topology"]["DataCenters"]
           for r in dc["Racks"] for n in r["DataNodes"]}
print(len(urls), len({rack_of[u] for u in urls}))
PY
)
    [[ $rep_racks == "2 2" ]] || fail "volume $rep_vid has (copies racks) = $rep_racks, expected 2 copies in 2 racks" || return 1
    echo "  OK replication 010: two copies of volume $rep_vid in different racks"
}

idempotence() {
    log "Idempotence: second site.yml run must change nothing"
    local out
    out=$(ansible-playbook "$COLLECTION.site" "${EXTRA_VARS[@]}" | tee >(cat >&2))
    if grep -E 'changed=[1-9]' <<<"$out" >/dev/null; then
        echo "FAIL: second run reported changes" >&2
        return 1
    fi
    echo "OK: no changes on the second run"
}

# Node name (node01..03) that currently hosts the master leader (nodes are 172.29.14.11-13).
master_leader_node() {
    local ip
    ip=$(curl -sf http://172.29.14.11:9333/cluster/status | python3 -c 'import sys,json;print(json.load(sys.stdin)["Leader"].split(":")[0])')
    printf 'node%02d\n' $((${ip##*.} - 10))
}

# The master that was the leader before the upgrade must have been restarted last.
check_leader_last() {
    local leader=$1 n started latest="" latest_node=""
    for n in "${MASTER_NODES[@]}"; do
        started=$(docker exec "swfs-test-$n" docker inspect -f '{{.State.StartedAt}}' "master${n#node}")
        echo "  master${n#node} restarted at $started$([[ $n == "$leader" ]] && echo '  <- leader before the upgrade')"
        if [[ -z $latest || $started > $latest ]]; then latest=$started; latest_node=$n; fi
    done
    [[ $latest_node == "$leader" ]] || fail "the leader ($leader) was not upgraded last (last was $latest_node)" || return 1
    echo "  OK the leader ($leader) was upgraded last"
}

# One rolling_update per group, in the documented order; the master leader must be restarted last.
rolling_all() {
    local version=$1 group leader_before
    for group in master filer admin volume worker; do
        [[ $group == master ]] && leader_before=$(master_leader_node)
        log "Rolling update ${group} -> ${version}${TAG_SUFFIX}"
        ansible-playbook "$COLLECTION.rolling_update" "${EXTRA_VARS[@]}" -e "seaweed_version=${version}" -e "target_group=${group}"
        [[ $group == master ]] && check_leader_last "$leader_before"
    done
    return 0
}

update() {
    rolling_all test-b
}

# Add two masters (SeaweedFS needs an odd number): new masters join by themselves, the existing services are then
# refreshed one by one so that they all know the new list.
add_masters() {
    local out peers
    log "Add masters: an even masters_list must be rejected"
    if out=$(ansible-playbook "$COLLECTION.add_node" "${EXTRA_VARS[@]}" -i "$HERE/inventory/hosts.yml" -i "$HERE/inventory-masters/hosts.yml" \
        -e target_node=master04 -e '{"masters_list":["172.29.14.11:9333","172.29.14.12:9333","172.29.14.13:9333","172.29.14.14:9333"]}' 2>&1); then
        fail "a four-master list was accepted" || return 1
    fi
    grep -q 'refuses to start masters with an even list' <<<"$out" || { tail -15 <<<"$out" >&2; fail "rejected, but not for the right reason" || return 1; }
    echo "OK: an even number of masters is rejected"

    log "Add masters: master04 (on node04) and master05 (on the new node05) join the running cluster"
    export ANSIBLE_INVENTORY="$HERE/inventory/hosts.yml,$HERE/inventory-masters/hosts.yml"
    EXTRA_VARS+=(-e "@$HERE/inventory-masters/masters5.yml")
    MASTER_NODES+=(node04 node05)
    ansible-playbook "$COLLECTION.add_node" "${EXTRA_VARS[@]}" -e target_node=master04,master05
    peers=$(curl -sf http://172.29.14.11:9333/cluster/status | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["Peers"])+1)')
    [[ $peers == 5 ]] || fail "the cluster has $peers masters, expected 5" || return 1
    echo "  OK the cluster has 5 masters"

    log "Add masters: refresh the existing services so that they use the new list (leader last)"
    rolling_all test-a
    verify test-a
}

running_containers() {
    local n total=0
    for n in "${NODES[@]}"; do
        total=$((total + $(docker exec "swfs-test-$n" docker ps -a --format '{{.Names}}' | grep -vxc postgres)))
    done
    echo "$total"
}

dryrun_fresh() {
    log "Dry run (--check) on empty nodes must succeed and create nothing"
    ansible-playbook "$COLLECTION.site" "${EXTRA_VARS[@]}" --check
    [[ $(running_containers) == 0 ]] || { echo "FAIL: --check created containers" >&2; return 1; }
    echo "OK: --check on empty nodes changed nothing"
}

dryrun_live() {
    log "Dry run (--check) on the live cluster: no changes for the same config, changes reported for a new version"
    local out
    out=$(ansible-playbook "$COLLECTION.site" "${EXTRA_VARS[@]}" --check | tee >(cat >&2))
    if grep -E 'changed=[1-9]' <<<"$out" >/dev/null; then
        echo "FAIL: --check reported changes for an unchanged config" >&2
        return 1
    fi
    out=$(ansible-playbook "$COLLECTION.site" "${EXTRA_VARS[@]}" -e seaweed_version=test-b --check | tee >(cat >&2))
    grep -E 'changed=[1-9]' <<<"$out" >/dev/null || { echo "FAIL: --check did not report the version change" >&2; return 1; }
    verify test-a
    echo "OK: --check reports changes without applying them"
}

# --- helpers for the maintenance mode, add_node and failure-path tests -------------------------------------
VOLUME_SERVERS=(172.29.14.11:8081 172.29.14.11:8082 172.29.14.12:8081 172.29.14.12:8082 172.29.14.13:8081 172.29.14.13:8082
                172.29.14.14:8081 172.29.14.14:8082)

weed_shell() { docker exec -i swfs-test-node01 docker exec -i master01 weed shell -master=172.29.14.11:9333 2>&1; }

# yes|no
maintenance_state() {
    weed_shell <<<"volumeServer.state -nodes $1" | sed -n 's/.*Maintenance mode: *//p' | head -1
}

# "<count> <volume server url>" for 60 write assignments
assign_distribution() {
    local i
    for i in $(seq 1 60); do
        curl -s "http://172.29.14.11:9333/dir/assign?count=1" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("url","none"))'
    done | sort | uniq -c | sort -rn
}

deploy_partial() {
    log "Deploy everything except new hardware (node04) and two aliases on an existing node (added later with add_node)"
    ansible-playbook "$COLLECTION.site" "${EXTRA_VARS[@]}" --limit 'all:!node04:!node05:!volume03-dg02:!worker02-vacuum01'
}

add_nodes() {
    local out
    log "add_node without target_node must be rejected"
    if out=$(ansible-playbook "$COLLECTION.add_node" "${EXTRA_VARS[@]}" 2>&1); then
        fail "add_node ran without target_node" || return 1
    fi
    grep -q 'Pass the inventory alias' <<<"$out" || { tail -15 <<<"$out" >&2; fail "add_node failed for another reason" || return 1; }
    echo "OK: add_node requires target_node"

    log "add_node: add a volume server and a worker on an existing node"
    ansible-playbook "$COLLECTION.add_node" "${EXTRA_VARS[@]}" -e 'target_node=volume03-dg02,worker02-vacuum01'

    log "add_node: add a brand-new node (node04: filer, two volume servers, a worker) by its group name"
    ansible-playbook "$COLLECTION.add_node" "${EXTRA_VARS[@]}" -e target_node=node04
}

# Maintenance mode must take a volume server out of the write rotation, and switching it off must bring it back.
maintenance_effect() {
    log "Maintenance mode: the server leaves the write rotation and returns afterwards"
    local target before after i
    target=$(assign_distribution | awk 'NR==1{print $2}')
    before=$(assign_distribution | awk -v t="$target" '$2==t{print $1}')
    [[ ${before:-0} -gt 0 ]] || fail "no writes are assigned to $target even without maintenance mode" || return 1
    weed_shell <<<"lock; volumeServer.state -nodes $target -maintenanceOn; unlock" >/dev/null
    [[ $(maintenance_state "$target") == yes ]] || fail "maintenance mode did not turn on for $target" || return 1
    sleep 8
    after=$(assign_distribution | awk -v t="$target" '$2==t{print $1}')
    [[ ${after:-0} -eq 0 ]] || fail "$target still received $after of 60 writes in maintenance mode" || return 1
    echo "  OK $target: $before of 60 writes before, 0 in maintenance mode"
    weed_shell <<<"lock; volumeServer.state -nodes $target -maintenanceOff; unlock" >/dev/null
    [[ $(maintenance_state "$target") == no ]] || fail "maintenance mode did not turn off for $target" || return 1
    for i in $(seq 1 15); do
        after=$(assign_distribution | awk -v t="$target" '$2==t{print $1}')
        [[ ${after:-0} -gt 0 ]] && { echo "  OK $target is back in the write rotation ($after of 60)"; return 0; }
        sleep 4
    done
    fail "$target did not return to the write rotation after maintenance mode" || return 1
}

# An upgrade that fails must stop the run at the first instance, leave the cluster serving, and be recoverable.
failpath() {
    log "Failure path: an upgrade to a missing image tag stops at the first volume server"
    local out s hosts_run
    if out=$(ansible-playbook "$COLLECTION.rolling_update" "${EXTRA_VARS[@]}" -e seaweed_version=no-such-tag -e target_group=volume 2>&1); then
        fail "the upgrade to a missing tag succeeded" || return 1
    fi
    grep -q 'the rolling update is stopped' <<<"$out" || { tail -20 <<<"$out" >&2; fail "no stop message" || return 1; }
    grep -q 'maintenanceOff' <<<"$out" || fail "the error message does not tell how to leave maintenance mode" || return 1
    hosts_run=$(awk '/PLAY RECAP/{r=1;n=0;next} r&&/ : ok=[1-9]/{n++} END{print n}' <<<"$out")
    [[ $hosts_run == 1 ]] || fail "$hosts_run hosts were touched, expected only the first" || return 1
    echo "  OK stopped at the first volume server (the others were not touched)"
    verify test-a
    [[ $(maintenance_state "${VOLUME_SERVERS[0]}") == yes ]] || fail "expected the failed server to stay in maintenance mode" || return 1
    echo "  OK the failed server is still in maintenance mode, as documented"

    log "Failure path: re-running the update recovers the cluster"
    ansible-playbook "$COLLECTION.rolling_update" "${EXTRA_VARS[@]}" -e seaweed_version=test-a -e target_group=volume
    for s in "${VOLUME_SERVERS[@]}"; do
        [[ $(maintenance_state "$s") == no ]] || fail "$s is still in maintenance mode after the re-run" || return 1
    done
    echo "  OK all volume servers are out of maintenance mode"
    verify test-a
}

# Remove the two extra masters again (5 -> 3) and refresh every service with the shorter list.
remove_masters() {
    local out
    export ANSIBLE_INVENTORY="$HERE/inventory/hosts.yml,$HERE/inventory-masters/hosts.yml"
    log "Remove masters: removing a single master (an even list would remain) must be rejected"
    if out=$(ansible-playbook "$COLLECTION.remove_masters" "${EXTRA_VARS[@]}" -e target_masters=master05 2>&1); then
        fail "removing one of five masters was accepted" || return 1
    fi
    grep -q 'Remove masters in pairs' <<<"$out" || { tail -15 <<<"$out" >&2; fail "rejected, but not for the right reason" || return 1; }
    echo "  OK removing a single master is rejected"

    log "Remove masters: master04 and master05 leave the raft cluster (one of them is made the leader first)"
    local leader_ip i
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        leader_ip=$(weed_shell <<<"cluster.raft.ps" | sed -n 's/^ *\* \(172\.29\.14\.[0-9]*\):.*(Leader).*/\1/p')
        [[ $leader_ip == 172.29.14.14 || $leader_ip == 172.29.14.15 ]] && break
        echo "  leader is ${leader_ip:-unknown}, restarting it to get another election"
        [[ -n $leader_ip ]] && docker exec "swfs-test-node0$((${leader_ip##*.} - 10))" docker restart "master0$((${leader_ip##*.} - 10))" >/dev/null
        sleep 15
    done
    [[ $leader_ip == 172.29.14.14 || $leader_ip == 172.29.14.15 ]] || fail "could not make master04 or master05 the leader" || return 1
    echo "  leader before the removal: $leader_ip"
    out=$(ansible-playbook "$COLLECTION.remove_masters" "${EXTRA_VARS[@]}" -e target_masters=master04,master05 2>&1) \
        || { tail -40 <<<"$out" >&2; fail "remove_masters failed" || return 1; }
    grep -A1 'Stop the leading master' <<<"$out" | grep -q 'changed:' || fail "the leader was not removed through the leader path" || return 1
    echo "  OK the leader was stopped first and then removed"
    weed_shell <<<"cluster.raft.ps" | grep -q 'has 3 servers' || fail "the raft cluster does not have 3 servers" || return 1
    for out in node04:master04 node05:master05; do
        [[ -z $(docker exec "swfs-test-${out%%:*}" docker ps -q --filter "name=^${out##*:}$") ]] \
            || fail "${out##*:} is still running" || return 1
    done
    for out in node04:master04 node05:master05; do
        if docker exec "swfs-test-${out%%:*}" grep -q "${out##*:}/compose.yaml" /opt/seaweed/compose.yaml; then
            fail "${out##*:} is still in the node compose file" || return 1
        fi
    done
    echo "  OK the raft cluster has three servers and the removed containers are gone"

    log "Remove masters: refresh every service with the three-master list"
    export ANSIBLE_INVENTORY="$HERE/inventory/hosts.yml"
    EXTRA_VARS+=(-e '{"masters_list":["172.29.14.11:9333","172.29.14.12:9333","172.29.14.13:9333"]}')
    MASTER_NODES=(node01 node02 node03)
    rolling_all test-b
    verify test-b
}

# EC volumes: a volume server must re-register its erasure coding shards before the next server is touched.
ec_shards() {
    log "EC shards: encode a volume, then a server that lost a shard must stop the upgrade"
    local fid vid out n file alias=""
    fid=$(curl -sf "http://172.29.14.11:9333/dir/assign" | python3 -c 'import sys,json;print(json.load(sys.stdin)["fid"])')
    vid=${fid%%,*}
    head -c 200000 /dev/urandom | curl -sf -F file=@- "http://$(curl -sf "http://172.29.14.11:9333/dir/lookup?volumeId=$vid" \
        | python3 -c 'import sys,json;print(json.load(sys.stdin)["locations"][0]["url"])')/$fid" >/dev/null
    out=$(printf 'lock\nec.encode -volumeId=%s\nunlock\n' "$vid" | weed_shell) || true
    grep -q 'Successfully completed EC encoding' <<<"$out" || { tail -5 <<<"$out" >&2; fail "ec.encode of volume $vid failed" || return 1; }
    sleep 5
    # A shard file on a first-group disk (disk01/disk02) of node01-03 belongs to that node's dg01 volume server.
    for n in 1 2 3; do
        file=$(docker exec "swfs-test-node0$n" sh -c "find /mnt/disk01 /mnt/disk02 -name '$vid.ec[0-9][0-9]' | head -1")
        if [[ -n $file ]]; then alias="volume0$n-dg01"; break; fi
    done
    [[ -n $alias ]] || fail "no shard of volume $vid found on a dg01 disk" || return 1
    echo "  volume $vid is erasure coded; deleting $file on $alias"
    docker exec "swfs-test-node0$n" rm -f "$file"
    if out=$(ansible-playbook "$COLLECTION.rolling_update" "${EXTRA_VARS[@]}" -e seaweed_version=test-b -e target_group=volume \
        -e volume_ec_register_timeout=15 --limit "$alias" 2>&1); then
        fail "the upgrade went on although a shard did not come back" || return 1
    fi
    grep -q 'EC shards registered before the start' <<<"$out" || { tail -20 <<<"$out" >&2; fail "stopped, but not because of the missing shard" || return 1; }
    echo "  OK the upgrade stops when a shard does not come back"
}

guard() {
    log "Guard: switching the image variant on a live cluster must be refused"
    local flipped=true out
    [[ -n $TAG_SUFFIX ]] && flipped=false
    if out=$(ansible-playbook "$COLLECTION.rolling_update" -e "seaweed_large_disk=$flipped" \
        -e seaweed_version=test-b -e target_group=master 2>&1); then
        echo "FAIL: the variant switch was not refused" >&2
        return 1
    fi
    if ! grep -q 'would switch between the regular and the large_disk build' <<<"$out"; then
        echo "FAIL: playbook failed, but not because of the variant guard" >&2
        tail -30 <<<"$out" >&2
        return 1
    fi
    echo "OK: variant switch refused"
    verify test-a

    log "Guard: a missing seaweed_large_disk must be rejected"
    if out=$(ansible-playbook -i localhost, guard_missing.yml 2>&1); then
        echo "FAIL: a missing seaweed_large_disk was accepted" >&2
        return 1
    fi
    grep -q 'Set seaweed_large_disk explicitly' <<<"$out" || { echo "FAIL: wrong error" >&2; tail -20 <<<"$out" >&2; return 1; }
    echo "OK: missing seaweed_large_disk rejected"
}

# One Compose project per node: the node compose file lists every container, works by hand, and containers made by
# earlier versions of the roles (own project per directory, service named after the role) are moved without data loss.
compose() {
    log "Compose: every container of a node is in one project and listed in the node compose file"
    local node name n expected shown
    for n in 1 2 3; do
        node=swfs-test-node0$n
        expected=$(docker exec "$node" docker ps --format '{{.Names}}' | grep -v '^postgres$' | sort | tr '\n' ' ')
        shown=$(docker exec "$node" sh -c 'cd /opt/seaweed && docker compose ps --format "{{.Name}}"' | sort | tr '\n' ' ')
        [[ -n $expected && $expected == "$shown" ]] \
            || fail "$node: docker ps says [$expected], the node compose file shows [$shown]" || return 1
        for name in $expected; do
            [[ $(docker exec "$node" docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$name") == seaweed ]] \
                || fail "$name is not in the project seaweed" || return 1
        done
    done
    echo "  OK all containers are in the project seaweed and listed"

    log "Compose: a container can be restarted by hand through the node compose file"
    local before after
    before=$(docker exec swfs-test-node01 docker inspect -f '{{.State.StartedAt}}' volume01-dg01)
    docker exec swfs-test-node01 sh -c 'cd /opt/seaweed && docker compose restart volume01-dg01' >/dev/null 2>&1
    after=$(docker exec swfs-test-node01 docker inspect -f '{{.State.StartedAt}}' volume01-dg01)
    [[ $before != "$after" ]] || fail "volume01-dg01 was not restarted" || return 1
    echo "  OK restarted by hand"

    log "Compose: a container from an older layout is moved into the shared project, data kept"
    local c=volume02-dg01 dir=/opt/seaweed/volume02-dg01 mark=/mnt/disk01/compose-migration.mark
    docker exec swfs-test-node02 sh -c "touch $mark; chown 1000:1000 $mark; docker rm -f $c >/dev/null; \
        sed -e '/^name: /d' -e 's/^  $c:\$/  volume:/' $dir/compose.yaml > $dir/old.yaml && mv $dir/old.yaml $dir/compose.yaml \
        && cd $dir && docker compose up -d >/dev/null 2>&1"
    [[ $(docker exec swfs-test-node02 docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' $c) == volume02-dg01 ]] \
        || fail "could not recreate the old layout" || return 1
    deploy --limit "$c" -e seaweed_version=test-a
    [[ $(docker exec swfs-test-node02 docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' $c) == seaweed ]] \
        || fail "$c was not moved into the project seaweed" || return 1
    docker exec swfs-test-node02 test -f $mark || fail "data on the disk was lost" || return 1
    docker exec swfs-test-node02 rm -f $mark
    docker exec swfs-test-node02 sh -c 'cd /opt/seaweed && docker compose ps --format "{{.Name}}"' | grep -qx $c \
        || fail "$c is not listed in the node compose file" || return 1
    verify test-a
    echo "  OK moved without losing data"
}

ownership() {
    log "Ownership: a foreign file on a data disk must stop the deployment, and volume_fix_ownership repairs it"
    docker exec swfs-test-node01 sh -c 'touch /mnt/disk01/foreign.dat && chown 0:0 /mnt/disk01/foreign.dat'
    local out
    if out=$(ansible-playbook "$COLLECTION.site" "${EXTRA_VARS[@]}" --limit volume01-dg01 2>&1); then
        echo "FAIL: a foreign file was not detected" >&2
        return 1
    fi
    grep -q 'holds files not owned by 1000:1000' <<<"$out" || { echo "FAIL: wrong error" >&2; tail -20 <<<"$out" >&2; return 1; }
    echo "OK: foreign file detected"
    ansible-playbook "$COLLECTION.site" "${EXTRA_VARS[@]}" --limit volume01-dg01 -e volume_fix_ownership=true
    [[ $(docker exec swfs-test-node01 stat -c %u:%g /mnt/disk01/foreign.dat) == 1000:1000 ]] \
        || { echo "FAIL: ownership was not repaired" >&2; return 1; }
    docker exec swfs-test-node01 rm -f /mnt/disk01/foreign.dat
    echo "OK: ownership repaired"
}

# The disks role on loop devices (node05 is not used by the cluster services): refuses without confirmation, refuses
# foreign data, previews with --check, formats, mounts by label and is idempotent.
disks() {
    log "Disks: format and mount loop devices through /dev/disk/by-id names"
    local n=172.29.14.15 out i
    docker exec swfs-test-node05 sh -c '
        set -e
        mkdir -p /dev/disk/by-id /var/tmp/disks
        for i in 1 2 3; do
            truncate -s 300M /var/tmp/disks/d$i.img
            dev=$(losetup -f)
            [ -b "$dev" ] || mknod "$dev" b 7 "${dev#/dev/loop}"
            losetup "$dev" /var/tmp/disks/d$i.img
            ln -sfn "$dev" /dev/disk/by-id/test-disk$i
        done
        mkfs.ext4 -q -L precious /dev/disk/by-id/test-disk3'
    local vars=(-e target_node=$n -i "$n," -e '{"disks_filesystems": [
        {"device": "/dev/disk/by-id/test-disk1", "label": "tdisk1", "mount": "/mnt/tdisk1"},
        {"device": "/dev/disk/by-id/test-disk2", "label": "tdisk2", "mount": "/mnt/tdisk2"}]}')
    if out=$(ansible-playbook "$COLLECTION.prepare_disks" "${vars[@]}" 2>&1); then
        echo "FAIL: empty disks were formatted without disks_format=true" >&2
        return 1
    fi
    grep -q 'empty disk(s) would be formatted' <<<"$out" || { echo "FAIL: wrong error" >&2; tail -20 <<<"$out" >&2; return 1; }
    echo "OK: nothing is formatted without confirmation"

    if out=$(ansible-playbook "$COLLECTION.prepare_disks" -e target_node=$n -i "$n," -e disks_format=true -e '{"disks_filesystems": [
        {"device": "/dev/disk/by-id/test-disk1", "label": "tdisk1", "mount": "/mnt/tdisk1"},
        {"device": "/dev/disk/by-id/test-disk3", "label": "tdisk3", "mount": "/mnt/tdisk3"}]}' 2>&1); then
        echo "FAIL: a disk with another filesystem was accepted" >&2
        return 1
    fi
    grep -q 'Refusing to continue' <<<"$out" || { echo "FAIL: wrong error" >&2; tail -20 <<<"$out" >&2; return 1; }
    [[ -z $(docker exec swfs-test-node05 blkid -s TYPE -o value /dev/disk/by-id/test-disk1) ]] \
        || { echo "FAIL: a disk was formatted although another one was refused" >&2; return 1; }
    [[ $(docker exec swfs-test-node05 blkid -s LABEL -o value /dev/disk/by-id/test-disk3) == precious ]] \
        || { echo "FAIL: the foreign filesystem was touched" >&2; return 1; }
    echo "OK: a foreign filesystem is refused and nothing else is changed"

    ansible-playbook "$COLLECTION.prepare_disks" "${vars[@]}" -e disks_format=true --check
    [[ -z $(docker exec swfs-test-node05 blkid -s TYPE -o value /dev/disk/by-id/test-disk1) ]] \
        || { echo "FAIL: --check formatted a disk" >&2; return 1; }
    echo "OK: --check formats nothing"

    ansible-playbook "$COLLECTION.prepare_disks" "${vars[@]}" -e disks_format=true
    for i in 1 2; do
        docker exec swfs-test-node05 sh -c "findmnt -n -o SOURCE,FSTYPE /mnt/tdisk$i | grep -q xfs && grep -q 'LABEL=tdisk$i /mnt/tdisk$i xfs defaults,noatime' /etc/fstab" \
            || { echo "FAIL: tdisk$i is not mounted by label or missing in fstab" >&2; return 1; }
    done
    echo "OK: formatted with XFS, mounted by label, listed in fstab"

    out=$(ansible-playbook "$COLLECTION.prepare_disks" "${vars[@]}" 2>&1)
    grep -qE 'changed=0 .*failed=0' <<<"$out" || { echo "FAIL: second run was not idempotent" >&2; tail -20 <<<"$out" >&2; return 1; }
    echo "OK: idempotent"

    docker exec swfs-test-node05 sh -c '
        umount /mnt/tdisk1 /mnt/tdisk2; sed -i "/tdisk[12]/d" /etc/fstab
        for i in 1 2 3; do losetup -d "$(readlink -f /dev/disk/by-id/test-disk$i)"; rm -f /dev/disk/by-id/test-disk$i; done
        rm -rf /var/tmp/disks /mnt/tdisk1 /mnt/tdisk2'
}

down() {
    log "Removing test nodes and volumes"
    docker compose down -v --remove-orphans
}

case ${1:-test} in
    up) up ;;
    deploy) shift; deploy "$@" ;;
    verify) shift; verify "$@" ;;
    idempotence) idempotence ;;
    dryrun) dryrun_fresh; dryrun_live ;;
    addnode) deploy_partial; add_nodes ;;
    maintenance) maintenance_effect ;;
    failpath) failpath ;;
    masters) add_masters ;;
    removemasters) remove_masters ;;
    ecshards) ec_shards ;;
    guard) guard ;;
    disks) disks ;;
    compose) compose ;;
    update) update ;;
    down) down ;;
    shell) docker exec -it "swfs-test-${2:?node name, e.g. node01}" sh ;;
    test)
        [[ ${KEEP:-0} == 1 ]] || trap down EXIT
        up
        dryrun_fresh
        deploy_partial
        add_nodes
        verify test-a
        idempotence
        dryrun_live
        add_masters
        idempotence
        guard
        disks
        compose
        ownership
        maintenance_effect
        failpath
        ec_shards
        update
        verify test-b
        remove_masters
        log "ALL TESTS PASSED"
        ;;
    *) sed -n '2,8p' "$0"; exit 2 ;;
esac
