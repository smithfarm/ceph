set -ex

declare -a storage_minions=("$@")

rgw_sls="
rgw_configurations:
  rgw:
    users:
      - { uid: "admin", name: "admin", email: "demo@demo.nil", system: True }
"

echo "$rgw_sls" | sed '/^$/d' >> /srv/pillar/ceph/rgw.sls

random_minion_fqdn=${storage_minions[0]}
random_minion=$(echo $random_minion_fqdn | cut -d . -f 1)

echo "role-rgw/cluster/${random_minion_fqdn}.sls" >> /srv/pillar/ceph/proposals/policy.cfg

random_minion2_fqdn=${storage_minions[1]}

random_minoin2=${random_minion2_fqdn%.*}

echo "role-rgw/cluster/${random_minion2_fqdn}.sls" >> /srv/pillar/ceph/proposals/policy.cfg
