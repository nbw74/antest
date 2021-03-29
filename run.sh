#!/bin/bash

set -o nounset
set -o errtrace
set -o pipefail

readonly CENTOS_VERSION=7.9.2009
readonly PODMAN_SUBNET=10.25.11.0/24
readonly ANTEST_PROJECT_DIR="${HOME}/projects/nbw74/antest"

readonly bn="$(basename "$0")"

typeset -i err_warn=0

main() {
    local fn=${FUNCNAME[0]}

    trap 'except $LINENO' ERR

    local ansible_rolename=${PWD##*/}
    local ansible_network_name="ansible-test-$ansible_rolename"
    local ansible_target_container="ansible-test-$ansible_rolename"

    export ANSIBLE_ROLES_PATH="${PWD%/*}"
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
	    --name="$ansible_target_container" \
	    --network="$ansible_network_name" \
	    --publish "127.0.0.1:2222:2222" \
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

    echo_info "Stop container '$ansible_target_container'"
    podman stop "$ansible_target_container"
    echo_info "Remove container '$ansible_target_container'"
    podman rm "$ansible_target_container"

    echo_info "Remove network $ansible_network_name"
    podman network rm "$ansible_network_name"
}

_run() {
    local fn=${FUNCNAME[0]}

    ansible-playbook tests/antest/site.yml -b --diff -u ansible \
	--private-key "${ANTEST_PROJECT_DIR}/id_ed25519" \
	-i tests/antest/inventory \
	-e ansible_ssh_port=2222
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

echo_err()      { tput bold; tput setaf 7; echo "* ERROR: $*" ;   tput sgr0;   }
echo_fatal()    { tput bold; tput setaf 1; echo "* FATAL: $*" ;   tput sgr0;   }
echo_warn()     { tput bold; tput setaf 3; echo "* WARNING: $*" ; tput sgr0;   }
echo_info()     { tput bold; tput setaf 6; echo "* INFO: $*" ;    tput sgr0;   }
echo_ok()       { tput bold; tput setaf 2; echo "* OK" ;          tput sgr0;   }

main

### EOF ###
