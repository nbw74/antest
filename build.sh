#!/bin/bash

set -o nounset
set -o errtrace
set -o pipefail

readonly CENTOS_6_VERSION=6.10
readonly CENTOS_7_VERSION=7.9.2009
readonly ALMALINUX_8_VERSION=8.6
readonly AMAZONLINUX_VERSION=2

export BUILDAH_LAYERS=true

typeset bn="" dn=""
bn="$(basename "$0")"
dn="$(dirname "$0")"
readonly bn dn

main() {
    local fn=${FUNCNAME[0]}

    trap 'except $LINENO' ERR

    if [[ ! -f "${dn}/id_ed25519" ]]; then
	echo_info "Generate ed25519 SSH key pair"
	ssh-keygen -t ed25519 -N '' -f ./id_ed25519
    fi

    if [[ ! -f "${dn}/id_dsa" ]]; then
	echo_info "Generate DSA SSH key pair"
	ssh-keygen -m PEM -t dsa -N '' -f ./id_dsa
    fi

    case "${target:-nop}" in
	c6)
	    RH_VERSION=$CENTOS_6_VERSION _build_centos_sysv
	    ;;
	c7)
	    RH_VERSION=$CENTOS_7_VERSION PYTHON_VERSION=2 _build_centos
	    ;;
	a8)
	    RH_VERSION=$ALMALINUX_8_VERSION PYTHON_VERSION=36 _build_almalinux
	    ;;
	amzn)
	    _build_amazonlinux
	    ;;
	*)
	    usage
    esac
}

_build_centos_sysv() {
    local fn=${FUNCNAME[0]}

    # shellcheck disable=SC2153
    echo_info "Build CentOS $RH_VERSION image with openssh-server"
    buildah bud \
	-f "${dn}/centos_sysv/Dockerfile" \
	-t "antest:centos-${RH_VERSION%%.*}" \
	--build-arg="RH_VERSION=$RH_VERSION" \
	"$dn"
}

_build_centos() {
    local fn=${FUNCNAME[0]}

    # shellcheck disable=SC2153
    echo_info "Build CentOS $RH_VERSION image with Python$PYTHON_VERSION and openssh-server"
    buildah bud \
	-f "${dn}/centos/Dockerfile" \
	-t "antest:centos-${RH_VERSION%%.*}" \
	--build-arg="RH_VERSION=$RH_VERSION" \
	--build-arg="PYTHON_VERSION=$PYTHON_VERSION" \
	"$dn"
}

_build_almalinux() {
    local fn=${FUNCNAME[0]}

    # shellcheck disable=SC2153
    echo_info "Build CentOS $RH_VERSION image with Python$PYTHON_VERSION and openssh-server"
    buildah bud \
	-f "${dn}/almalinux/Dockerfile" \
	-t "antest:almalinux-${RH_VERSION%%.*}" \
	--build-arg="RH_VERSION=$RH_VERSION" \
	--build-arg="PYTHON_VERSION=$PYTHON_VERSION" \
	"$dn"
}

_build_amazonlinux() {
    local fn=${FUNCNAME[0]}

    # shellcheck disable=SC2153
    echo_info "Build Amazon Linux $AMAZONLINUX_VERSION image with openssh-server"
    buildah bud \
	-f "${dn}/amazonlinux/Dockerfile" \
	-t "antest:amzn-${AMAZONLINUX_VERSION%%.*}" \
	--build-arg="AMAZONLINUX_VERSION=$AMAZONLINUX_VERSION" \
	"$dn"
}

except() {
    local ret=$?
    local no=${1:-no_line}

    echo_fatal "error occured in function '$fn' near line ${no}, exitcode $ret."
    logger -p user.err -t "$bn" "* FATAL: error occured in function '$fn' near line ${no}, exitcode $ret."

    exit $ret
}

usage() {
    echo -e "\\n    Usage: $bn [OPTION]\\n
    Options:

    -t, --target <str>	    build defined target

				c6	CentOS 6
				c7	CentOS 7
				a8	AlmaLinux 8
				amzn	Amazon Linux 2

    -h, --help			print help
"
}

# Getopts
getopt -T; (( $? == 4 )) || { echo "incompatible getopt version" >&2; exit 4; }

if ! TEMP=$(getopt -o t:h --longoptions target:,help -n "$bn" -- "$@")
then
    echo "Terminating..." >&2
    exit 1
fi

eval set -- "$TEMP"
unset TEMP

while true; do
    case $1 in
	-t|--target)
	    target=$2 ;		shift 2	;;
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
