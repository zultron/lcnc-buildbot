#!/bin/bash -xe

# This script starts execution in 'workdir'
WORKDIR="$(pwd)"

# If '-r' option exists, we're in a chroot
IN_CHROOT=false
SOURCE_DIR=source
if test "$1" = -r; then
    shift
    IN_CHROOT=true
    SOURCE_DIR=/buildsrc/source
fi

# At least a step should be defined
usage="usage:  $0 <step>"
step=${1:?$usage}; shift

# If step name begins with 'chroot-', run in mock
CHROOT=false
if ! test $step = ${step#chroot-}; then
    CHROOT=true
    step=${step#chroot-}
fi

# buildbot sets wacky 077 umask
umask 022

GIT="git --git-dir=$repodir"

# buildbot properties are not available in chroot
if ! $IN_CHROOT; then
    # translate $distro and $arch into a mock config name
    case $distro in
	el*) deriv=sl${distro#el} ;;
	*) deriv=$distro
    esac
    case $arch in
	32) distro_arch=i386 ;;
	64) distro_arch=x86_64 ;;
	*) echo "unknown arch $arch" 1>&2; exit 1 ;;
    esac

    # where to put temporary files between steps
    transfer_dir=$transfer_dir/$distro-$arch
fi

# print 7-digit SHA1 of $revision
shortrev() {
    $GIT rev-parse --short "$revision"
}

# print a value suitable for the RPM 'gitrel' macro
gitrel() {
    echo "$(date +%Y%m%d)git$(shortrev)"
}

# print RPM 'Source0' filename from specfile in $1
rpm_source0() {
    rpm -q --specfile $1 -E '%{trace}\n' 2>&1 | awk '/Source0:/ {print $3}'
}

# print RPM version from specfile in $1
rpm_version() {
    rpm -q --specfile $1 --qf='%{version}\n' | head -1
}

# print RPM 'NVR' from specfile in $1
rpm_nvr() {
    rpm -q --specfile $1 --qf='%{name}-%{version}-%{release}\n' | head -1
}

# hack to get the number of processors for make -j
num_procs() {
    cat /proc/cpuinfo | grep ^processor | wc -l
}

# fetch into the repo if it already exists in the 'buildir' subdir;
# else clone a fresh repo

step-init-git() {
    # sanity check/create the git repo directory
    if test -z "$repodir"; then
	echo "ERROR:  'repodir' environment variable not configured"
	exit 1
    elif ! mkdir -p $repodir; then
	echo "ERROR:  unable to create repo directory '$repodir'"
	exit 1
    fi

    # git version annoyance
    case "$(git --version | awk '{print $3}')" in
	1.[0-6].*|1.7.[0-3]*|1.7.[0-3]*.*|1.7.4.[01])
	# sheesh; want anything before 1.7.4.2.8.g3ccd6, I believe
	    GIT_REMOTE_MIRROR="--mirror" ;;
	*)
	    GIT_REMOTE_MIRROR="--mirror=fetch" ;;
    esac

    # check there's a git repo
    if $GIT branch >/dev/null 2>&1; then
	pushd $repodir
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
	    rm -rf $repodir
	    echo "fetch failed; retrying"
	    step-init
	else
	    set -e
	    echo "fetch succeeded"
	    popd
	fi
    else
	git clone --mirror "$repository" $repodir
    fi
}

# create tarball -%{version}%{?_gitrel:.%{_gitrel}}.tar.bz2
step-build-tarball() {
    # Update %_gitrel macro
    mkdir -p SPECS
    sed 's/%global\s\+_gitrel\s.*/%global _gitrel    '$(gitrel)'/' \
	linuxcnc.spec > SPECS/linuxcnc.spec

    # Create the tarball for Source0
    TARBALL="$WORKDIR/SOURCES/$(rpm_source0 SPECS/linuxcnc.spec)"
    mkdir -p SOURCES
    $GIT archive --prefix=linuxcnc-$(rpm_version SPECS/linuxcnc.spec)/ \
	"$revision" | bzip2 > $TARBALL
}

