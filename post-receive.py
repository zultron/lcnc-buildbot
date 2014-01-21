#! /usr/bin/env python

# This script expects one line for each new revision on the form
#   <oldrev> <newrev> <refname>
#
# For example:
#   aa453216d1b3e49e7f6f98441fa56946ddcd6a20
#   68f7abf4e6f922807889f52bc043ecd31b79f814 refs/heads/master
#
# Each of these changes will be passed to the buildbot server along
# with any other change information we manage to extract from the
# repository.
#
# This script is meant to be run from hooks/post-receive in the git
# repository. It can also be run at client side with hooks/post-merge
# after using this wrapper:

#!/bin/sh
# PRE=$(git rev-parse 'HEAD@{1}')
# POST=$(git rev-parse HEAD)
# SYMNAME=$(git rev-parse --symbolic-full-name HEAD)
# echo "$PRE $POST $SYMNAME" | git_buildbot.py
#
# Largely based on contrib/hooks/post-receive-email from git.

import commands
import logging
import os
import os.path
import re
import sys
import yaml

from twisted.spread import pb
from twisted.cred import credentials
from twisted.internet import reactor, defer

from optparse import OptionParser

# The master server address comes from the command line or the config file

master = None

# When sending the notification, send this category if (and only if)
# it's set (via --category)

category = None

# When sending the notification, send this project if (and only if)
# it's set (via --project)

project = None

# Username portion of PB login credentials to send the changes to the master
username = "git"

# Config file to retrieve params from
configfile = os.sep.join((os.path.dirname(os.path.abspath(__file__)),
                          'config.yaml'))

# Repos from config file
git_repos = {}

# Password portion of PB login credentials to send the changes to the master
auth = "secret-pass"

# When converting strings to unicode, assume this encoding. 
# (set with --encoding)

encoding = 'utf8'

# git fetch output prints updates in lines like this:
#  * [new branch]      bar        -> bar
#  + a1576ed...2a22233 foo        -> foo  (forced update)
updatere=re.compile(r'^(?:\+ )?([^. ]+)\.\.\.?([^. ]+) +([^ ]+) .*')
newbranchre=re.compile(r'^ ?\* \[new branch\] +([^ ]+) .*')


changes = []

def readconfig(configfile):
    return yaml.load(open(configfile,'r').read())


def connectFailed(error):
    logging.error("Could not connect to %s: %s"
            % (master, error.getErrorMessage()))
    return error


def addChanges(remote, changei, src='git'):
    def addChange(c):
        logging.info("New revision: %s" % c['revision'][:8])
        for key, value in c.iteritems():
            logging.debug("  %s: %s" % (key, value))

        c['src'] = src
        d = remote.callRemote('addChange', c)
        return d

    finished_d = defer.Deferred()
    def iter():
        try:
            c = changei.next()
            d = addChange(c)
            # handle successful completion by re-iterating, but not immediately
            # as that will blow out the Python stack
            def cb(_):
                reactor.callLater(0, iter)
            d.addCallback(cb)
            # and pass errors along to the outer deferred
            d.addErrback(finished_d.errback)
        except StopIteration:
            remote.broker.transport.loseConnection()
            finished_d.callback(None)

    iter()
    return finished_d


def connected(remote):
    return addChanges(remote, changes.__iter__())


def grab_commit_info(c, rconfig):
    # Extract information about committer and files using git show
    f = os.popen("%(git)s show --raw --pretty=full %(revision)s" % rconfig,
                 'r')

    files = []
    comments = []

    while True:
        line = f.readline()
        if not line:
            break

        if line.startswith(4*' '):
            comments.append(line[4:])

        m = re.match(r"^:.*[MAD]\s+(.+)$", line)
        if m:
            logging.debug("Got file: %s" % m.group(1))
            files.append(unicode(m.group(1), encoding=encoding))
            continue

        m = re.match(r"^Author:\s+(.+)$", line)
        if m:
            logging.debug("Got author: %s" % m.group(1))
            c['who'] = unicode(m.group(1), encoding=encoding)

        if re.match(r"^Merge: .*$", line):
            files.append('merge')

    c['comments'] = ''.join(comments)
    c['files'] = files
    status = f.close()
    if status:
        logging.warning("git show exited with status %d" % status)


