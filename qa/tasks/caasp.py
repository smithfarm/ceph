'''
Task that deploys a CAASP cluster on all the nodes
Linter:
    flake8 --max-line-length=100
'''
import logging
import os
from util import remote_exec
from teuthology.exceptions import ConfigError
from teuthology.misc import (
    delete_file,
    move_file,
    sh,
    sudo_write_file,
    write_file,
    copy_file
    )
from teuthology.orchestra import run
from teuthology.task import Task
from util import (
    get_remote_for_role,
    remote_exec
    )
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
        self.ctx['roles'] = self.ctx.config['roles']
        self.log = log
        self.remotes = self.cluster.remotes
        self.mgmt_remote = get_remote_for_role(self.ctx, "skuba_mgmt_host.0")

    def __copy_key_to_mgmt(self):
        '''
        Copy key from teuthology server to the mgmt one
        '''
        os.system(
            'scp "%s" "%s:%s"' %
            ('/home/ubuntu/.ssh/id_rsa',
             self.mgmt_remote,
             '/home/ubuntu/.ssh/id_rsa'))

    def __enable_ssh_agent(self):
        self.mgmt_remote.sh("eval `ssh-agent` && ssh-add ~/.ssh/id_rsa")

    def with_agent(self, command):
        set_agent = "eval `ssh-agent` && ssh-add ~/.ssh/id_rsa && "
        self.mgmt.remote.sh("%s %s" % (set_agent, command))

    def __create_cluster(self):
        master_remote = get_remote_for_role(self.ctx, "caasp_master.0")
        commands = [
            "skuba cluster init --control-plane {} cluster".format(master_remote.hostname),
            "cd cluster && skuba node bootstrap --user ubuntu --sudo --target {} my-master".format(
                master_remote.hostname),
        ]
        for command in commands:
            self.with_agent(self, command)
        for i in range(4):
            worker_remote = get_remote_for_role(
                self.ctx, "caasp_worker." + str(i))
            self.mgmt_remote.sh(
                "cd cluster;skuba node join --role worker --user ubuntu --sudo --target {} worker.{}".format(
                    worker_remote.hostname, str(i)))

    def begin(self):
        self.log.info('Installing Caasp on mgmt host')
        self.__copy_key_to_mgmt()
        self.__enable_ssh_agent()
        self.__create_cluster()

    def end(self):
        pass

    def teardown(self):
        pass


task = Caasp
