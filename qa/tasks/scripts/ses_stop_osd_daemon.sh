set -ex

declare -a storage_minions=("$@")

random_minion_fqdn=${storage_minions[0]}
random_minion=`echo $random_minion_fqdn | cut -d . -f 1`
random_osd=`ceph osd tree | grep -A 1 $random_minion | grep -o osd.* | awk '{print$1}'`

salt $random_minion_fqdn service.stop ceph-osd@`echo $random_osd | cut -d . -f 2`

sleep 5


until [ "`ceph health`" == "HEALTH_OK" ]
do
 let n+=30
 sleep 30
 echo "waiting till health is OK."
done
 echo "Total waiting time ${n}s."
unset n

random_minion2_fqdn=${storage_minions[1]}

random_minion2=`echo $random_minion2_fqdn | cut -d . -f 1`
random_osd2=`ceph osd tree | grep -A 1 $random_minion2 | grep -o osd.* | awk '{print$1}'`
 
salt $random_minion2_fqdn service.stop ceph-osd@`echo $random_osd2 | cut -d . -f 2`

sleep 5

until [ "`ceph health`" == "HEALTH_OK" ]
do
 let n+=30
 sleep 30
 echo "waiting till health is OK."
done
 echo "Total waiting time ${n}s."
unset n


salt $random_minion_fqdn service.start ceph-osd@`echo $random_osd | cut -d . -f 2`
salt $random_minion2_fqdn service.start ceph-osd@`echo $random_osd2 | cut -d . -f 2`

ceph osd pool rm stoposddeamon stoposddeamon --yes-i-really-really-mean-it

