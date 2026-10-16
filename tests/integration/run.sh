#!/usr/bin/env bash
# Integration tests on disposable Docker-in-Docker nodes. Nothing here touches real hosts.
#
#   ./run.sh test     full run: up, deploy, verify, idempotence, rolling update, down
#   ./run.sh up|deploy|verify|idempotence|dryrun|guard|update|down|shell <node>
#
# Env: KEEP=1 keeps the nodes after `test`.
#      SEAWEED_TEST_LARGE_DISK=1 tests the official large_disk build instead of the regular one.
#      SEAWEED_TEST_IMAGE overrides the source image copied into the nodes.
set -euo pipefail

cd "$(dirname "$0")"
HERE=$PWD
WORK=$HERE/.work
NODES=(node01 node02 node03)
if [[ ${SEAWEED_TEST_LARGE_DISK:-0} == 1 ]]; then
    TAG_SUFFIX=_large_disk
    EXTRA_VARS=(-e seaweed_large_disk=true)
else
    TAG_SUFFIX=
    EXTRA_VARS=(-e seaweed_large_disk=false)
fi
SEAWEED_TEST_IMAGE=${SEAWEED_TEST_IMAGE:-chrislusf/seaweedfs:latest${TAG_SUFFIX}}
COLLECTION=andreyhammer.seaweedfs_docker

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

up() {
    prepare
    log "Starting test nodes"
    docker compose up -d --build
    for n in "${NODES[@]}"; do
        printf 'waiting for dockerd on %s ' "$n"
        until docker exec "swfs-test-$n" docker info >/dev/null 2>&1; do printf '.'; sleep 2; done
        echo ok
    done
    log "Loading $SEAWEED_TEST_IMAGE into the nodes as test-a / test-b (suffix: ${TAG_SUFFIX:-none})"
    docker image inspect "$SEAWEED_TEST_IMAGE" >/dev/null 2>&1 || docker pull "$SEAWEED_TEST_IMAGE"
    for n in "${NODES[@]}"; do
        if ! docker exec "swfs-test-$n" docker image inspect chrislusf/seaweedfs:test-a${TAG_SUFFIX} >/dev/null 2>&1; then
            docker save "$SEAWEED_TEST_IMAGE" | docker exec -i "swfs-test-$n" docker load
            docker exec "swfs-test-$n" docker tag "$SEAWEED_TEST_IMAGE" "chrislusf/seaweedfs:test-a${TAG_SUFFIX}"
            docker exec "swfs-test-$n" docker tag "$SEAWEED_TEST_IMAGE" "chrislusf/seaweedfs:test-b${TAG_SUFFIX}"
        fi
    done
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
}

idempotence() {
    log "Idempotence: second site.yml run must change nothing"
    local out
    out=$(ansible-playbook "$COLLECTION.site" "${EXTRA_VARS[@]}" | tee /dev/stderr)
    if grep -E 'changed=[1-9]' <<<"$out" >/dev/null; then
        echo "FAIL: second run reported changes" >&2
        return 1
    fi
    echo "OK: no changes on the second run"
}

update() {
    # Upgrade order: masters, filer, admin, volume, workers; one group per invocation.
    local group
    for group in master filer admin volume worker; do
        log "Rolling update ${group} -> test-b${TAG_SUFFIX}"
        ansible-playbook "$COLLECTION.rolling_update" "${EXTRA_VARS[@]}" -e seaweed_version=test-b -e "target_group=${group}"
    done
}

running_containers() {
    local n total=0
    for n in "${NODES[@]}"; do
        total=$((total + $(docker exec "swfs-test-$n" docker ps -a -q | wc -l)))
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
    out=$(ansible-playbook "$COLLECTION.site" "${EXTRA_VARS[@]}" --check | tee /dev/stderr)
    if grep -E 'changed=[1-9]' <<<"$out" >/dev/null; then
        echo "FAIL: --check reported changes for an unchanged config" >&2
        return 1
    fi
    out=$(ansible-playbook "$COLLECTION.site" "${EXTRA_VARS[@]}" -e seaweed_version=test-b --check | tee /dev/stderr)
    grep -E 'changed=[1-9]' <<<"$out" >/dev/null || { echo "FAIL: --check did not report the version change" >&2; return 1; }
    verify test-a
    echo "OK: --check reports changes without applying them"
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
    guard) guard ;;
    update) update ;;
    down) down ;;
    shell) docker exec -it "swfs-test-${2:?node name, e.g. node01}" sh ;;
    test)
        [[ ${KEEP:-0} == 1 ]] || trap down EXIT
        up
        dryrun_fresh
        deploy
        verify test-a
        idempotence
        dryrun_live
        guard
        update
        verify test-b
        log "ALL TESTS PASSED"
        ;;
    *) sed -n '2,8p' "$0"; exit 2 ;;
esac
