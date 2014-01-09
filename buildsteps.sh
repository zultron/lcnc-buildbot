#!/bin/bash -xe

# Where the clean git repo is checked out into
#
# Must match the 'workdir' setting in config.yaml (which makes this
# liable to break :P )
REPODIR=repo

# This script starts execution in 'workdir'
WORKDIR="$(pwd)"

# At least a step should be defined
usage="usage:  $0 <step>"
step=${1:?$usage}; shift

# Fix relative paths
if test $REPODIR = ${REPODIR#/}; then   # relative path
    # Always assume we're starting in the 'build' directory
    # FIXME This is a terrible assumption.  How to pass in these params?
    REPODIR="$(readlink -f $(pwd)/../$REPODIR)"
fi

# git version annoyance
case "$(git --version | awk '{print $3}')" in
    1.[0-6].*|1.7.[0-3]*|1.7.[0-3]*.*|1.7.4.[01])
	# sheesh; want anything before 1.7.4.2.8.g3ccd6, I believe
	GIT_REMOTE_MIRROR="--mirror" ;;
    *)
	GIT_REMOTE_MIRROR="--mirror=fetch" ;;
esac

# fetch into the repo if it already exists in the 'buildir' subdir;
# else clone a fresh repo

step-init() {
    if [ -d $REPODIR ]; then
	pushd $REPODIR
	# Force the correct git url
	#
	# This is needed if the URL changes, and possibly in differing
	# versions of git:  some set origin after clone, some don't
	git remote rm origin 2>/dev/null || true
	git remote add $GIT_REMOTE_MIRROR origin "$repository"
	# Now fetch as usual
	if ! git fetch origin -t '+refs/*:refs/*' ||
	    ! git log -1 $revision; then
	    # either fetch command failed or it succeded but the
	    # needed revision isn't available; clean out directory and
	    # try from scratch
	    popd
	    rm -rf $REPODIR
	    echo "fetch failed; retrying"
	    step-init
	else
	    set -e
	    echo "fetch succeeded"
	    popd
	fi
    else
	git clone --mirror "$repository" $REPODIR
    fi
}

# clear and populate working subdirectory from the repo

step-sourcetree() {
    cd $REPODIR
    rm -rf $WORKDIR/source
    git archive --prefix=source/ "$revision" | tar xCf "$WORKDIR" -
}

# read and clear dmesg ring buffer to aid in debugging failed builds
#
# note: fails if buildslave user doesn't have passwordless permission
# to run 'sudo /bin/dmesg'

step-dmesg() {
    sudo dmesg -c
}

# report some useful info back to the buildmaster

step-environment() {
    set +x
    echo 'uname -a:'; 
    uname -a; 
    echo; 
    echo 'ulimit -a:'; 
    ulimit -a; 
    echo; 
    echo 'git --version:'; 
    git --version; 
    echo; 
    echo 'gcc --version:'; 
    gcc --version; 
    echo; 
    echo 'python -V:'; 
    python -V; 
    echo; 
    if test -x /usr/bin/xenomai-gid-ctl; then
	echo "xenomai-gid-ctl test:"
	/usr/bin/xenomai-gid-ctl test
    fi
    echo "groups:"
    groups
    if test -x /usr/bin/lsb_release; then
	echo 'lsb_release --all:'; 
	lsb_release --all; 
	echo; 
    else
	cat /etc/redhat-release
    fi
    echo 'lsmod:'; 
    lsmod; 
    echo; 
    if test -x /bin/rpm; then
	echo "rpm -qa:"
	rpm -qa
    elif test -x /usr/bin/dpkg; then
	echo 'dpkg --get-selections:'; 
	dpkg --get-selections;
    fi
}

# autogen needed build files

step-autogen() {
    cd source/src
    ./autogen.sh
}

# configure the build process - use default options here

step-configure() {
    cd source/src
    # lcnc doesn't look for {tcl,tk}Config.sh in /usr/lib64 in configure.in
    if test -f /usr/lib64/tkConfig.sh; then
	ARGS="--with-tkConfig=/usr/lib64/tkConfig.sh"
    fi
    if test -f /usr/lib64/tclConfig.sh; then
	ARGS="$ARGS --with-tclConfig=/usr/lib64/tclConfig.sh"
    fi
    ./configure $ARGS
}

# configure the doc build process - use default options here

step-configure-docs() {
    cd source/src
    # lcnc doesn't look for {tcl,tk}Config.sh in /usr/lib64 in configure.in
    if test -f /usr/lib64/tkConfig.sh; then
	ARGS="--with-tkConfig=/usr/lib64/tkConfig.sh"
    fi
    if test -f /usr/lib64/tclConfig.sh; then
	ARGS="$ARGS --with-tclConfig=/usr/lib64/tclConfig.sh"
    fi
    ./configure $ARGS --enable-build-documentation
}

# start the make process

step-make() {
    cd source/src
    make V=1
}

# start the make docs process

step-make-docs() {
    cd source/src
    make V=1 docs
}

# finally, set proper permissions on executables
#
# note: fails if buildslave user doesn't have passwordless permission
# to run 'sudo /usr/bin/make'

step-setuid() {
    cd source/src
    sudo make setuid
}

# run the runtests in the default realtime environment

step-runtests() {
    cd source
    source ./scripts/rip-environment
    # Force the flavor for runtests
    case "$buildername" in
	*-posix) FLAVOR=posix ;;
	*-rtpreempt) FLAVOR=rt-preempt ;;
	*-xenomai) FLAVOR=xenomai ;;
	*-xenomai_kernel) FLAVOR=xenomai-kernel ;;
	*-rtai_kernel) FLAVOR=rtai-kernel ;;
	'')  echo "buildername is unset!" 1>&2; exit 1 ;;
	*) echo "buildername '$buildername' unknown!" 1>&2; exit 1 ;;
    esac
    export FLAVOR

    # for debugging
    env

    # help ensure a previous crashed session doesn't interfere
    realtime stop || true

    echo "flavor: $(flavor)"
    runtests -v
}

# read dmesg ring buffer again in case anything useful was logged 

step-closeout() {
    dmesg
}

# create the SRPM

step-source-rpm() {
    :
}

step-$step; res=$?

echo "step $step exited with status $res" 1>&2
exit $res


