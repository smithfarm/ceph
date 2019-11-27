set -ex

declare -a storage_minions=("$@")

minion_fqdn=${storage_minions[0]}
minion=${minion_fqdn%.*}
random_osd=$(ceph osd tree | grep -A 1 $minion | grep -o osd.* | awk '{print$1}')

salt $minion_fqdn service.stop ceph-osd@${random_osd#*.}

sleep 5

until [ "$(ceph health)" == "HEALTH_OK" ]
do
    let n+=30
    sleep 30
    echo "waiting till health is OK."
done

echo "Total waiting time ${n}s."
unset n

minion2_fqdn=${storage_minions[1]}
minion2=${minion2_fqdn%.*}
random_osd2=$(ceph osd tree | grep -A 1 $minion2 | grep -o osd.* | awk '{print$1}')
 
salt $minion2_fqdn service.stop ceph-osd@${random_osd2#*.}

sleep 5

until [ "$(ceph health)" == "HEALTH_OK" ]
do
    let n+=30
    sleep 30
    echo "waiting till health is OK."
done

echo "Total waiting time ${n}s."
unset n


salt $minion_fqdn service.start ceph-osd@${random_osd#*.}
salt $minion2_fqdn service.start ceph-osd@${random_osd2#*.}

ceph osd pool rm stoposddeamon stoposddeamon --yes-i-really-really-mean-it

