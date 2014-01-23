#!/bin/bash -xe

##############################################
# CONVENIENCE ROUTINES

# print 7-digit SHA1 of $revision
shortrev() {
    # do it without needing a repo
    #$GIT rev-parse --short "$revision"
    echo ${revision%?????????????????????????????????}
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

##############################################
# PROCESS PARAMETERS

# This script starts execution in 'workdir'
WORKDIR="$(pwd)"

# If '-r' option exists, we're in a chroot
IN_CHROOT=false
if test "$1" = -r; then
    shift
    IN_CHROOT=true
    # Set $BUILD_TEST_DIR same as outside chroot so $EMC2_HOME
    # etc. are correct
    BUILD_TEST_DIR="$2"
    # BUILD_TEST_DIR is a sensible directory to start in
    cd $BUILD_TEST_DIR
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

GIT="git --git-dir=$repository"

# buildbot properties are not available in chroot
if ! $IN_CHROOT && ! $SERVER_SIDE; then
    # translate $distro and $arch into a mock config name
    case $distro in
	el*) deriv=sl${distro#el} ;;
	*) deriv=$distro
    esac
    case $arch in
	32) distro_arch=i386 ;;
	64) distro_arch=x86_64 ;;
    esac

    # this changeset's results directory
    changeset_result_dir=$result_dir/$(shortrev)

    # distro-arch results directory, also for inter-builder transfers
    result_da_dir=$changeset_result_dir/$distro-$arch

    # where the chroot build and non-chroot unit tests happen
    BUILD_TEST_DIR=/var/lib/buildslave/$distro-$arch-bldtest/build/source

    # tmp dir where the chroot build puts results
    BUILD_TEST_RESULT_DIR=/var/lib/buildslave/$distro-$arch-bldtest/result

    # name of git archive tarball
    git_archive_tarball=$changeset_result_dir/linuxcnc.tar.bz2

    # name of built sources tarball
    built_source_tarball=$result_da_dir/linuxcnc-built.tar.bz2

fi


##############################################
# REUSED STEPS

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
    if ! $IN_CHROOT; then
	echo 'lsmod:'; 
	lsmod; 
	echo; 
    fi
    if test -x /bin/rpm; then
	echo "rpm -qa:"
	rpm -qa
    elif test -x /usr/bin/dpkg; then
	echo 'dpkg --get-selections:'; 
	dpkg --get-selections;
    fi
}

##############################################
# INIT 'ANT'

# Build a clean tarball from git
step-tarball() {
    prefix=linuxcnc-$(rpm_version linuxcnc.spec)/
    mkdir -p $changeset_result_dir
    # (use 'dd' so destination is visible in 'bash -x' output)

    $GIT archive --prefix=$prefix "$revision" | \
	bzip2 | dd of=$git_archive_tarball
}

##############################################
# INIT DISTRO/FLAVOR 'BEE'

