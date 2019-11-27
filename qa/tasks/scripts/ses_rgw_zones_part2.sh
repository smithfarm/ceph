set -ex

minion_fqdn=$1
minion2_fqdn=$2

salt $minion_fqdn cmd.run "systemctl status ceph-radosgw@us-east-1.\$(hostname).service"
salt $minion2_fqdn cmd.run "systemctl status ceph-radosgw@us-east-2.\$(hostname).service"

ceph health | grep HEALTH_OK

echo "### Removing RGW ###"
sed -i "s/^role-us-east/#role-us-east/g" /srv/pillar/ceph/proposals/policy.cfg
