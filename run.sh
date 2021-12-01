#!/bin/bash

set -o nounset
set -o errtrace
set -o pipefail

readonly PODMAN_SUBNET=10.25.11.0/24
readonly ANTEST_PROJECT_DIR="${HOME}/projects/nbw74/antest"
readonly BIN_REQUIRED="podman"

readonly bn="$(basename "$0")"

typeset -i err_warn=0 INSTANCES=1 KEEP_RUNNING=0 POD_SSH_PORT=2222 ACT_STOP=0 ACT_REMOVE=0
typeset PUBLISH_HTTP="" CENTOS_VERSION=""

main() {
    local fn=${FUNCNAME[0]}

    trap 'except $LINENO' ERR

    local ansible_rolename=${PWD##*/}
    local ansible_network_name="ansible-test-podman"
    local ansible_target_container="$ansible_rolename"

    if [[ $ACT_STOP == 0 && $ACT_REMOVE == 0 ]]; then
	checks
	_create
    else
	_stop

	if (( ACT_REMOVE )); then
	    _rm
	fi
    fi
}

_create() {
    local fn=${FUNCNAME[0]}

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

    for (( c = 1; c <= INSTANCES; c++ )); do
	_target="${ansible_target_container}-$c"

	[[ -n "$PUBLISH_HTTP" && $c -gt 1 ]] && PUBLISH_HTTP=""

	if ! inArray ContainersAll "$_target"; then
	    echo_info "Run container $_target"
	    podman run -d \
		--privileged \
		--name="$_target" \
		--network="$ansible_network_name" \
		$PUBLISH_HTTP \
		--publish "127.0.0.1${c}:$(( POD_SSH_PORT + c - 1 )):${POD_SSH_PORT}" \
		"localhost/antest:centos-$CENTOS_VERSION"
	fi
    done

    # shellcheck disable=SC2034
    mapfile -t ContainersRunning < <(podman ps --format="{{.Names}}")

    for (( c = 1; c <= INSTANCES; c++ )); do
	_target="${ansible_target_container}-$c"

	if ! inArray ContainersRunning "$_target"; then
	    echo_info "Start container $_target"
	    podman start "$_target"
	fi
    done

    echo_info "Run ansible playbook (I)"
    _run

    read -rp "Press key to continue for second pass... " -n1 -s

    echo
    echo_info "Run ansible playbook (II)"
    _run

    if (( ! KEEP_RUNNING )); then
	_stop
	_rm

# 	echo_info "Remove network $ansible_network_name"
# 	podman network rm "$ansible_network_name"
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
	-i tests/antest/inventory/hosts.yml
}

_stop() {
    local fn=${FUNCNAME[0]}
    err_warn=1

    for (( c = 1; c <= INSTANCES; c++ )); do
	_target="${ansible_target_container}-$c"

	echo_info "Stop container '$_target'"
	podman stop "$_target"
    done

    err_warn=0
}

_rm() {
    local fn=${FUNCNAME[0]}
    err_warn=1

    for (( c = 1; c <= INSTANCES; c++ )); do
	_target="${ansible_target_container}-$c"

	echo_info "Remove container '$_target'"
	podman rm "$_target"
    done

    err_warn=0
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

checks() {
    local fn=${FUNCNAME[0]}
    # Required binaries check
    for i in $BIN_REQUIRED; do
        if ! command -v "$i" >/dev/null
        then
            echo "Required binary '$i' is not installed" >&2
            false
        fi
    done

    if [[ ${CENTOS_VERSION:-nop} == "nop" ]]; then
	echo "Required parameter '--centos-version' is missing" >&2
	false
    fi
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
    -c, --instanes <int>	make several instances
    -H, --publish-http		publish HTTP(S) ports
    -s, --stop			stop containers
    -R, --remove		remove containers
    -k, --keep-running		do not stop containers
    -V, --centos-version	image tag; available tags:

				    7.9.2009-2
				    7.9.2009-3
				    8.4.2105-36
				    8.4.2105-38

    -h, --help			print help
"
}
# Getopts
getopt -T; (( $? == 4 )) || { echo "incompatible getopt version" >&2; exit 4; }

if ! TEMP=$(getopt -o a:c:HksRV:h --longoptions ansible-port:,instances:,publish-http,keep-running,stop,remove,centos-version,help -n "$bn" -- "$@")
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
	-c|--instances)
	    INSTANCES=$2 ;	shift 2	;;
	-H|--publish-http)
	    PUBLISH_HTTP='--publish "0.0.0.0:80:80" --publish "0.0.0.0:443:443"' ;	shift	;;
	-k|--keep-running)
	    KEEP_RUNNING=1 ;	shift	;;
	-s|--stop)
	    ACT_STOP=1 ;	shift	;;
	-R|--remove)
	    ACT_REMOVE=1 ;	shift	;;
	-V|--centos-version)
	    CENTOS_VERSION=$2 ;	shift 2	;;
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
