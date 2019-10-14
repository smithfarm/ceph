set -ex

declare -a random_minion_fqdn="$@"

echo "### Getting random minion and its random OSD ###"
random_minion=`echo $random_minion_fqdn | cut -d . -f 1`
random_osd=`ceph osd tree | grep -A 1 $random_minion | grep -o "osd\.".* | awk '{print$1}'`
osd_id=`echo $random_osd | cut -d . -f 2`

ceph health | grep HEALTH_OK

ceph osd tree | grep $osd_id

ceph osd pool rm replacedisk replacedisk --yes-i-really-really-mean-it

