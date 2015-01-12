#!/bin/bash -e

# Uncomment this to print lots of debug output
#DEBUG=true
# (Otherwise debug is false)
test -n "$DEBUG" || DEBUG=false

# Enable verbose tarball packing/unpacking
if $DEBUG; then TAR_ARGS="$TAR_ARGS -v"; UNTAR_ARGS="$UNTAR_ARGS -v"; fi

# If pbzip2 exists, use it
/usr/bin/which pbzip2 >& /dev/null && BZIP2=pbzip2 || BZIP2=bzip2
TAR_ARGS="$TAR_ARGS -I $BZIP2"

# print the build slave name so we know where we are :-/
echo "Build slave hostname:  $(hostname)"

set -x

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
    rpm -q --specfile $1 -E '%{trace}\n' 2>&1 | \
	awk '/%{_sourcedir}\^/ { sub(".*%{_sourcedir}.",""); s=$0;}
		END {print s}'
}

# print RPM 'NVR' from specfile in $1
rpm_nvr() {
    rpm -q --specfile $1 --qf='%{name}-%{version}-%{release}\n' | head -1
}

# hack to get the number of processors for make -j
num_procs() {
    cat /proc/cpuinfo | grep ^processor | wc -l
}

# convenience function to test for debian
is_debian() {
    case "$distro" in
	d[0-9]*) return 0 ;;
	*) return 1 ;;
    esac
}

RemoveModules(){
    # Remove a list of modules recursively
    #
    # When RTAPI shuts down uncleanly, not only hal_lib and rtapi may
    # still be loaded, but also comp, motmod, or other modules that
    # depend on those.
    #
    # Check for loaded modules dependent on hal_lib and unload them
    # first.

    for MODULE in $*; do
        # recurse on any dependent modules in /proc/modules
        DEP_MODULES=$(cat /proc/modules | \
            awk '/^'$MODULE' / { mods=$4; gsub(","," ",mods); \
		gsub("\[permanent\]","",mods); print mods }')
        test "$DEP_MODULES" = - || RemoveModules $DEP_MODULES

        # remove module if still loaded
        grep -q "^$MODULE " /proc/modules && \
            linuxcnc_module_helper remove $MODULE

    done
}

# construct bind mount args for chroot-util.sh
debian_bind_mounts() {
    for i in $DEBIAN_BIND_MOUNTS; do
	echo -n " -b $i"
    done
    echo
}

debian-chroot-mount() {
    # run chroot-util
    $CHROOT_UTIL $(debian_bind_mounts) ${distro}-${arch} mount
    # print info and bomb if mounts aren't all right
    $CHROOT_UTIL $(debian_bind_mounts) ${distro}-${arch} mount-check
}

debian-chroot-umount() {   
    # run chroot-util
    $CHROOT_UTIL $(debian_bind_mounts) ${distro}-${arch} umount
    # print info if mounts aren't all right
    $CHROOT_UTIL $(debian_bind_mounts) ${distro}-${arch} umount-check || true
}

debian-chroot-run() {
    # debian-chroot-run CMD [ ARGS ... ]

    # Resolve the buildbot uid:gid for the chroot
    # http://lists.gnu.org/archive/html/coreutils/2012-05/msg00009.html
    BB_UID_GID=$(cat $debian_chroot_basedir/${distro}-${arch}/etc/passwd | \
	awk -F : '/^buildbot/ {print $3 ":" $4}')

    # Run the chroot
    $CHROOT_UTIL -n -u $BB_UID_GID ${distro}-${arch} run "$@"
}



##############################################
# PROCESS PARAMETERS

HOME=/home/buildbot

# This script starts execution in 'workdir'
WORKDIR="$(pwd)"
echo "WORKDIR contents:"
ls -la $WORKDIR

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
    # Show what the environment looks like in the chroot
    env
fi

# At least a step should be defined
usage="usage:  $0 <step>"
step=${1:?$usage}; shift

# Arch code for packaging build-indep .debs
BUILD_INDEP_ARCH_CODE=64

