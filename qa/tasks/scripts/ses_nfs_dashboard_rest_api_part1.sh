set -ex

# deploy services if they aren't already
declare -a storage_minions=("$@")
echo "role-ganesha/cluster/${storage_minions[0]}" >> /srv/pillar/ceph/proposals/policy.cfg

echo "role-mds/cluster/${storage_minions[1]}" >> /srv/pillar/ceph/proposals/policy.cfg

echo "role-rgw/cluster/${storage_minions[2]}" >> /srv/pillar/ceph/proposals/policy.cfg

