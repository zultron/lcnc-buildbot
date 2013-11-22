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

# on the server side, update the git poller repo for sharing over the
# web

step-git-web() {
    cd $POLLER_REPODIR
    git update-server-info
}


# fetch into the repo if it already exists in the 'buildir' subdir;
# else clone a fresh repo

step-init() {
    if [ -d $REPODIR ]; then
	pushd $REPODIR
	git fetch origin +refs/heads/*:refs/heads/*
	echo fetched
	popd
    else
	git clone --bare "$GIT_URL" $REPODIR
	pushd $REPODIR
	# Force the correct git url
	#
	# This is needed if the URL changes, and possibly in differing
	# versions of git, some that set origin after clone, some that
	# don't
	git remote rm origin 2>/dev/null || true
	git remote add origin "$GIT_URL"
	popd
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
    if test -x /usr/bin/lsb_release; then
	echo 'lsb_release --all:'; 
	lsb_release --all; 
	echo; 
    else
	    # what does this do, and how to replicate on RH?
	    # (RH has lsb, but the package drags in a whole X environment)
	: # do nothing
    fi
    echo 'lsmod:'; 
    lsmod; 
    echo; 
    if test -x /bin/rpm; then
	echo "rpm -qa:"
	rpm -qa
    elif test -x /usr/bin/dpkg; then
	    # Ubuntu
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

# initialize the make process

step-make() {
    cd source/src
    make V=1
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
    runtests -v
}

# read dmesg ring buffer again in case anything useful was logged 

step-closeout() {
    dmesg
}

step-$step; res=$?

echo "step $step exited with status $res" 1>&2
exit $res