# Distro code for running Debian distro-indep jobs
DEBIAN_INDEP_DISTRO_CODE=d7

# If step name begins with 'chroot-', run in mock/debroot
CHROOT=false
if ! test $step = ${step#chroot-}; then
    CHROOT=true
    step=${step#chroot-}
    if test ${buildername} = ant; then
	# a chroot in ant means we want to run something in Debian
	distro=${DEBIAN_INDEP_DISTRO_CODE}
	arch=${BUILD_INDEP_ARCH_CODE}
    fi
fi

# buildbot sets wacky 077 umask
umask 022

# Debian likes this in chroots
LANG=C

GIT="git --git-dir=$repository"

# tmpfs disk size for building and testing; give more space to builders
TMPFS_SIZE=800m
case $buildername in
    *-pkg) TMPFS_SIZE=1500m ;;
esac

# Buildbot details for packaging
BB_URL=http://buildbot.dovetail-automata.com
MAINTAINER="Dovetail Automata LLC Buildbot <buildbot@dovetail-automata.com>"
# Indicate Dovetail Automata Buildbot build
DEB_RELEASE=1da.bbot

# Utilities
BUILDBOT_BINDIR=$HOME/bin
GITHUB_UTILS=${BUILDBOT_BINDIR}/github-utils.py
CHROOT_UTIL="${BUILDBOT_BINDIR}/chroot-util.sh -v"
export https_proxy=http://infra1:3128
export http_proxy=http://infra1:3128

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
	bb) distro_arch=armhfp ;;
	"") arch=64;  # pick an arch arbitrarily for e.g. docs
	    distro_arch=x86_64 ;;
    esac

    # Pull request number
    pr_num=$(($(basename ${branch/\/head/} | sed 's/[^0-9]//g')))
    if test $pr_num = 0; then
	# master branch
	pr_num=$master_pr_number
    fi

    # make some checks to lessen danger
    test -n "$result_dir"
    test -n "$(shortrev)"

    # this changeset's results directory
    changeset_result_dir=$result_dir/$(shortrev)

    # this changeset's pull-request directory link
    changeset_pr_link=$pr_link_dir/$pr_num

    # distro-arch results directory, also for inter-builder transfers
    result_da_dir=$changeset_result_dir/$distro-$arch

    # where the chroot build and non-chroot unit tests happen
    BUILD_TEST_DIR=/var/lib/buildslave/$distro-$arch-bldtest/build/source
    # ...except for the ant builder
    test ${buildername} != ant || BUILD_TEST_DIR=$WORKDIR

    # tmp dir where the chroot build puts results
    BUILD_TEST_RESULT_DIR=/var/lib/buildslave/$distro-$arch-bldtest/result

    # name of git archive tarball
    git_archive_tarball=$changeset_result_dir/machinekit.tar.bz2

    # name of built sources tarball
    built_source_tarball=$result_da_dir/machinekit-built.tar.bz2

    # list of bind mounts for chroot
    DEBIAN_BIND_MOUNTS="$BUILD_TEST_DIR $WORKDIR $changeset_result_dir"

fi

# package version
VERSION=0.1.${ant_build_number}

# mock breaks if /usr/bin comes after /usr/sbin in $PATH
PATH=/bin:/usr/bin:/usr/sbin:/sbin

# set environment variable if running in a VM
case $buildername in
    d7-bb-*-tst) : ;; # not a VM
    *) export IS_VM=yes ;; # others are all VMs
esac