# create linuxcnc-2.6-<release>-<shortrev>.src.rpm source package
step-build-source-package() {
    rpmbuild --define "_topdir $(pwd)" -bs SPECS/linuxcnc.spec
}

# build source package
step-build-binary-package() {
    # Calculate the mock config name
    case $arch in
	32) RH_ARCH=i386 ;;
	64) RH_ARCH=x86_64 ;;
	*) echo "Unknown arch '$arch'"; exit 1 ;;
    esac
    case $distro in
	el6) MOCK_CONFIG=sl6-$RH_ARCH  ;;
	el7) MOCK_CONFIG=sl7-$RH_ARCH  ;;
	fc*) MOCK_CONFIG=$distro-$RH_ARCH ;;
	*) echo "Unknown distro '$distro'"; exit 1 ;;
    esac

    mock -v -r $MOCK_CONFIG --no-clean \
	SRPMS/$(rpm_nvr SPECS/linuxcnc.spec).src.rpm
}



# clear and populate working subdirectory from the repo

step-sourcetree() {
    sudo -n rm -rf $WORKDIR/source
    git --git-dir=$repository archive --prefix=source/ "$revision" | \
	tar xCf "$WORKDIR" -
}

# read and clear dmesg ring buffer to aid in debugging failed builds
#
# note: fails if buildslave user doesn't have passwordless permission
# to run 'sudo /bin/dmesg'

step-dmesg() {
    sudo dmesg -c
}

# report some useful info back to the buildmaster

if test $step = environment; then
    # run mock verbosely in environment step
    MOCK_OPTS="$MOCK_OPTS -v"
fi

step-environment() {
    set +x
    echo 'uname -a:'; 
    uname -a; 
    echo; 
    echo 'ulimit -a:'; 
    ulimit -a; 
    echo; 
    echo 'gcc --version:'; 
    gcc --version; 
    echo; 
    echo 'python -V:'; 
    python -V; 
    echo; 
    if test ${buildername} != ${buildername%xenomai} -a \
	-x /usr/bin/xenomai-gid-ctl; then
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
    cd $SOURCE_DIR/src
    ./autogen.sh
}

# configure the build process - use default options here

step-configure() {
    cd $SOURCE_DIR/src
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
    cd $SOURCE_DIR/src
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
    cd $SOURCE_DIR/src
    make V=1 -j$(num_procs)
}

# create tarball of built source tree for unit testing

step-result-tarball() {
    cd $SOURCE_DIR
    tar czf /builddir/linuxcnc.tgz .
    chgrp mockbuild /builddir/linuxcnc.tgz
    chmod g+rw /builddir/linuxcnc.tgz
}

# move built source tarball to common place for unit testing

step-move-tarball() {
    mv $WORKDIR/linuxcnc.tgz \
	$transfer_dir/linuxcnc-$distro-$arch.tgz
}

# start the make docs process

step-make-docs() {
    cd $SOURCE_DIR/src
    make V=1 -j$(num_procs) docs
}

# finally, set proper permissions on executables
#
# note: fails if buildslave user doesn't have passwordless permission
# to run 'sudo /usr/bin/make'

step-setuid() {
    cd $SOURCE_DIR/src
    sudo make setuid
}

# run the runtests in the default realtime environment

step-runtests() {
    cd $SOURCE_DIR
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

    # FIXME testing xenomai
    if test ${buildername} != ${buildername%xenomai}; then
	# turn on debugging for xenomai builders; this will fail, but
	# will expose extra debug messages to help locate the problem
	tail -F tests/abs.0/stderr & TAIL_PID=$!
	DEBUG=5 MSGD_OPTS=-s runtests -v tests/abs.0 || true
	kill $TAIL_PID
    fi

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

if $CHROOT; then
    mock -r ${deriv}-${distro_arch} --no-clean $MOCK_OPTS \
	--configdir=$mock_config_dir \
	--shell "/bin/bash -xe /buildsrc/buildsteps.sh -r $step"
    res=$?

else
    step-$step; res=$?
fi

echo "step $step exited with status $res" 1>&2
exit $res