def gen_changes(input, rconfig):
    while True:
        line = input.readline()
        if not line:
            break

        logging.debug("Change: %s" % line)

        m = re.match(r"^([0-9a-f]+) (.*)$", line.strip())
        rconfig['revision'] = m.group(1)

        c = {'revision': m.group(1),
             'branch': unicode(rconfig['branch'], encoding=encoding),
        }

        if category:
            c['category'] = unicode(category, encoding=encoding)

        c['repository'] = unicode(rconfig['local-remote'], encoding=encoding)

        if project:
            c['project'] = unicode(project, encoding=encoding)

        grab_commit_info(c, rconfig)
        changes.append(c)


def gen_create_branch_changes(rconfig):
    # A new branch has been created. Generate changes for everything
    # up to `newrev' which does not exist in any branch but `refname'.
    #
    # Note that this may be inaccurate if two new branches are created
    # at the same time, pointing to the same commit, or if there are
    # commits that only exists in a common subset of the new branches.

    logging.info("Branch `%(branch)s' created" % rconfig)

    f = os.popen("%(git)s rev-parse --not --branches"
                 "| grep -v $(%(git)s rev-parse %(branch)s)"
                 "| %(git)s rev-list --reverse --pretty=oneline "
                 "--stdin %(newrev)s" % rconfig,
                 'r')

    gen_changes(f, rconfig)

    status = f.close()
    if status:
        logging.warning("git rev-list exited with status %d" % status)


def gen_update_branch_changes(rconfig):
    # A branch has been updated. If it was a fast-forward update,
    # generate Change events for everything between oldrev and newrev.
    #
    # In case of a forced update, first generate a "fake" Change event
    # rewinding the branch to the common ancestor of oldrev and
    # newrev. Then, generate Change events for each commit between the
    # common ancestor and newrev.

    logging.info("Branch `%(branch)s' updated %(oldrev)s .. %(newrev)s"
            % rconfig)

    rconfig['baserev'] = commands.getoutput(
        "%(git)s merge-base %(oldrev)s %(newrev)s" % rconfig)
    rconfig['baserev_s'] = rconfig['baserev'][:8]
    logging.debug("oldrev=%(oldrev)s newrev=%(newrev)s baserev=%(baserev_s)s" %
                  rconfig)
    if rconfig['baserev'] != rconfig['oldrev']:
        c = {'revision': rconfig['baserev'],
             'comments': "Rewind branch",
             'branch': unicode(rconfig['branch'], encoding=encoding),
             'who': "dummy",
        }
        logging.info("Branch %(branch)s was rewound to %(baserev_s)s" %
                     rconfig)
        files = []
        f = os.popen("%(git)s diff --raw %(oldrev)s..%(baserev)s" % 
                     rconfig, 'r')
        while True:
            line = f.readline()
            if not line:
                break

            m = re.match(r"^:.*[MAD]\s+(.+)$", line)
            if m is None:
                logging.error("output does not match regex: %s" % line)
                continue

            file = m.group(1)
            logging.debug("  Rewound file: %s" % file)
            files.append(unicode(file, encoding=encoding))

        status = f.close()
        if status:
            logging.warning("git diff exited with status %d" % status)

        if category:
            c['category'] = unicode(category, encoding=encoding)

        c['repository'] = unicode(rconfig['local-remote'], encoding=encoding)

        if project:
            c['project'] = unicode(project, encoding=encoding)

        if files:
            c['files'] = files
            changes.append(c)

    if rconfig['newrev'] != rconfig['baserev']:
        # Not a pure rewind
        f = os.popen("%(git)s rev-list --reverse --pretty=oneline "
                     "%(baserev)s..%(newrev)s" % rconfig, 'r')
        gen_changes(f, rconfig)

        status = f.close()
        if status:
            logging.warning("git rev-list exited with status %d" % status)


def cleanup(res):
    reactor.stop()


