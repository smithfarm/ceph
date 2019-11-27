set -ex

declare -a storage_minions=("$@")

random_minion2_fqdn=${storage_minions[1]}

sed -i "s/^#role-rgw\/cluster\/$random_minion2_fqdn/role-rgw\/cluster\/$random_minion2_fqdn/g" /srv/pillar/ceph/proposals/policy.cfg