# Empty the distro-arch results dir
step-init() {
    rm $result_da_dir/*
}

##############################################
# BUILD

# Clear and populate working subdirectory from the repo.  At
# the same time, copy 'buildsteps.sh' here, accessible in the chroot.

step-sourcetree() {
    sudo -n rm -rf $BUILD_TEST_DIR
    mkdir -p $BUILD_TEST_DIR
    tar xCjf $BUILD_TEST_DIR $git_archive_tarball

    cp buildsteps.sh linuxcnc.spec $BUILD_TEST_DIR
}

# autogen needed build files

step-autogen() {
    cd $BUILD_TEST_DIR/linuxcnc-$(rpm_version linuxcnc.spec)/src
    ./autogen.sh
}

# configure the build process - use default options here

step-configure() {
    cd $BUILD_TEST_DIR/linuxcnc-$(rpm_version linuxcnc.spec)/src
    # lcnc doesn't look for {tcl,tk}Config.sh in /usr/lib64 in configure.in
    if test -f /usr/lib64/tkConfig.sh; then
	ARGS="--with-tkConfig=/usr/lib64/tkConfig.sh"
    fi
    if test -f /usr/lib64/tclConfig.sh; then
	ARGS="$ARGS --with-tclConfig=/usr/lib64/tclConfig.sh"
    fi
    ./configure $ARGS
}

# start the make process

step-make() {
    cd $BUILD_TEST_DIR/linuxcnc-$(rpm_version linuxcnc.spec)/src
    make V=1 -j$(num_procs)
    # make the tree writable by the buildbot user
    chgrp -R mockbuild ..
    chmod -R g+w ..
}

# create tarball of built source tree in common location for unit
# testing

step-result-tarball() {
    test -d $result_da_dir || mkdir -p $result_da_dir
    tar cCjf $BUILD_TEST_DIR $built_source_tarball \
	linuxcnc-$(rpm_version linuxcnc.spec)
}

##############################################
# TESTS

# Unpack the build result tarball created in the 'build' builder.

step-untar-build() {
    rm -rf $BUILD_TEST_DIR
    mkdir -p $BUILD_TEST_DIR
    cd $BUILD_TEST_DIR
    tar xjf $built_source_tarball
}

# read and clear dmesg ring buffer to aid in debugging failed builds
#
# note: fails if buildslave user doesn't have passwordless permission
# to run 'sudo /bin/dmesg'

# does this actually do anything, now that we have msgd?

step-dmesg() {
    sudo -n dmesg -c
}

# finally, set proper permissions on executables
#
# note: fails if buildslave user doesn't have passwordless permission
# to run 'sudo /usr/bin/make'

step-setuid() {
    cd $BUILD_TEST_DIR/linuxcnc-$(rpm_version linuxcnc.spec)/src
    sudo make setuid
}

# run the runtests in the default realtime environment

step-runtests() {
    cd $BUILD_TEST_DIR/linuxcnc-$(rpm_version linuxcnc.spec)
    source ./scripts/rip-environment
    # Force the flavor for runtests
    case "$buildername" in
	*-pos-tst) FLAVOR=posix ;;
	*-rtp-tst) FLAVOR=rt-preempt ;;
	*-x-tst) FLAVOR=xenomai ;;
	*-x-k-tst) FLAVOR=xenomai-kernel ;;
	*-rtk) FLAVOR=rtai-kernel ;;
	'') echo "buildername is unset!" 1>&2; exit 1 ;;
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


##############################################
# BUILD PACKAGES

# create tarball -%{version}%{?_gitrel:.%{_gitrel}}.tar.bz2
step-build-tarball() {
    # Update specfile's %_gitrel macro
    mkdir -p SPECS
    sed 's/%global\s\+_gitrel\s.*/%global _gitrel    '$(gitrel)'/' \
	linuxcnc.spec > SPECS/linuxcnc.spec

    # Create the tarball for Source0
    TARBALL="SOURCES/$(rpm_source0 SPECS/linuxcnc.spec)"
    mkdir -p SOURCES
    cp $git_archive_tarball $TARBALL
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

    # mock wants to write things as root to --resultdir, which means
    # no NFS.  Work around with an intermediate, local resultdir.
    mkdir -p $BUILD_TEST_RESULT_DIR

    mock -v -r $MOCK_CONFIG --no-clean --resultdir=$BUILD_TEST_RESULT_DIR \
	--configdir=$mock_config_dir --unpriv \
	SRPMS/$(rpm_nvr SPECS/linuxcnc.spec).src.rpm

    cp $BUILD_TEST_RESULT_DIR/* $result_da_dir
    rm -r $BUILD_TEST_RESULT_DIR
}



##############################################
# DOCS
#
# configure the doc build process - use default options here

step-configure-docs() {
    cd $BUILD_TEST_DIR/linuxcnc-$(rpm_version linuxcnc.spec)/src
    # lcnc doesn't look for {tcl,tk}Config.sh in /usr/lib64 in configure.in
    if test -f /usr/lib64/tkConfig.sh; then
	ARGS="--with-tkConfig=/usr/lib64/tkConfig.sh"
    fi
    if test -f /usr/lib64/tclConfig.sh; then
	ARGS="$ARGS --with-tclConfig=/usr/lib64/tclConfig.sh"
    fi
    ./configure $ARGS --enable-build-documentation
}

# start the make docs process

step-make-docs() {
    cd $BUILD_TEST_DIR/linuxcnc-$(rpm_version linuxcnc.spec)/src
    make V=1 -j$(num_procs) docs
}

##############################################
# DO IT:  RUN STEP

if $CHROOT; then
    cmd="$BUILD_TEST_DIR/buildsteps.sh -r $step $BUILD_TEST_DIR"
    mock -r ${deriv}-${distro_arch} --no-clean $MOCK_OPTS \
	--configdir=$mock_config_dir \
	--shell "/bin/bash -xe $cmd"
    res=$?

else
    step-$step; res=$?
fi

echo "step $step exited with status $res" 1>&2
exit $res


