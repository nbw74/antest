#!/bin/bash -l

set -o nounset
set -o errtrace
set -o pipefail

readonly PODMAN_SUBNET=10.25.11.0/24
readonly PODMAN_NET=10.25.11
readonly ANTEST_PROJECT_DIR="${HOME}/projects/github/nbw74/antest"
readonly BIN_REQUIRED="podman"

typeset bn=""
bn="$(basename "$0")"
readonly bn

typeset -i err_warn=0 COUNT=1 KEEP_RUNNING=1 DEFAULT_PRIVATE_KEY=0 \
    CONTAINER_SSH_PORT=2222 SSH_PORT=2222 STATIC_IP=0 \
    ACT_STOP=0 ACT_REMOVE=0 START_OCTET=11 NO_CREATE=0 \
    SETUP_FROM_INV=0 PUBLISH_FTP=0 PUBLISH_HTTP=0 CHECK_MODE=0

typeset IMAGE="" NAME_PREFIX="" NETWORK_PROXY="" STATIC_IP_STR="" TAGS=""
typeset INVENTORY="tests/antest/inventory/hosts.yml" PLAYBOOK="tests/antest/site.yml"

main() {
    local fn=${FUNCNAME[0]}

    trap 'except $LINENO' ERR

    until [[ $(pwd) == "/" ]]; do
	if [[ -d ./tests/antest ]]; then
	    break
	else
	    cd .. || false
	fi
    done

    if [[ ! -d ./tests/antest ]]; then
	echo_err "Cannot find tests/antest dir in any catalog up in directory tree"
	false
    fi
    # shellcheck disable=SC1091
    source "${HOME}/venv/ansible/bin/activate"

    local -a Setup=()

    if (( SETUP_FROM_INV )); then
	mapfile -t Setup < <(niet -f toml all.vars.antest "$INVENTORY")

	for (( c = 0; c < ${#Setup[@]} - 1 ; c++ )); do
	    eval "export $(echo "${Setup[c]}" | awk 'BEGIN { FS = "="; OFS = "=" } { gsub(/\s+/, ""); print toupper($1), $2 }')"
	done
    fi

    echo DEFAULT_PRIVATE_KEY[$DEFAULT_PRIVATE_KEY]

    local ansible_rolename=${PWD##*/}
    local ansible_rolename_norm=${ansible_rolename//_/-}
    local ansible_network_name="ansible-test-podman"
    local ansible_target_container="${NAME_PREFIX:-$ansible_rolename_norm}"

    if [[ -f "${HOME}/.config/run.sh.conf" ]]; then
	# shellcheck disable=SC1091
	source "${HOME}/.config/run.sh.conf"
    fi

    if [[ $ACT_STOP == 0 && $ACT_REMOVE == 0 ]]; then

	if (( ! NO_CREATE )); then
	    checks
	    _create
	fi

	echo_info "Run ansible playbook"
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
	# podman unshare --rootless-netns
	podman network create --subnet "$PODMAN_SUBNET" "$ansible_network_name"
    fi

    for (( c = 1; c <= COUNT; c++ )); do
	_target="${ansible_target_container}-$c"

	[[ $PUBLISH_FTP -gt 0 && $c -gt 1 ]] && PUBLISH_FTP=0
	[[ $PUBLISH_HTTP -gt 0 && $c -gt 1 ]] && PUBLISH_HTTP=0

	local -a publish_http=() publish_ftp=()

	if (( PUBLISH_HTTP )); then
	    publish_http=(
		"--publish"
		"0.0.0.0:80:80"
		"--publish"
		"0.0.0.0:443:443"
	    )
	fi

	if (( PUBLISH_FTP )); then
	    publish_ftp=(
		"--publish"
		"0.0.0.0:20:20"
		"--publish"
		"0.0.0.0:21:21"
		"--publish"
		"0.0.0.0:49900-50000:49900-50000"
	    )
	fi

	(( STATIC_IP )) && STATIC_IP_STR="--ip=${PODMAN_NET}.$(( START_OCTET + c - 1 ))"
	# shellcheck disable=SC2086
	if ! inArray ContainersAll "$_target"; then
	    local publish="127.0.0.$(( START_OCTET + c - 1 )):$(( SSH_PORT + c - 1 )):${CONTAINER_SSH_PORT}"
	    echo_info "Run container $_target with publish $publish"
	    podman run -d \
		$STATIC_IP_STR \
		--privileged \
		--name="$_target" \
		--hostname="${_target}.example.com" \
		--network="$ansible_network_name" \
		"${publish_ftp[@]}" \
		"${publish_http[@]}" \
		--publish "$publish" \
		"localhost/$IMAGE"
	    sleep 2
	fi
    done

    # shellcheck disable=SC2034
    mapfile -t ContainersRunning < <(podman ps --format="{{.Names}}")

    for (( c = 1; c <= COUNT; c++ )); do
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
    export ANSIBLE_HOST_KEY_CHECKING="False"
    export ANSIBLE_PYTHON_INTERPRETER=auto
    export ANSIBLE_SSH_ARGS="-C -o ControlMaster=auto -o ControlPersist=60s -o IdentitiesOnly=yes"

    if [[ -n $NETWORK_PROXY ]]; then
	HTTP_PROXY="$NETWORK_PROXY"
	HTTPS_PROXY="$NETWORK_PROXY"
	http_proxy="$NETWORK_PROXY"
	https_proxy="$NETWORK_PROXY"

	export HTTP_PROXY HTTPS_PROXY http_proxy https_proxy
    fi

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

    if inArray oldSSH "$IMAGE"; then
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
    local tags=""

    if [[ -f vars.local ]]; then
	extra_vars="-e @vars.local"
    fi

    if [[ -n "$TAGS" ]]; then
	tags="-t $TAGS"
    fi

    local default_private_key="--private-key ${ANTEST_PROJECT_DIR}/id_$ssh_key_type"

    if (( DEFAULT_PRIVATE_KEY )); then
	default_private_key=""
    fi

    local check_mode=""

    if (( CHECK_MODE )); then
	check_mode="--check"
    fi

    # shellcheck disable=SC2086
    ansible-playbook $PLAYBOOK -b -u ansible $check_mode \
	$default_private_key \
	--ssh-extra-args "-o ControlMaster=auto -o ControlPersist=60s -o UserKnownHostsFile=/dev/null" \
	$extra_vars $tags
}

_stop() {
    local fn=${FUNCNAME[0]}
    err_warn=1

    for (( c = 1; c <= COUNT; c++ )); do
	_target="${ansible_target_container}-$c"

	echo_info "Stop container '$_target'"
	podman stop "$_target"
    done

    err_warn=0
}

_rm() {
    local fn=${FUNCNAME[0]}
    err_warn=1

    for (( c = 1; c <= COUNT; c++ )); do
	_target="${ansible_target_container}-$c"

	echo_info "Remove container '$_target'"
	podman rm "$_target"
    done

    pkill aardvark-dns

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

    if [[ ${IMAGE:-nop} == "nop" ]]; then
	echo "Required parameter '--image' is missing" >&2
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

    -a, --ssh-port <int>	set pod's SSH port (default: 2222)
    -A <int>			container's SSH port (default: 2222)
    -c, --count <int>		launch several instances
    -C, --check-mode		run ansible-playbook with --check option
    -f, --static-ip		set static IP for container
    -H, --publish-http		publish HTTP(S) ports
    -i, --inventory <path>	alternative inventory (default is tests/antest/inventory/hosts.yml)
    -I, --start-octet <int>	start from this IP address' last octet (default is 11)
    -K, --no-keep-running	stop containers after double plays
    -n, --name-prefix <string>	container name prefix (default is current directory name)
    -N, --no-create		don't create containers (just run ansible on existing container)
    --default-private-key	use SSH private keys from user's profile
    -p, --playbook <path>	alternative playbook (default is tests/antest/site.yml)
    -P, --network-proxy		set HTTP_PROXY and HTTPS_PROXY environment variables
    -q, --from-inventory	read script parameters from hosts.yml
    -R, --remove		remove containers
    -s, --stop			stop containers
    -V, --image			see 'podman images' for available images
    -h, --help			print help
"
}
# Getopts
getopt -T; (( $? == 4 )) || { echo "incompatible getopt version" >&2; exit 4; }

if ! TEMP=$(getopt -o a:A:c:Cfi:I:p:qn:FHKNP:st:RV:h --longoptions ansible-port:,count:,check-mode,static-ip,inventory:,start-octet:,playbook:,default-private-key,name-prefix:,publish-ftp,publish-http,no-keep-running,no-create,network-proxy:,from-inventory,stop,tags:,remove,image,help -n "$bn" -- "$@")
then
    echo "Terminating..." >&2
    exit 1
fi

eval set -- "$TEMP"
unset TEMP

while true; do
    case $1 in
	-a|--ssh-port)
	    SSH_PORT=$2 ;	shift 2	;;
	-A)
	    CONTAINER_SSH_PORT=$2 ;	shift 2	;;
	-C|--check)
	    CHECK_MODE=1 ;	shift	;;
	-c|--count)
	    COUNT=$2 ;	shift 2	;;
	-f|--static-ip)
	    STATIC_IP=1 ;	shift	;;
	-i|--inventory)
	    INVENTORY=$2 ;	shift 2	;;
	-I|--start-octet)
	    START_OCTET=$2 ;	shift 2	;;
	-p|--playbook)
	    PLAYBOOK=$2 ;	shift 2	;;
	--default-private-key)
	    DEFAULT_PRIVATE_KEY=1 ; shift ;;
	-n|--name-prefix)
	    NAME_PREFIX=$2 ;	shift 2	;;
	-F|--publish-ftp)
	    PUBLISH_FTP=1;	shift	;;
	-H|--publish-http)
	    PUBLISH_HTTP=1 ;	shift	;;
	-K|--no-keep-running)
	    KEEP_RUNNING=0 ;	shift	;;
	-N|--no-create)
	    NO_CREATE=1 ;	shift	;;
	-P|--network-proxy)
	    NETWORK_PROXY=$2 ;	shift 2	;;
	-q|--from-inventory)
	    SETUP_FROM_INV=1 ;	shift	;;
	-R|--remove)
	    ACT_REMOVE=1 ;	shift	;;
	-s|--stop)
	    ACT_STOP=1 ;	shift	;;
	-t|--tags)
	    TAGS=$2 ;		shift 2 ;;
	-V|--image)
	    IMAGE=$2 ;	shift 2	;;
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
