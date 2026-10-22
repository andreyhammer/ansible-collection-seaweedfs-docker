# Test "node": a Debian host (the platform the tests run on) with sshd, python, findmnt and a
# Docker-in-Docker daemon with the compose plugin, plus mounted data disks (see entrypoint.sh).
FROM docker:dind AS dind-src

FROM debian:bookworm
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg openssh-server python3 util-linux procps iproute2 iptables kmod \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" \
        > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /run/sshd \
    && echo "root:$(head -c 24 /dev/urandom | base64)" | chpasswd \
    && printf 'PermitRootLogin prohibit-password\nPasswordAuthentication no\nUsePAM no\n' >> /etc/ssh/sshd_config

# The helper that prepares cgroups for a nested dockerd (the same one the official docker:dind image uses).
COPY --from=dind-src /usr/local/bin/dind /usr/local/bin/dind
COPY entrypoint.sh /test-entrypoint.sh

VOLUME /var/lib/docker
ENTRYPOINT ["/test-entrypoint.sh"]
CMD []