# configure RTAI kernel version through environment
export RTAI_KVER=$(for i in /lib/modules/*-rtai.*; do \
    basename $(readlink -e $i); done)


##############################################
# INIT 'ANT'

# Build a clean tarball from git
step-tarball() {
    prefix=machinekit-$VERSION/
    # create results dir and PR link
    rm -rf $changeset_result_dir
    mkdir -p $changeset_result_dir
    ls -l $changeset_result_dir
    ln -sfn $changeset_result_dir $changeset_pr_link
    # (use 'dd' so destination is visible in 'bash -x' output)

    $GIT archive --prefix=$prefix "$revision" | \
	$BZIP2 | dd of=$git_archive_tarball
}

# Build Debian source packages
#
# configure debian package in chroot
step-configure-source-package() {
    for codename in $debian_codenames; do

	# untar sources
	SRCDIR=$(pwd)/source
	mkdir -p $SRCDIR; rm -rf $SRCDIR/*

	ln -f $changeset_result_dir/machinekit.tar.bz2 \
	    $changeset_result_dir/machinekit_${VERSION}.orig.tar.bz2
	tar xjCf $SRCDIR $changeset_result_dir/machinekit.tar.bz2 --strip-components=1

	# Destination directory
	cd $changeset_result_dir

	# # Generate variables used in changelog
	# PACKAGE=$(dpkg-parsechangelog -l$SRCDIR/debian/changelog \
	# 	| awk '/^Source:/ { print $2 }')
	# VERSION=2:0.$ant_build_number  # Resetting version to 0.<pr#>, so bump epoch

	# # generate changelog for the distro
	# CHANGELOG=changelog-${codename}

	# 	# Add changelog entry with version like
	# 	# 2:0.206-1da.bbot~wheezy1, where 2 is the epoch (bumped from
	# 	# 1 in the LinuxCNC project), 0 is the release, 206 is the PR
	# 	# number, 1da.bbot indicates a Dovetail Buildbot build, and
	# 	# wheezy1 is the codename for a common Deb archive pool.
	# PACKAGE_VERSION=${VERSION}-${DEB_RELEASE}~${codename}1

	# 	# Buildbot doesn't let us pass buildnumber, an int, into the
	# 	# script env. :P Otherwise we could put a link to the buildbot
	# 	# as well.
	# 	# BUILD_URL=${BB_URL}/builders/${buildername}/builds/${buildnumber}

	cp $SRCDIR/debian/changelog .
	# {
	    # echo "${PACKAGE} (${PACKAGE_VERSION}) stable; urgency=low"
	    # echo
	    # echo "  * Buildbot rebuild for ${codename}, pull request ${ant_build_number}"
	    # echo "    - https://github.com/machinekit/machinekit/pull/${ant_build_number}"
	    # echo
	    # echo " -- ${MAINTAINER}  $(date -R)"
	    # echo
	#     $GITHUB_UTILS -c $pr_num -d $codename -b $ant_build_number \
	# 	-s $revision
	#     cat changelog
	# } > $SRCDIR/debian/changelog
	$GITHUB_UTILS -c $pr_num -d $codename -b $ant_build_number \
	    -s $revision -o $SRCDIR/debian/changelog
	cat changelog >> $SRCDIR/debian/changelog


	# Print changelog debug info
	dpkg-parsechangelog -l$SRCDIR/debian/changelog

	# Configure package; set POSIX, RT_PREEMPT, XENOMAI and docs
	# by default
	$SRCDIR/debian/configure -prxdt 8.5

	# build source package with updated distro changelog
	dpkg-source -i -I -l${CHANGELOG} -b $SRCDIR

	# clean up
	rm -rf $SRCDIR
    done
}

# Add debian packages to archive
step-debian-archive() {
    cd $changeset_result_dir
    repodir=$changeset_result_dir/debian_archive
    for codename in $debian_codenames; do
	case $codename in
	    wheezy) DIST=d7 ;;
	    jessie) DIST=d8 ;;
	    *)  echo "No such codename"; exit 1 ;;
	esac

	# set up new archive for this distro from scratch
	rm -rf $repodir/conf-$codename; mkdir -p $repodir/conf-$codename
	cat > $repodir/conf-$codename/distributions <<EOF
# Origin, Label, Description are copied into the Release file
Origin: Dovetail Automata
Label: Machinekit
Description: Machinekit dependency packages for $codename,
 courtesy of Dovetail Automata LLC
# copied into Release files; stable, testing or unstable
#
# (the Debian kernel packaging wants anything besides testing or
# unstable when the release looks like '3.8.13-1mk~wheezy1')
Suite: stable
# distribution; dists/<codename> & in Release files (auto-configured)
Codename: $codename
# list of architectures
Architectures: amd64 i386 armhf source
# List of distribution components
Components: main
# When we are ready...
#SignWith: 
EOF
	REPREPRO="reprepro -VV -b $repodir \
	   --confdir +b/conf-$codename --dbdir +b/db-$codename -C main"
	# Add source package
	$REPREPRO includedsc $codename *.dsc
	# Add binary packages
	$REPREPRO includedeb $codename $DIST-*/*.deb
	# Debug info
	$REPREPRO list $codename
    done
}