def create_repo(rconfig):
    # Check the repo is already created; if so, return True; if not,
    # create & return False
    created = True
    direxists = False
    try:
        os.chdir(rconfig['dir'])
    except OSError, e:
        if e.errno == 2:
            # no such file or directory
            created = False
    if created:
        # Be sure there's a get repo in the directory
        res = os.popen(
            "%(git)s config -l >/dev/null 2>&1" % rconfig, 'r').close()
        if res is not None:
            created = False
            direxists = True
    if created:
        logging.debug("git repo exists in %(dir)s" % rconfig)
        return True

    # Repo does not exist and needs to be cloned
    logging.info("no git repo in directory %(dir)s; cloning" % rconfig)
    # Create the directory; throw an exception if it can't be done
    if not direxists:
        os.makedirs(rconfig['dir'])
    # Run git clone
    f = os.popen(
        "%(git)s clone --mirror -q %(remote)s %(dir)s 2>&1" % rconfig, 'r')
    while True:
        line = f.readline()
        if line:
            logging.info(line)
        else:
            break
    res = (f.close() or 0)
    logging.info("git clone exited with status %s" % res)
    return False


def check_ancestor(rconfig):
    # Return True if ref is a descendent of ancestor
    rconfig['merge_base'] = os.popen(
        "%(git)s merge-base %(ancestor)s %(newrev)s" %
        rconfig).readline().strip()
    rconfig['merge_base_s'] = rconfig['merge_base'][:8]
    logging.debug("found merge_base %(merge_base_s)s for ref "
                  "%(newrev_s)s and ancestor %(ancestor_s)s" % rconfig)
    return rconfig['merge_base'] == rconfig['ancestor']

def process_changes(rname,rconfig):
    # Fetch changes from configured repos and process them
    logging.debug("Fetching from repo '%s'" % rname)

    # construct git command line
    rconfig['git'] = "git --git-dir %s" % rconfig['dir']
    logging.debug("base git command:  %(git)s" % rconfig)

    # If the repo has not been created, do so and return, processing
    # no changes
    if not create_repo(rconfig):
        logging.debug("base repo not created; doing nothing")
        return

    # if the only-ancestors-of param exists, get the full SHA1
    if rconfig.has_key('only-ancestors-of'):
        rconfig['ancestor'] = os.popen(
            "%(git)s rev-parse %(only-ancestors-of)s" %
                rconfig).readline().strip()
        rconfig['ancestor_s'] = rconfig['ancestor'][:8]
        logging.debug("Filtering commits with ancestor %(ancestor_s)s" %
                      rconfig)

    # run 'git fetch' and parse out any updates
    cmd = "%(git)s fetch -t --all 2>&1" % rconfig
    f = os.popen(cmd)
    logging.debug("Running '%s'" % cmd)
    # scrape each output line for changes
    while True:
        line = f.readline().strip()
        if not line:
            logging.debug("Found final empty line")
            break

        # match line against new branch regex
        m = newbranchre.match(line)
        if m:
            logging.debug("Found new branch output line:  '%s'" % line)
            # get latest revision
            rconfig['branch'] = m.group(1)
            rconfig['newrev'] = os.popen(
                "%(git)s --git-dir %(dir)s rev-parse %(branch)s" %
                rconfig).readline().strip()
            rconfig['newrev_s'] = rconfig['newrev'][:8]
            logging.debug("Revision for branch %(branch)s: %(newrev_s)s" %
                          rconfig)
            if not check_ancestor(rconfig):
                logging.debug("Pedigree failed check; skipping commit")
                continue
            gen_create_branch_changes(rconfig)
            continue

        # match line against update regex
        m = updatere.match(line)
        if m:
            logging.debug("Found new commit output line:  '%s'" % line)
            (rconfig['oldrev'], rconfig['newrev'], rconfig['branch']) = \
                m.groups()
            rconfig['oldrev_s'] = rconfig['oldrev'][:8]
            rconfig['newrev_s'] = rconfig['newrev'][:8]

            if not check_ancestor(rconfig):
                logging.debug("Pedigree failed check; skipping commit")
                continue
            gen_update_branch_changes(rconfig)
            continue

        logging.debug("Found line with no matches:  '%s'" % line)

    # run git prune origin to remove any local branches removed on
    # remote
    os.popen("%(git)s remote prune origin" % rconfig).close()

    # run git update-server-info
    os.popen("%(git)s update-server-info" % rconfig).close()

    logging.debug("Finished branch changes, pruning and updating server info")

