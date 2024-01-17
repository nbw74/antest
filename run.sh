#!/bin/bash

set -o nounset
set -o errtrace
set -o pipefail

readonly PODMAN_SUBNET=10.25.11.0/24
readonly ANTEST_PROJECT_DIR="${HOME}/projects/github/nbw74/antest"
readonly BIN_REQUIRED="podman"

typeset bn=""
bn="$(basename "$0")"
readonly bn

typeset -i err_warn=0 INSTANCES=1 KEEP_RUNNING=1 POD_SSH_PORT=2222 ACT_STOP=0 ACT_REMOVE=0 START_OCTET=11 NO_CREATE=0
typeset PUBLISH_FTP="" PUBLISH_HTTP="" USED_IMAGE="" NAME_PREFIX="" INVENTORY="tests/antest/inventory/hosts.yml" PLAYBOOK="tests/antest/site.yml"

readonly CONTAINER_SSH_PORT=$POD_SSH_PORT

main() {
    local fn=${FUNCNAME[0]}

    trap 'except $LINENO' ERR

    local ansible_rolename=${PWD##*/}
    local ansible_rolename_norm=${ansible_rolename//_/-}
    local ansible_network_name="ansible-test-podman"
    local ansible_target_container="${NAME_PREFIX:-$ansible_rolename_norm}"

    if [[ -f "${HOME}/.config/run.sh.conf" ]]; then
	source "${HOME}/.config/run.sh.conf"
    fi

    if [[ $ACT_STOP == 0 && $ACT_REMOVE == 0 ]]; then

	if (( ! NO_CREATE )); then
	    checks
	    _create
	fi

	echo_info "Run ansible playbook (I)"
	_run
	read -rp "Press key to continue for second pass... " -n1 -s
	echo
	echo_info "Run ansible playbook (II)"
	_run

	if (( ! KEEP_RUNNING )); then
	    _stop
	    _rm
	fi
    else
	_stop

	if (( ACT_REMOVE )); then
	    _rm
	fi
    fi
}

_create() {
    local fn=${FUNCNAME[0]}

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

	[[ -n "$PUBLISH_FTP" && $c -gt 1 ]] && PUBLISH_FTP=""
	[[ -n "$PUBLISH_HTTP" && $c -gt 1 ]] && PUBLISH_HTTP=""
	# shellcheck disable=SC2086
	if ! inArray ContainersAll "$_target"; then
	    local publish="127.0.0.$(( START_OCTET + c - 1 )):$(( POD_SSH_PORT + c - 1 )):${CONTAINER_SSH_PORT}"
	    echo_info "Run container $_target with publish $publish"
	    podman run -d \
		--privileged \
		--name="$_target" \
		--network="$ansible_network_name" \
		$PUBLISH_FTP \
		$PUBLISH_HTTP \
		--publish "$publish" \
		"localhost/$USED_IMAGE"
	    sleep 2
	fi
    done

    # shellcheck disable=SC2034
    mapfile -t ContainersRunning < <(podman ps --format="{{.Names}}")

    for (( c = 1; c <= INSTANCES; c++ )); do
	_target="${ansible_target_container}-$c"

	if ! inArray ContainersRunning "$_target"; then
	    echo_info "Start container $_target"
	    podman start "$_target"
	    sleep 2
	fi
    done
}

_run() {
    local fn=${FUNCNAME[0]}

    export ANSIBLE_ROLES_PATH="${PWD%/*}:${HOME}/.ansible/roles"
    export ANSIBLE_COLLECTIONS_PATH="${HOME}/projects/sb:${HOME}/.ansible/collections"
    export ANSIBLE_HOST_KEY_CHECKING="False"
    export ANSIBLE_STDOUT_CALLBACK=yaml
    export ANSIBLE_SSH_ARGS="-C -o ControlMaster=auto -o ControlPersist=60s -o IdentitiesOnly=yes"

    if [[ -f requirements.yml ]]; then
	ansible-galaxy install -r requirements.yml 2>&1 | grep -F -- 'use --force' \
	    && ansible-galaxy install -r requirements.yml --force
    fi

    local ssh_key_type=""
    # shellcheck disable=SC2034
    local -a oldSSH=(
	"antest:centos-5"
	"antest:centos-6"
    )

    if inArray oldSSH "$USED_IMAGE"; then
	ssh_key_type=dsa
    else
	ssh_key_type=ed25519
    fi

    if [[ "${ANSIBLE_INVENTORY:-nul}" != "nul" ]]; then
	ANSIBLE_INVENTORY="${ANSIBLE_INVENTORY},$INVENTORY"
    else
	ANSIBLE_INVENTORY="$INVENTORY"
    fi

    export ANSIBLE_INVENTORY

    local extra_vars=""

    if [[ -f vars.local ]]; then
	extra_vars="-e @vars.local"
    fi
    # shellcheck disable=SC2086
    ansible-playbook $PLAYBOOK -b -u ansible \
	--private-key "${ANTEST_PROJECT_DIR}/id_$ssh_key_type" \
	--ssh-extra-args "-o ControlMaster=auto -o ControlPersist=60s -o UserKnownHostsFile=/dev/null" \
	$extra_vars
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

    if [[ ${USED_IMAGE:-nop} == "nop" ]]; then
	echo "Required parameter '--used-image' is missing" >&2
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
    -c, --instances <int>	make several instances
    -i, --inventory <path>	alternative inventory (default is tests/antest/inventory/hosts.yml)
    -I, --start-ip <int>	start from this IP address' last octet (default is 11)
    -p, --playbook <path>	alternative playbook (default is tests/antest/site.yml)
    -n, --prefix <string>	container name prefix (default is current directory name)
    -H, --publish-http		publish HTTP(S) ports
    -s, --stop			stop containers
    -R, --remove		remove containers
    -K, --no-keep-running	stop containers after double plays
    -N, --no-create		don't create containers (just run ansible on existing container)
    -V, --used-image		available images:

				    antest:centos-6
				    antest:centos-7
				    antest:almalinux-8
				    antest:almalinux-9
				    antest:amzn-2
				    antest:amzn-2023

    -h, --help			print help
"
}
# Getopts
getopt -T; (( $? == 4 )) || { echo "incompatible getopt version" >&2; exit 4; }

if ! TEMP=$(getopt -o a:c:i:I:p:n:FHKNsRV:h --longoptions ansible-port:,instances:,inventory:,start-ip:,playbook:,prefix:,publish-ftp,publish-http,no-keep-running,no-create,stop,remove,used-image,help -n "$bn" -- "$@")
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
	-i|--inventory)
	    INVENTORY=$2 ;	shift 2	;;
	-I|--start-ip)
	    START_OCTET=$2 ;	shift 2	;;
	-p|--playbook)
	    PLAYBOOK=$2 ;	shift 2	;;
	-n|--prefix)
	    NAME_PREFIX=$2 ;	shift 2	;;
	-F|--publish-ftp)
	    PUBLISH_FTP='--publish "0.0.0.0:20:20" --publish "0.0.0.0:21:21" --publish "0.0.0.0:49900-50000:49900-50000"' ;	shift	;;
	-H|--publish-http)
	    PUBLISH_HTTP='--publish "0.0.0.0:80:80" --publish "0.0.0.0:443:443"' ;	shift	;;
	-K|--no-keep-running)
	    KEEP_RUNNING=0 ;	shift	;;
	-N|--no-create)
	    NO_CREATE=1 ;	shift	;;
	-s|--stop)
	    ACT_STOP=1 ;	shift	;;
	-R|--remove)
	    ACT_REMOVE=1 ;	shift	;;
	-V|--used-image)
	    USED_IMAGE=$2 ;	shift 2	;;
	-h|--help)
	    usage ;		exit 0	;;
	--)
	    shift ;		break	;;
	*)
	    usage ;		exit 1
    esac
done

echo_err()      { echo "* ERROR: $*" ;   }
echo_fatal()    { echo "* FATAL: $*" ;   }
echo_warn()     { echo "* WARNING: $*" ; }
echo_info()     { echo "* INFO: $*" ;    }
echo_ok()       { echo "* OK" ;          }

main

### EOF ###