##############################################
# INIT DISTRO/FLAVOR 'BEE'

# Empty the distro-arch results dir
step-init() {
    rm -rf $result_da_dir
    mkdir -p $result_da_dir
}

##############################################
# BUILD
#
# Build Machinekit in a mock chroot environment; includes building docs

# Populate working subdirectory from the repo.  At the same time, copy
# 'buildsteps.sh' here, accessible in the chroot.

step-sourcetree() {
    # unpack sources
    tar xCf $BUILD_TEST_DIR $git_archive_tarball $UNTAR_ARGS
    # be sure these are available in the chroot
    cp buildsteps.sh machinekit.spec $BUILD_TEST_DIR
}

# Report some useful info back to the buildmaster

if test $step = environment; then
    # run mock verbosely in environment step
    MOCK_OPTS="$MOCK_OPTS -v"
fi

step-environment() {
    set +x
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
	cat /etc/redhat-release
    fi
    echo 'env:'
    env
    echo
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
    cd $BUILD_TEST_DIR/machinekit-$VERSION/src
    ./autogen.sh
}

# configure the build process - use default options here

step-configure() {
    cd $BUILD_TEST_DIR/machinekit-$VERSION/src
    # lcnc doesn't look for {tcl,tk}Config.sh in /usr/lib64 in configure.in
    if test -f /usr/lib64/tkConfig.sh; then
	ARGS="--with-tkConfig=/usr/lib64/tkConfig.sh"
    fi
    if test -f /usr/lib64/tclConfig.sh; then
	ARGS="$ARGS --with-tclConfig=/usr/lib64/tclConfig.sh"
    fi
    if ! test ${buildername%-doc} = ${buildername}; then
	ARGS="$ARGS --enable-build-documentation"
    fi
    # don't try to build xenomai-kernel or rtpreempt on beaglebone
    if test "${buildername}" = "${distro}-bb-bld"; then
	ARGS="$ARGS --with-xenomai --with-posix"
    fi

    ./configure $ARGS
}

# start the make process

step-make() {
    cd $BUILD_TEST_DIR/machinekit-$VERSION/src
    TARGET=
    if ! test ${buildername%-doc} = ${buildername}; then
	TARGET=docs
    fi
    make V=1 -j$(num_procs) $TARGET
    if ! is_debian; then
        # in mock:  make the tree writable by the buildbot user
	chgrp -R mockbuild ..
	chmod -R g+w ..
    fi
}

# create tarball of built source tree in common location for unit
# testing

