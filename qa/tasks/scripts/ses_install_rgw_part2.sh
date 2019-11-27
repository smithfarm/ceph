set -ex

declare -a storage_minions=("$@")

random_minion_fqdn=${storage_minions[0]}
random_minion=${random_minion_fqdn%.*}

random_minion2_fqdn=${storage_minions[1]}
random_minion2=${random_minion2_fqdn%.*}

salt $random_minion_fqdn service.status ceph-radosgw@rgw.${random_minion}.service 2>/dev/null
salt $random_minion2_fqdn service.status ceph-radosgw@rgw.${random_minion2}.service 2>/dev/null
salt $random_minion_fqdn service.restart ceph-radosgw@rgw.${random_minion}.service 2>/dev/null
salt $random_minion2_fqdn service.restart ceph-radosgw@rgw.${random_minion2}.service 2>/dev/null

salt $random_minion_fqdn service.status ceph-radosgw@rgw.${random_minion}.service | grep -i true 2>/dev/null
salt $random_minion2_fqdn service.status ceph-radosgw@rgw.${random_minion2}.service | grep -i true 2>/dev/null

sed -i "s/^role-rgw\/cluster\/$random_minion2_fqdn/#role-rgw\/cluster\/$random_minion2_fqdn/g" /srv/pillar/ceph/proposals/policy.cfg
