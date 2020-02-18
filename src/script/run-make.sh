#!/usr/bin/env bash

set -e

trap clean_up_after_myself EXIT

ORIGINAL_CCACHE_CONF="$HOME/.ccache/ccache.conf"
SAVED_CCACHE_CONF="$HOME/.run-make-check-saved-ccache-conf"

function save_ccache_conf() {
    test -f $ORIGINAL_CCACHE_CONF && cp $ORIGINAL_CCACHE_CONF $SAVED_CCACHE_CONF || true
}

function restore_ccache_conf() {
    test -f $SAVED_CCACHE_CONF && mv $SAVED_CCACHE_CONF $ORIGINAL_CCACHE_CONF || true
}

function clean_up_after_myself() {
    rm -fr ${CEPH_BUILD_VIRTUALENV:-/tmp}/*virtualenv*
    restore_ccache_conf
}

function get_processors() {
    # get_processors() depends on coreutils nproc.
    if test -n "$NPROC" ; then
        echo $NPROC
    else
        if test $(nproc) -ge 2 ; then
            expr $(nproc) / 2
        else
            echo 1
        fi
    fi
}

function detect_ceph_dev_pkgs() {
    local cmake_opts
    local boost_root=/opt/ceph
    if test -f $boost_root/include/boost/config.hpp; then
        cmake_opts+=" -DWITH_SYSTEM_BOOST=ON -DBOOST_ROOT=$boost_root"
    else
        cmake_opts+=" -DBOOST_J=$(get_processors)"
    fi

    source /etc/os-release
    if [[ "$ID" == "ubuntu" ]] && [[ "$VERSION" =~ .*Xenial*. ]]; then 
        cmake_opts+=" -DWITH_RADOSGW_KAFKA_ENDPOINT=NO"
    fi
    echo "$cmake_opts"
}

function prepare() {
    local install_cmd
    local which_pkg="which"
    source /etc/os-release
    if test -f /etc/redhat-release ; then
        if ! type bc > /dev/null 2>&1 ; then
            echo "Please install bc and re-run." 
            exit 1
        fi
        if test "$(echo "$VERSION_ID >= 22" | bc)" -ne 0; then
            install_cmd="dnf -y install"
        else
            install_cmd="yum install -y"
        fi
    elif type zypper > /dev/null 2>&1 ; then
        install_cmd="zypper --gpg-auto-import-keys --non-interactive install --no-recommends"
    elif type apt-get > /dev/null 2>&1 ; then
        install_cmd="apt-get install -y"
        which_pkg="debianutils"
    fi

    if ! type sudo > /dev/null 2>&1 ; then
        echo "Please install sudo and re-run. This script assumes it is running"
        echo "as a normal user with the ability to run commands as root via sudo." 
        exit 1
    fi
    if [ -n "$install_cmd" ]; then
        $DRY_RUN sudo $install_cmd ccache $which_pkg
    else
        echo "WARNING: Don't know how to install packages" >&2
        echo "This probably means distribution $ID is not supported by run-make-check.sh" >&2
    fi

    if ! type ccache > /dev/null 2>&1 ; then
        echo "ERROR: ccache could not be installed"
        exit 1
    fi

    if test -f ./install-deps.sh ; then
            if [ "$WITHOUT_SEASTAR" ] ; then
                true
            else
	        export WITH_SEASTAR=1
            fi
	    $DRY_RUN source ./install-deps.sh || return 1
        trap clean_up_after_myself EXIT
    fi

    cat <<EOM
Note that the binaries produced by this script do not contain correct time
and git version information, which may make them unsuitable for debugging
and production use.
EOM
    save_ccache_conf
    # remove the entropy generated by the date/time embedded in the build
    $DRY_RUN export SOURCE_DATE_EPOCH="946684800"
    $DRY_RUN ccache -o sloppiness=time_macros
    $DRY_RUN ccache -o run_second_cpp=true
    if [ -n "$JENKINS_HOME" ]; then
        # Build host has plenty of space available, let's use it to keep
        # various versions of the built objects. This could increase the cache hit
        # if the same or similar PRs are running several times
        $DRY_RUN ccache -o max_size=100G
    else
        echo "Current ccache max_size setting:"
        ccache -p | grep max_size
    fi
    $DRY_RUN ccache -sz # Reset the ccache statistics and show the current configuration
}

function configure() {
    local cmake_build_opts=$(detect_ceph_dev_pkgs)
    $DRY_RUN ./do_cmake.sh $cmake_build_opts $@ || return 1
}

function build() {
    local targets="$@"
    $DRY_RUN cd build
    BUILD_MAKEOPTS=${BUILD_MAKEOPTS:-$DEFAULT_MAKEOPTS}
    test "$BUILD_MAKEOPTS" && echo "make will run with option(s) $BUILD_MAKEOPTS"
    $DRY_RUN make $BUILD_MAKEOPTS $targets || return 1
    $DRY_RUN ccache -s # print the ccache statistics to evaluate the efficiency
}

DEFAULT_MAKEOPTS=${DEFAULT_MAKEOPTS:--j$(get_processors)}

if [ "$0" = "$BASH_SOURCE" ]; then
    # not sourced
    if [ `uname` = FreeBSD ]; then
        GETOPT=/usr/local/bin/getopt
    else
        GETOPT=getopt
    fi

    options=$(${GETOPT} --name "$0" --options "" --longoptions "cmake-args:" -- "$@")
    if [ $? -ne 0 ]; then
        exit 2
    fi
    eval set -- "${options}"
    while true; do
        case "$1" in
            --cmake-args)
                cmake_args=$2
                shift 2;;
            --)
                shift
                break;;
            *)
                echo "bad option $1" >& 2
                exit 2;;
        esac
    done
    prepare
    configure "$cmake_args"
    build "$@"
fi
