# vim: set ft=dockerfile:
ARG CENTOS_VERSION
FROM centos:$CENTOS_VERSION

WORKDIR /root

ARG CENTOS_VERSION

# hadolint ignore=DL3033
RUN set -eux; \
    sed -ri -e '/mirrorlist/d' \
	-e "s!^#baseurl.*\$!baseurl=http://vault.centos.org/${CENTOS_VERSION}/os/\$basearch/!g" \
	-e "s!^gpgkey.*\$!gpgkey=http://mirror.centos.org/centos/RPM-GPG-KEY-CentOS-${CENTOS_VERSION%%.*}!g" \
	/etc/yum.repos.d/CentOS-Base.repo; \
    yum -y install \
	iproute \
	openssh-server \
	rsyslog \
	sudo \
	; \
    yum -y clean all

RUN set -eux; \
    sed -ri 's/^.*Port 22.*$/Port 2222/' /etc/ssh/sshd_config; \
    sed -ri 's!^(.*pam_loginuid.so.*)$!# \1!' /etc/pam.d/sshd; \
    chkconfig rsyslog on; \
    chkconfig sshd on; \
    useradd -mG wheel ansible; \
    mkdir -m 0700 /home/ansible/.ssh; \
    chown ansible:ansible /home/ansible/.ssh; \
    echo "%wheel ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/wheel

COPY --chown=ansible:ansible id_dsa.pub /home/ansible/.ssh/authorized_keys

RUN set -eux; \
    chmod 0600 /home/ansible/.ssh/authorized_keys

CMD ["/sbin/init"]