step-result-tarball() {
    # don't tar results for doc builds
    test ${buildername#${distro}-} = doc && return

    test -d $result_da_dir || mkdir -p $result_da_dir
    tar cCf $BUILD_TEST_DIR $built_source_tarball $TAR_ARGS \
	machinekit-$VERSION
}

##############################################
# TESTS

# Unpack the build result tarball created in the 'build' builder.

step-untar-build() {
    cd $BUILD_TEST_DIR
    tar xf $built_source_tarball $UNTAR_ARGS
}


# Set up RT environment; used by test-environment and runtest steps

rtapi-init() {
    cd $BUILD_TEST_DIR/machinekit-*
    source ./scripts/rip-environment

    # Force the flavor for runtests; set non-conflicting instance
    # numbers so a crash in one flavor doesn't hurt another
    case "$buildername" in
	*-pos-tst) FLAVOR=posix ;;
	*-rtp-tst) FLAVOR=rt-preempt ;;
	*-x-tst) FLAVOR=xenomai ;;
	*-x-k-tst) FLAVOR=xenomai-kernel ;;
	*-rtk-tst) FLAVOR=rtai-kernel ;;
	'') echo "buildername is unset!" 1>&2; exit 1 ;;
	*) echo "buildername '$buildername' unknown!" 1>&2; exit 1 ;;
    esac
    echo "Detected flavor '${FLAVOR}' from builder name ${buildername}"
    export FLAVOR
}


# Gather data about test environment for debugging

step-test-environment() {
    #FIXME debugging
    #set +x
    rtapi-init
    echo 'default flavor:'
    flavor
    echo
    echo 'env:'
    env
    echo
    echo 'uname -a:'; 
    uname -a; 
    echo; 
    echo 'ulimit -a:'; 
    ulimit -a; 
    echo; 
    echo "ps -p $$ -o cgroup=:"
    ps -p $$ -o cgroup=
    echo
    echo "cat /proc/$$/cgroup:"
    cat /proc/$$/cgroup
    echo
    echo 'hostname:'
    hostname
    echo; 
    echo 'gcc --version:'; 
    gcc --version; 
    echo; 
    echo 'python -V:'; 
    python -V; 
    echo; 
    if test "$FLAVOR" = xenomai -o "$FLAVOR" = xenomai-kernel; then
	if test -x /usr/bin/xenomai-gid-ctl; then
	    # 2.6.3 RPMs include this utility
	    echo "xenomai-gid-ctl test:"
	    /usr/bin/xenomai-gid-ctl test
	else
	    # otherwise, query directly
	    xeno_gid=$(cat /sys/module/xeno_nucleus/parameters/xenomai_gid)
	    if test $xeno_gid = -1; then
		echo "xenomai non-root group disabled!"
	    else
		xeno_group=$(getent group | \
		    awk -F : "/:${xeno_gid}:/ { print \$1 }")
		echo "xenomai non-root group: " \
		    "name=${xeno_group}; gid=${xeno_gid}"
	    fi
	fi
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
    echo 'realtime status:'
    realtime status || true
    echo
    if ps -C linuxcncrsh -o pid=; then
	echo 'killing detected linuxcncrsh instance:'
	killall linuxcncrsh
	sleep 1
    fi
    if test "$FLAVOR" = xenomai-kernel; then
	echo "looking for hal_lib in /proc/modules:"
	depmods="$(awk '/^hal_lib / { gsub(","," ",$4); print $4 }' \
		 /proc/modules)"
	case "$depmods" in
	    '') echo  "    not loaded" ;;
	    '-') echo "   loaded; no depending modules loaded" ;;
	    *)  echo  "   loaded with depending modules: $depmods; removing"
		RemoveModules $depmods
		;;
	esac
	echo
    fi
    # run 'realtime stop' for all applicable flavors
    
    case $(unset FLAVOR; flavor) in
	xenomai) STOP_FLAVORS="xenomai xenomai-kernel posix" ;;
	posix) STOP_FLAVORS="posix" ;;
	*) STOP_FLAVORS="$FLAVOR posix" ;;
    esac
    for f in $STOP_FLAVORS; do
	echo "stopping realtime environment for flavor $f:"
	FLAVOR=$f DEBUG=5 MSGD_OPTS=-s realtime stop || true
	echo
    done
}

# read and clear dmesg ring buffer to aid in debugging failed builds
#
# note: fails if buildslave user doesn't have passwordless permission
# to run 'sudo /bin/dmesg'

# does this actually do anything, now that we have msgd?

