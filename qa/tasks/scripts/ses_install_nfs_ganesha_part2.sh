set -ex

declare -a storage_minions=("$@")

random_minion=${storage_minions[0]}

random_minion2=${storage_minions[1]}

salt $random_minion service.status nfs-ganesha.service 2>/dev/null
salt $random_minion2 service.status nfs-ganesha.service 2>/dev/null
salt $random_minion service.restart nfs-ganesha.service 2>/dev/null
salt $random_minion2 service.restart nfs-ganesha.service 2>/dev/null

sleep 15

salt $random_minion service.status nfs-ganesha.service | grep -i true 2>/dev/null

salt $random_minion2 service.status nfs-ganesha.service | grep -i true 2>/dev/null


sed -i "s/^role-ganesha\/cluster\/$random_minion2/#role-ganesha\/cluster\/$random_minion2/g" /srv/pillar/ceph/proposals/policy.cfg
