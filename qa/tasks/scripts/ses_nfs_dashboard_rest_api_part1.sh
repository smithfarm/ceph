set -ex

declare -a storage_minions=("$@")
roles=(ganesha mds rgw)
for i in ${!roles[@]} ; do
    echo "role-${role[i]}/cluster/${storage_minions[i]}" >> /srv/pillar/ceph/proposals/policy.cfg
done