step-dmesg() {
    sudo -n dmesg -c

    # clean up old runtest.* and linuxcnc.* directories under /tmp
    echo "cleaning up /tmp:"
    ls -l /tmp
    df -h /tmp
    # find /tmp  -maxdepth 1 -mtime +1 -user buildbot \
    # 	\( -name runtest.\* -o -name linuxcnc.\* \) \
    # 	-exec rm -rf '{}' \;
    rm -rf /tmp/linuxcnc.*
}

# set proper permissions on executables
#
# note: fails if buildslave user doesn't have passwordless permission
# to run 'sudo /usr/bin/make'

step-setuid() {
    cd $BUILD_TEST_DIR/machinekit-*/src
    sudo make setuid
}

# run the runtests in the default realtime environment

step-runtests() {
    rtapi-init

    # debug a test on all flavors
    #
    # run an initial debugging test; this will fail, but will expose
    # extra debug messages to help locate the problem
    #
    # DEBUG=5 MSGD_OPTS=-s runtests -v tests/linuxcncrsh || true

    export DEBUG=5
    export MSGD_OPTS=-s
    bash -xe runtests -v
}

# read dmesg ring buffer again in case anything useful was logged 
# save test results

step-closeout() {
    cd $BUILD_TEST_DIR/machinekit-*
    dmesg
    tar cf $result_da_dir/tests-${buildername}.tar.bz2 $TAR_ARGS tests
}


##############################################
# BUILD PACKAGES

# create tarball -%{version}%{?_gitrel:.%{_gitrel}}.tar.bz2
step-build-tarball() {
    # clean out old RPM build directories
    rm -rf BUILD BUILDROOT RPMS SOURCES SPECS SRPMS

    # Update specfile's %_gitrel macro
    mkdir -p SPECS
    sed 's/%global\s\+_gitrel\s.*/%global _gitrel    '$(gitrel)'/' \
	machinekit.spec > SPECS/machinekit.spec

    # Create the tarball for Source0
    TARBALL="SOURCES/$(rpm_source0 SPECS/machinekit.spec)"
    mkdir -p SOURCES
    cp $git_archive_tarball $TARBALL
}

# create machinekit-0.1-<release>-<shortrev>.src.rpm or Debian source
# package
step-prep-source-package() {
    if is_debian; then
	# Unpack source package
	cd $BUILD_TEST_DIR
	dpkg-source -x $changeset_result_dir/machinekit_*-${DEB_RELEASE}*.dsc
	cd machinekit-0.1.*

	# construct args to build xenomai-kernel packages from
	# installed linux-headers packages:  linux-headers-xenomai, but
	# not -common-.
	xenomai_kver_list="$(dpkg-query -W linux-headers-\*-xenomai\* | \
	    grep -v common | \
	    sed 's/^linux-headers-\([^	]*\)	.*/\1/')"
	local xk_args
	for kver in $xenomai_kver_list; do xk_args+=" -X${kver}"; done

	# construct args to build rtai-kernel packages from
	# installed linux-headers packages:  linux-headers-rtai, but
	# not -common-.
	rtai_kver_list="$(dpkg-query -W linux-headers-\*-rtai\* | \
	    grep -v common | \
	    sed 's/^linux-headers-\([^	]*\)	.*/\1/')"
	local rk_args
	for kver in $rtai_kver_list; do rk_args+=" -R${kver}"; done

	# Tune source package configuration for each arch:
	# - Only build docs on amd64
	# - Only build posix and xenomai on beaglebone
	# - Add xenomai-kernel packages on x86
	local args=-px  # always build POSIX and Xenomai
	case "${buildername}" in
	    *-bb-pkg)  : ;;  # nothing extra
	    *-32-pkg)  args+=" -r ${xk_args} ${rk_args}" ;;
	    *-64-pkg)  args+=" -rd ${xk_args} ${rk_args}" ;;
	    *)  echo "Unknown buildername ${buildername}"; exit 1 ;;
	esac
	# reconfigure the package
	debian/configure ${args}
	# debugging
	ls -l debian
	head -20 debian/changelog
	cat debian/control
	cat debian/rules
    else
	rpmbuild --define "_topdir $(pwd)" -bs SPECS/machinekit.spec
    fi
}

