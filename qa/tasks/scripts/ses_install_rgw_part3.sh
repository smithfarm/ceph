set -ex

declare -a storage_minions=("$@")

random_minion2_fqdn=${storage_minions[1]}
random_minion2=`echo $random_minion2_fqdn | cut -d . -f 1`

sed -i "s/^#role-rgw\/cluster\/$random_minion2_fqdn/role-rgw\/cluster\/$random_minion2_fqdn/g" /srv/pillar/ceph/proposals/policy.cfg
