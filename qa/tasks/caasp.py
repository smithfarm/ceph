'''
Task that deploys a CAASP cluster on all the nodes

Linter:
    flake8 --max-line-length=100
'''
import logging

from util import remote_exec
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


class caasp(Task):
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
        super(Salt, self).__init__(ctx, config)
        log.debug("beginning of constructor method")
        log.debug("munged config is {}".format(self.config))
        self.remotes = self.cluster.remotes
        self.sm = SaltManager(self.ctx)
        self.master_remote = self.sm.master_remote
        log.debug("end of constructor method")

task = caasp
