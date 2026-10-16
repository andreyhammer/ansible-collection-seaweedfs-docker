# Test "node": a Docker-in-Docker container that behaves like a Debian-style host for this collection
# (sshd, python, findmnt, docker + compose plugin, mounted data disks).
FROM docker:dind

RUN apk add --no-cache openssh python3 findmnt util-linux procps \
    && echo "root:$(head -c 24 /dev/urandom | base64)" | chpasswd \
    && printf 'PermitRootLogin prohibit-password\nPasswordAuthentication no\n' >> /etc/ssh/sshd_config

COPY entrypoint.sh /test-entrypoint.sh
ENV DOCKER_TLS_CERTDIR=""
ENTRYPOINT ["/test-entrypoint.sh"]
CMD []
