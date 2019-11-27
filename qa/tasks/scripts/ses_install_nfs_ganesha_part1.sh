set -ex

declare -a storage_minions=("$@")

random_minion=${storage_minions[0]}

echo "role-ganesha/cluster/${random_minion}.sls" >> /srv/pillar/ceph/proposals/policy.cfg

random_minion2=${storage_minions[1]}

if [ -z "$(salt-run select.minions roles=mds)" ]
then
    echo "role-mds/cluster/${random_minion2}.sls" >> /srv/pillar/ceph/proposals/policy.cfg
fi

echo "role-ganesha/cluster/${random_minion2}.sls" >> /srv/pillar/ceph/proposals/policy.cfg
