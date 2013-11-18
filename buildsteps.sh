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

step-sourcetree() {
    cd $REPODIR
    rm -rf source
    git archive --prefix=source/ HEAD | tar xCf "$WORKDIR" -
}

step-dmesg() {
    sudo dmesg -c
}

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

step-autogen() {
    cd source/src
    ./autogen.sh
}

step-configure() {
    cd source/src
    ./configure
}

step-make() {
    cd source/src
    make V=1
}

step-setuid() {
    cd source/src
    sudo make setuid
}

step-runtests() {
    cd source
    source ./scripts/rip-environment
    runtests -v
}

step-closeout() {
    dmesg
}

step-$step || { echo "$usage" 1>&2; exit 1; }

