set -ex

declare -a storage_minions=("$@")

echo "### Getting random minion to install RGW on ###"
random_minion_fqdn=${storage_minions[0]}
random_minion=`echo $random_minion_fqdn | cut -d . -f 1`

echo "### Getting second random minion to install RGW on ###"
random_minion2_fqdn=${storage_minions[1]}
random_minion2=`echo $random_minion2_fqdn | cut -d . -f 1`

salt $random_minion_fqdn cmd.run "systemctl status ceph-radosgw@us-east-1.\`hostname\`.service"
salt $random_minion2_fqdn cmd.run "systemctl status ceph-radosgw@us-east-2.\`hostname\`.service"

ceph health | grep HEALTH_OK

echo "### Removing RGW ###"
sed -i "s/^role-us-east/#role-us-east/g" /srv/pillar/ceph/proposals/policy.cfg
