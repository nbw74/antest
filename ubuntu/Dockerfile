# vim: set ft=dockerfile:
ARG UBUNTU_VERSION
FROM docker.io/ubuntu:$UBUNTU_VERSION

WORKDIR /root

ARG PYTHON_VERSION

# hadolint ignore=DL3008
RUN set -eux; \
    apt-get update; \
    apt-get --yes --no-install-recommends \
	install \
	bash-completion \
	bzip2 \
	iproute2 \
	openssh-server \
	"python$PYTHON_VERSION" \
	sudo \
	systemd \
	; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    ssh-keygen -A; \
    sed -i -r 's/^.*Port 22.*$/Port 2222/' /etc/ssh/sshd_config; \
    systemctl enable ssh.service; \
    useradd -mG sudo ansible; \
    mkdir -m 0700 /home/ansible/.ssh; \
    chown ansible:ansible /home/ansible/.ssh; \
    echo "%sudo ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/sudo

COPY --chown=ansible:ansible id_ed25519.pub /home/ansible/.ssh/authorized_keys

RUN set -eux; \
    chmod 0600 /home/ansible/.ssh/authorized_keys

CMD ["/lib/systemd/systemd"]