def submit_changes():

    # Submit the changes, if any
    if not changes:
        logging.info("No changes found")
        return

    host, port = master.split(':')
    port = int(port)

    f = pb.PBClientFactory()
    d = f.login(credentials.UsernamePassword(username, auth))
    reactor.connectTCP(host, port, f)

    d.addErrback(connectFailed)
    d.addCallback(connected)
    d.addBoth(cleanup)

    reactor.run()


def parse_options():
    parser = OptionParser()
    parser.add_option("-f", "--configfile", action="store", type="string",
                      help="Config file path")
    parser.add_option("-l", "--logfile", action="store", type="string",
            help="Log to the specified file")
    parser.add_option("-v", "--verbose", action="count",
            help="Be more verbose. Ignored if -l is not specified.")
    master_help = ("Build master to push to. Default is %(master)s" % 
                   { 'master' : master })
    parser.add_option("-m", "--master", action="store", type="string",
            help=master_help)
    parser.add_option("-c", "--category", action="store",
                      type="string", help="Scheduler category to notify.")
    parser.add_option("-p", "--project", action="store",
                      type="string", help="Project to send.")
    encoding_help = ("Encoding to use when converting strings to "
                     "unicode. Default is %(encoding)s." % 
                     { "encoding" : encoding })
    parser.add_option("-e", "--encoding", action="store", type="string", 
                      help=encoding_help)
    username_help = ("Username used in PB connection auth, defaults to "
                     "%(username)s." % { "username" : username })
    parser.add_option("-u", "--username", action="store", type="string",
                      help=username_help)
    auth_help = ("Password used in PB connection auth, defaults to "
                     "%(auth)s." % { "auth" : auth })
    # 'a' instead of 'p' due to collisions with the project short option
    parser.add_option("-a", "--auth", action="store", type="string",
                      help=auth_help)
    options, args = parser.parse_args()
    return options


# Log errors and critical messages to stderr. Optionally log
# information to a file as well (we'll set that up later.)
stderr = logging.StreamHandler(sys.stderr)
fmt = logging.Formatter("git_buildbot: %(levelname)s: %(message)s")
stderr.setLevel(logging.ERROR)
stderr.setFormatter(fmt)
logging.getLogger().addHandler(stderr)
logging.getLogger().setLevel(logging.DEBUG)

try:
    options = parse_options()
    level = logging.WARNING
    if options.verbose:
        level -= 10 * options.verbose
        if level < 0:
            level = 0

    if options.logfile:
        logfile = logging.FileHandler(options.logfile)
        logfile.setLevel(level)
        fmt = logging.Formatter("%(asctime)s %(levelname)s: %(message)s")
        logfile.setFormatter(fmt)
        logging.getLogger().addHandler(logfile)

    if options.category:
        category = options.category

    if options.project:
        project = options.project

    if options.configfile:
        configfile = options.configfile
    config = readconfig(configfile)
    changesources = config['change_source']
    for (key,val) in changesources.items():
        if val.get('type',None) == 'multi-multi-git-poller':
            changesource = val
            git_repos = changesource.get('git-repos',{})

    if options.master:
        master=options.master
    else:
        masterhost = config.get('global',{}).get('master_hostname','localhost')
        slaveport = config.get('global',{}).get('slavePortnum',9989)
        master = '%s:%s' % (masterhost, slaveport)

    if options.username:
        username = options.username
    else:
        username = changesource.get(
            'user',username)

    if options.auth:
        auth = options.auth
    else:
        auth = config['auth'][username]

    logging.debug("Buildbot username: %s; passwd: %s[...]" % \
                      (username,auth[:3]))

    if options.encoding:
        encoding = options.encoding

    for (rname,rconfig) in git_repos.items():
        process_changes(rname,rconfig)

    submit_changes()

except SystemExit:
    pass
except:
    logging.exception("Unhandled exception")
    sys.exit(1)
