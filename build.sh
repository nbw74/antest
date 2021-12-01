#!/bin/bash

set -o nounset
set -o errtrace
set -o pipefail

readonly CENTOS_7_VERSION=7.9.2009
readonly CENTOS_8_VERSION=8.4.2105

export BUILDAH_LAYERS=true

readonly bn="$(basename "$0")"
readonly dn="$(dirname "$0")"

main() {
    local fn=${FUNCNAME[0]}

    trap 'except $LINENO' ERR

#     echo_info "Testing Dockerfile with latest hadolint"
#     podman run --rm -i ghcr.io/hadolint/hadolint < "${dn}/Dockerfile"

    if [[ ! -f "${dn}/id_ed25519" ]]; then
	echo_info "Generate SSH key pair"
	ssh-keygen -t ed25519 -N '' -f ./id_ed25519
    fi

    CENTOS_VERSION=$CENTOS_7_VERSION PYTHON_VERSION=2 _build_centos
    CENTOS_VERSION=$CENTOS_7_VERSION PYTHON_VERSION=3 _build_centos
    CENTOS_VERSION=$CENTOS_8_VERSION PYTHON_VERSION=36 _build_centos
    CENTOS_VERSION=$CENTOS_8_VERSION PYTHON_VERSION=38 _build_centos

}

_build_centos() {
    local fn=${FUNCNAME[0]}

    echo_info "Build CentOS $CENTOS_VERSION image with Python$PYTHON_VERSION and openssh-server"
    buildah bud \
	-f "${dn}/Dockerfile" \
	-t antest:centos-${CENTOS_VERSION}-$PYTHON_VERSION \
	--build-arg=CENTOS_VERSION=$CENTOS_VERSION \
	--build-arg=PYTHON_VERSION=$PYTHON_VERSION \
	"$dn"
}

except() {
    local ret=$?
    local no=${1:-no_line}

    echo_fatal "error occured in function '$fn' near line ${no}, exitcode $ret."
    logger -p user.err -t "$bn" "* FATAL: error occured in function '$fn' near line ${no}, exitcode $ret."

    exit $ret
}

echo_err()      { tput bold; tput setaf 7; echo "* ERROR: $*" ;   tput sgr0;   }
echo_fatal()    { tput bold; tput setaf 1; echo "* FATAL: $*" ;   tput sgr0;   }
echo_warn()     { tput bold; tput setaf 3; echo "* WARNING: $*" ; tput sgr0;   }
echo_info()     { tput bold; tput setaf 6; echo "* INFO: $*" ;    tput sgr0;   }
echo_ok()       { tput bold; tput setaf 2; echo "* OK" ;          tput sgr0;   }

main

### EOF ###
