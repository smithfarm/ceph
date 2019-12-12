'''
Task that deploys a CAASP cluster on all the nodes

Linter:
    flake8 --max-line-length=100
'''
import logging

from util import (
#    copy_directory_recursively,
#    enumerate_osds,
    get_remote_for_role,
#    get_rpm_pkg_version,
#    introspect_roles,
#    remote_exec,
#    remote_run_script_as_root,
#    sudo_append_to_file,
    )
from teuthology.exceptions import ConfigError
from teuthology.misc import (
    delete_file,
    move_file,
    sh,
    sudo_write_file,
    write_file,
    )
from teuthology.orchestra import run
from teuthology.task import Task

log = logging.getLogger(__name__)


class Caasp(Task):
    """
    Deploy a Salt cluster on all remotes (test nodes).

    This task assumes all relevant Salt packages (salt, salt-master,
    salt-minion, salt-api, python-salt, etc. - whatever they may be called for
    the OS in question) are already installed. This should be done using the
    install task.

    One, and only one, of the machines must have a role corresponding to the
    value of the variable salt.sm.master_role (see salt_manager.py). This node
    is referred to as the "Salt Master", or the "master node".

    The task starts the Salt Master daemon on the master node, and Salt Minion
    daemons on all the nodes (including the master node), and ensures that the
    minions are properly linked to the master. Finally, it tries to ping all
    the minions from the Salt Master.

    :param ctx: the argparse.Namespace object
    :param config: the config dict
    """

    def __init__(self, ctx, config):
        super(Caasp, self).__init__(ctx, config)
        log.debug("beginning of constructor method")
        log.debug("munged config is {}".format(self.config))
        self.remotes = self.cluster.remotes
        self.master_remote = self.sm.master_remote
        log.debug("end of constructor method")

    def begin(self):
        self.log.info('Installing Caasp on mgmt host')
        self.deploy_ssh_keys()

    def deploy_ssh_keys(self):
        self.mgmt = get_remote_for_role(self.ctx, skuba_mgmt_host)
        self.mgmt.run(args=[
            'ssh-keygen',
            '-b',
            '2048',
            '-t',
            'rsa',
            '-f',
            '/tmp/sshkey',
            '-N',
            '""'
        ])

    def end(self):
        pass

    def teardown(self):
        pass


task = Caasp
