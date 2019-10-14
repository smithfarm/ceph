set -ex

declare -a random_minion_fqdn="$@"

wait_for_server () {
 sleep 20
 while ! nc -zv $1 22 
 do
  sleep 20
 done
}

random_minion=`echo $random_minion_fqdn | cut -d . -f 1`
random_osd=`ceph osd tree | grep -A 1 $random_minion | grep -o "osd\.".* | awk '{print$1}'`

ceph osd out $random_osd
ceph osd tree
ceph osd in $random_osd
salt $random_minion_fqdn service.stop ceph-osd@`echo $random_osd | cut -d . -f 2` 2>/dev/null
ceph osd crush remove $random_osd
ceph auth del $random_osd
ceph osd down $random_osd
ceph osd rm $random_osd
ceph osd tree
sleep 3
osd_systemdisk=$(salt $random_minion_fqdn cmd.run "find /var/lib/ceph/osd/ceph-$(echo $random_osd | cut -d . -f 2) -type l -exec readlink {} \; | cut -d / -f 3 | while read line; do pvdisplay | grep -B 1 \$line | head -1 | awk '{print \$3}'; done" | tail -1 | sed 's/\ //g')

salt $random_minion_fqdn cmd.run "sgdisk -Z $osd_systemdisk" 2>/dev/null

salt $random_minion_fqdn cmd.run "sgdisk -o -g $osd_systemdisk" 2>/dev/null

salt $random_minion_fqdn system.reboot || true

wait_for_server $random_minion_fqdn

ceph health | grep HEALTH_OK
