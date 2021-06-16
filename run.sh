#!/bin/bash

set -o nounset
set -o errtrace
set -o pipefail

readonly CENTOS_VERSION=7.9.2009
readonly PODMAN_SUBNET=10.25.11.0/24
readonly ANTEST_PROJECT_DIR="${HOME}/projects/nbw74/antest"

readonly bn="$(basename "$0")"

typeset -i err_warn=0 KEEP_RUNNING=0 POD_SSH_PORT=2222
typeset PUBLISH_HTTP=""

main() {
    local fn=${FUNCNAME[0]}

    trap 'except $LINENO' ERR

    local ansible_rolename=${PWD##*/}
    local ansible_network_name="ansible-test-podman"
    local ansible_target_container="ansible-test-$ansible_rolename"

    export ANSIBLE_ROLES_PATH="${PWD%/*}:${HOME}/.ansible/roles"
    export ANSIBLE_HOST_KEY_CHECKING="false"
    export ANSIBLE_SSH_ARGS="-C -o ControlMaster=auto -o ControlPersist=60s -o IdentitiesOnly=yes"

    local -a ContainersAll=() ContainersRunning=() Networks=()
    # shellcheck disable=SC2034
    mapfile -t ContainersAll < <(podman ps -a --format="{{.Names}}")
    # shellcheck disable=SC2034
    mapfile -t Networks < <(podman network ls --format="{{.Name}}")

    if ! inArray Networks "$ansible_network_name"; then
	echo_info "Creating network '$ansible_network_name'"
	podman network create --subnet "$PODMAN_SUBNET" "$ansible_network_name"
    fi

    if ! inArray ContainersAll "$ansible_target_container"; then
	echo_info "Run container $ansible_target_container"
	podman run -d \
	    --privileged \
	    --name="$ansible_target_container" \
	    --network="$ansible_network_name" \
	    $PUBLISH_HTTP \
	    --publish "127.0.0.1:${POD_SSH_PORT}:${POD_SSH_PORT}" \
	    "localhost/antest:centos-$CENTOS_VERSION"
    fi

    # shellcheck disable=SC2034
    mapfile -t ContainersRunning < <(podman ps --format="{{.Names}}")

    if ! inArray ContainersRunning "$ansible_target_container"; then
	echo_info "Start container $ansible_target_container"
	podman start "$ansible_target_container"
    fi

    echo_info "Run ansible playbook (I)"
    _run

    read -rp "Press key to continue for second pass... " -n1 -s

    echo
    echo_info "Run ansible playbook (II)"
    _run

    if (( ! KEEP_RUNNING )); then
	echo_info "Stop container '$ansible_target_container'"
	podman stop "$ansible_target_container"
	echo_info "Remove container '$ansible_target_container'"
	podman rm "$ansible_target_container"

	echo_info "Remove network $ansible_network_name"
	podman network rm "$ansible_network_name"
    fi
}

_run() {
    local fn=${FUNCNAME[0]}

    if [[ -f requirements.yml ]]; then
	ansible-galaxy install -r requirements.yml 2>&1 | grep -F -- 'use --force' \
	    && ansible-galaxy install -r requirements.yml --force
    fi

    ansible-playbook tests/antest/site.yml -b --diff -u ansible \
	--private-key "${ANTEST_PROJECT_DIR}/id_ed25519" \
	-i tests/antest/inventory/hosts.yml \
	-e ansible_ssh_port=${POD_SSH_PORT}
}

inArray() {
    local array="$1[@]"
    local seeking=$2
    local -i in=1

    if [[ ${!array:-nop} == "nop" ]]; then
	return $in
    fi

    for e in ${!array}; do
        if [[ $e == "$seeking" ]]; then
            in=0
            break
        fi
    done

    return $in
}

except() {
    local ret=$?
    local no=${1:-no_line}

    if (( err_warn )); then
	echo_warn "error occured in function '$fn' near line ${no}, exitcode $ret."
	logger -p user.warn -t "$bn" "* WARNING: error occured in function '$fn' near line ${no}, exitcode $ret."
    else
	echo_fatal "error occured in function '$fn' near line ${no}, exitcode $ret."
	logger -p user.err -t "$bn" "* FATAL: error occured in function '$fn' near line ${no}, exitcode $ret."
	exit $ret
    fi
}

usage() {
    echo -e "\\n    Usage: $bn [OPTION]\\n
    Options:

    -a, --ssh-port <int>	set SSH port (default: 2222)
    -H, --publish-http		publish HTTP(S) ports
    -k, --keep-running		do not stop containers
    -h, --help			print help
"
}
# Getopts
getopt -T; (( $? == 4 )) || { echo "incompatible getopt version" >&2; exit 4; }

if ! TEMP=$(getopt -o a:Hkh --longoptions ansible-port:,no-publish-http,keep-running,help -n "$bn" -- "$@")
then
    echo "Terminating..." >&2
    exit 1
fi

eval set -- "$TEMP"
unset TEMP

while true; do
    case $1 in
	-a|--ssh-port)
	    POD_SSH_PORT=$2 ;	shift 2	;;
	-H|--publish-http)
	    PUBLISH_HTTP='--publish "127.0.0.1:80:80" --publish "127.0.0.1:443:443"' ;	shift	;;
	-k|--keep-running)
	    KEEP_RUNNING=1 ;	shift	;;
	-h|--help)
	    usage ;		exit 0	;;
	--)
	    shift ;		break	;;
	*)
	    usage ;		exit 1
    esac
done

echo_err()      { tput bold; tput setaf 7; echo "* ERROR: $*" ;   tput sgr0;   }
echo_fatal()    { tput bold; tput setaf 1; echo "* FATAL: $*" ;   tput sgr0;   }
echo_warn()     { tput bold; tput setaf 3; echo "* WARNING: $*" ; tput sgr0;   }
echo_info()     { tput bold; tput setaf 6; echo "* INFO: $*" ;    tput sgr0;   }
echo_ok()       { tput bold; tput setaf 2; echo "* OK" ;          tput sgr0;   }

main

### EOF ###