# build binary packages
step-build-binary-package() {
    if is_debian; then
	cd $BUILD_TEST_DIR/machinekit-0.1.*

	# Make parallel
	export DEB_BUILD_OPTIONS=parallel=$(num_procs)

	# Only build arch-indep packages on the specified arch
	DPKG_BINARY_OPTS=-b
	test $arch = $BUILD_INDEP_ARCH_CODE || DPKG_BINARY_OPTS=-B

	# build binary package
	dpkg-buildpackage -us -uc -rfakeroot $DPKG_BINARY_OPTS

    else  # RedHat
        # Calculate the mock config name
	case $arch in
	    32) RH_ARCH=i386 ;;
	    64) RH_ARCH=x86_64 ;;
	    bb) RH_ARCH=armhfp ;;
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
	    SRPMS/$(rpm_nvr SPECS/machinekit.spec).src.rpm

	cp $BUILD_TEST_RESULT_DIR/* $result_da_dir
	rm -r $BUILD_TEST_RESULT_DIR
    fi
}

# build package archive
step-build-ppa() {
    cd $BUILD_TEST_DIR
    # copy results back
    cp *.deb *.changes "$result_da_dir"
    if test -f machinekit-0.1.*/src/nosetests.rt.log; then
	cp machinekit-0.1.*/src/nosetests.rt.log \
	    machinekit-0.1.*/src/nosetests.xml "$result_da_dir"
    fi
}


##############################################
# INIT AND CLEAN BUILDROOT

step-init-buildroot() {
    # ensure directory exists
    if ! test -d $BUILD_TEST_DIR; then
	mkdir -p $BUILD_TEST_DIR
    fi
    # ensure tmpfs is mounted
    if ! df -t tmpfs $BUILD_TEST_DIR >& /dev/null; then
	sudo -n mount -t tmpfs -o uid=buildbot,mode=755,size=$TMPFS_SIZE \
	    tmpfs $BUILD_TEST_DIR
    fi
    if $DEBUG; then df -h $BUILD_TEST_DIR; fi
    # ensure build root is clean
    sudo -n rm -rf $BUILD_TEST_DIR/*
}

# A common step to clean things up; right now, just unmount tmpfs
step-clean-buildroot() {
    # if the build directory is a tmpfs, unmount it, if possible
    if df -t tmpfs $BUILD_TEST_DIR >&/dev/null; then
	df -h -T $BUILD_TEST_DIR
	sudo -n umount -t tmpfs $BUILD_TEST_DIR
    else
	echo "Build directory $BUILD_TEST_DIR was not a tmpfs mount!" 1>&2
	exit 1
    fi
}


##############################################
# DO IT:  RUN STEP

if $CHROOT; then
    test ${buildername} = ant || \
	cp $WORKDIR/{buildsteps.sh,machinekit.spec} $BUILD_TEST_DIR
    cmd="$BUILD_TEST_DIR/buildsteps.sh -r $step $BUILD_TEST_DIR"
    if is_debian; then
	trap debian-chroot-umount 0 1 2 3 9 15
	debian-chroot-mount
	debian-chroot-run \
	    env \
	    buildername=$buildername \
	    result_da_dir=$result_da_dir \
	    changeset_result_dir=$changeset_result_dir \
	    pr_num=$pr_num \
	    ant_build_number=$ant_build_number \
	    arch=$arch \
	    debian_codenames=$debian_codenames \
	    HOME=$HOME \
	    /bin/bash -xe $cmd
	res=$?
    else
	mock -r ${deriv}-${distro_arch} --no-clean $MOCK_OPTS \
	    --configdir=$mock_config_dir \
	    --shell "env \
		buildername=$buildername \
		pr_num=$pr_num \
		/bin/bash -xe $cmd"
	res=$?
    fi

else
    step-$step; res=$?
fi

echo "step $step exited with status $res" 1>&2
exit $res


