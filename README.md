machinekit-buildbot
===================

This is the configuration for the Machinekit buildbot at
http://buildbot.dovetail-automata.com/

Configuration parameters have been pulled out into a separate
'config.yaml' file.  See 'config.yaml.sample' for a complete example.

The basic build flow:

-----

- A git poller script triggers the 'ant' builder

- The 'ant' builder creates a tarball from git and triggers a build for
  each distro+arch combination, and a documentation build for each distro

- The '<distro>-<arch>' builders in turn trigger a
  '<distro>-<arch>-bld' builder and then trigger concurrent
  '<distro>-<arch>-<rtos>-tst' unit tests and '<distro>-<arch>-pkg'
  package build

- The '<distro>-<arch>-bld' builders unpack the tarball from 'ant',
  build in the appropriate chroot environment (debootstrap on Debian,
  mock on Red Hat derivatives), and then pack up a result tarball

  - The '<distro>-<arch>-<rtos>-tst' builders unpack the '-bld' result
    tarball and execute unit tests

- The '<distro>-<arch>-pkg' builders unpack the 'ant' tarball and
  build packages in a chroot environment

- The '<distro>-doc' builders unpack the 'ant' tarball and build
  documentation

-----

This is a work-in-progress, and wasn't designed, but evolved.
Therefore, the code can be messy and convoluted.

The emphasis of this work was on a simplified YAML configuration,
which has been achieved, to a great degree.
