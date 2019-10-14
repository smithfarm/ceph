set -ex

# calculating PG and PGP number
num_of_osd=`sudo su -c "ceph osd ls | wc -l"`

k=4
m=2

num_of_existing_pools=`sudo su -c "ceph osd pool ls | wc -l"`
num_of_pools=1

power2() { echo "x=l($1)/l(2); scale=0; 2^((x+0.5)/1)" | bc -l; }
size=`sudo su -c "ceph-conf -c /dev/null -D" | grep "osd_pool_default_size" | cut -d = -f 2 | sed 's/\ //g'`
osd_num=`sudo su -c "ceph osd ls | wc -l"`
recommended_pg_per_osd=100
pg_num=$(power2 `echo "(($osd_num*$recommended_pg_per_osd) / $size) / ($num_of_existing_pools + $num_of_pools)" | bc`)
pgp_num=$pg_num


pg_size_total=$(($pg_num*($k+$m)))
until [ $pg_size_total -lt $((200*$num_of_osd)) ]
do
 pg_num=$(($pg_num/2))
 pgp_num=$pg_num
 pg_size_total=$(($pg_num*($k+$m)))
done

prepare_rbd () {
sudo su -c "ceph osd pool create $1 $pg_num $pgp_num"
sudo su -c "ceph osd pool application enable $1 rbd"
sudo su -c "rbd -p $1 create image1 --size 2G"
rbd_device=`sudo su -c "rbd map $1/image1"`
sudo su -c "parted -s $rbd_device mklabel gpt unit % mkpart 1 xfs 0 100"
sudo su -c "mkfs.xfs ${rbd_device}p1"
sudo su -c "mount ${rbd_device}p1 /mnt"
}

nettest () {
echo "sudo su -c 'time dd if=/dev/zero  of=/mnt/file1.bin count=100 bs=1M oflag=direct >/dev/null 2>&1'"
set +x
time_consumed+="$1 - `(sudo su -c "time dd if=/dev/zero  of=/mnt/file1.bin count=100 bs=1M oflag=direct >/dev/null 2>&1") 2>&1 | sed '/^$/d' | head -1`; "
set -x
sudo su -c "ls -l /mnt/file1.bin"
sudo su -c "rm -f /mnt/file1.bin"
sudo su -c "umount /mnt"
sudo su -c "rbdmap unmap-all > /dev/null 2>&1 || true"
sudo su -c "ceph osd pool rm $1 $1 --yes-i-really-really-mean-it"
}

create_netem_rules () {

case $3 in 
'') ooo="`echo -e $2`" ;;
*) ooo="`echo -e \"$2\" | tail -$3`" ;;
esac

for minion in $ooo
do
        public_interface=`sudo su -c "salt $minion cmd.run \"ip -o -4 address | grep $public_octet_ip\" | awk '{print \\$2}' | sed '/^$/d'"` 
        cluster_interface=`sudo su -c "salt $minion cmd.run \"ip -o -4 address | grep $cluster_octet_ip\" | awk '{print \\$2}' | sed '/^$/d'"`

        public_interface_list+=($public_interface)
        cluster_interface_list+=($cluster_interface)

        minion_list+=($minion)

       	case $1 in 
		delay|delay_all) sudo su -c "salt $minion cmd.run \"tc qdisc add dev $cluster_interface root netem delay 100ms 10ms distribution normal\""
		       	if [ "$public_interface" != "$cluster_interface" ]
		       	then
			       	sudo su -c "salt $minion  cmd.run \"tc qdisc add dev $public_interface root netem delay 100ms 10ms distribution normal\""
		       	fi
		       	;;
	       	packet_loss|packet_loss_all) sudo su -c "salt $minion cmd.run \"tc qdisc add dev $cluster_interface root netem loss 0.3% 25%\""
		       	if [ "$public_interface" != "$cluster_interface" ]
		       	then
			       	sudo su -c "salt $minion cmd.run \"tc qdisc add dev $public_interface root netem loss 0.3% 25%\""
		       	fi
		       	;;
	       	packet_dup|packet_dup_all) sudo su -c "salt $minion cmd.run \"tc qdisc add dev $cluster_interface root netem duplicate 1%\""
		       	if [ "$public_interface" != "$cluster_interface" ]
		       	then
			       	sudo su -c "salt $minion cmd.run \"tc qdisc add dev $public_interface root netem duplicate 1%\""
		       	fi
		       	;;
	       	packet_corruption|packet_corruption_all) sudo su -c "salt $minion cmd.run \"tc qdisc add dev $cluster_interface root netem corrupt 0.1%\""
		       	if [ "$public_interface" != "$cluster_interface" ]
		       	then
			       	sudo su -c "salt $minion cmd.run \"tc qdisc add dev $public_interface root netem corrupt 0.1%\""
		       	fi
		       	;;
	       	packet_reordering|packet_reordering_all) sudo su -c "salt $minion cmd.run \"tc qdisc add dev $cluster_interface root netem delay 10ms reorder 25% 50%\""
		       	if [ "$public_interface" != "$cluster_interface" ]
			then
			       	sudo su -c "salt $minion cmd.run \"tc qdisc add dev $public_interface root netem delay 10ms reorder 25% 50%\""
		       	fi
		       	;;
       	esac

done
}

remove_netem_rules () {
case $1 in 
	delay_all|packet_loss_all|packet_dup_all|packet_corruption_all|packet_reordering_all) simulated_minions=`echo -e "$2" | wc -l`
		   ;;
	*) simulated_minions=$2
		   ;;
esac

for rmqdisc in `seq 0 $(($simulated_minions-1))`
do

        if [ ! -z ${cluster_interface_list[$rmqdisc]} ] && [ "${cluster_interface_list[$rmqdisc]}" != "${public_interface_list[$rmqdisc]}" ]
        then
               sudo su -c "salt ${minion_list[$rmqdisc]} cmd.run \"tc qdisc del dev ${cluster_interface_list[$rmqdisc]} root netem || true\""
        fi

        sudo su -c "salt ${minion_list[$rmqdisc]} cmd.run \"tc qdisc del dev ${public_interface_list[$rmqdisc]} root netem || true\""

done

unset cluster_interface_list public_interface_list minion_list
}

net_storage_minions=`sudo su -c "salt-run select.minions roles=storage" | awk '{print $2}'`
net_monitor_minions=`sudo su -c "salt-run select.minions roles=mon" | awk '{print $2}'`

net_storage_minions_count=`echo "$net_storage_minions" | wc -l`
net_monitor_minions_count=`echo "$net_monitor_minions" | wc -l`
 
# simulate network failure on half of storage / monitor minions
net_storage_minions_simulate=$(($net_storage_minions_count / 2))
net_monitor_minions_simulate=$(($net_monitor_minions_count / 2))

# get public and cluster network
public_network=`sudo su -c "ceph-conf -D" | grep -w public_network | cut -d = -f 2 | cut -d / -f 1`
cluster_network=`sudo su -c "ceph-conf -D" | grep -w cluster_network | cut -d = -f 2 | cut -d / -f 1`

# get first three octets of public and cluster IP
public_octet_ip=`echo $public_network | cut -d . -f 1-3`
cluster_octet_ip=`echo $cluster_network | cut -d . -f 1-3`

# healthy network test
prepare_rbd "network_healthy"
nettest "network_healthy"

# PACKET DELAY
# delay on half of osd nodes
prepare_rbd "network_delay_osd_node"
create_netem_rules "delay" "$net_storage_minions" "$net_storage_minions_simulate"
nettest "network_delay_osd_node"
remove_netem_rules "delay" "$net_storage_minions_simulate"

# delay on half of monitors
prepare_rbd "network_delay_monitor_nodes"
create_netem_rules "delay" "$net_monitor_minions" "$net_monitor_minions_simulate"
nettest "network_delay_monitor_nodes"
remove_netem_rules "delay" "$net_monitor_minions_simulate"

# delay on all osd nodes
prepare_rbd "network_delay_all_osd_nodes"
create_netem_rules "delay_all" "$net_storage_minions" ""
nettest "network_delay_all_osd_nodes"
remove_netem_rules "delay_all" "$net_storage_minions" 

# delay on all monitors
prepare_rbd "network_delay_all_monitor_nodes"
create_netem_rules "delay_all" "$net_monitor_minions" ""
nettest "network_delay_all_monitor_nodes"
remove_netem_rules "delay_all" "$net_monitor_minions"

# delay on all monitors and osd nodes
prepare_rbd "network_delay_on_all_monitors_and_all_osdnodes"
create_netem_rules "delay_all" "$net_storage_minions \n $net_monitor_minions" ""
nettest "network_delay_on_all_monitors_and_all_osdnodes"
remove_netem_rules "delay_all" "$net_storage_minions \n $net_monitor_minions"

# PACKET LOSS
# packet loss on half of osd nodes
prepare_rbd "network_packet_loss_osd_node"
create_netem_rules "packet_loss" "$net_storage_minions" "$net_storage_minions_simulate"
nettest "network_packet_loss_osd_node"
remove_netem_rules "packet_loss" "$net_storage_minions_simulate"

# packet loss on half of monitors
prepare_rbd "network_packet_loss_monitor_node"
create_netem_rules "packet_loss" "$net_monitor_minions" "$net_monitor_minions_simulate"
nettest "network_packet_loss_monitor_node"
remove_netem_rules "packet_loss" "$net_monitor_minions_simulate"

# packet loss on all osd nodes
prepare_rbd "network_packet_loss_all_osd_nodes"
create_netem_rules "packet_loss_all" "$net_storage_minions"
nettest "network_packet_loss_all_osd_nodes"
remove_netem_rules "packet_loss_all" "$net_storage_minions"

# packet loss on all monitors
prepare_rbd "network_packet_loss_all_monitors"
create_netem_rules "packet_loss_all" "$net_monitor_minions"
nettest "network_packet_loss_all_monitors"
remove_netem_rules "packet_loss_all" "$net_monitor_minions"

# packet loss on all monitors and osd nodes
prepare_rbd "network_packet_loss_on_all_monitors_and_all_osdnodes"
create_netem_rules "packet_loss_all" "$net_storage_minions\n$net_monitor_minions"
nettest "network_packet_loss_on_all_monitors_and_all_osdnodes"
remove_netem_rules "packet_loss_all" "$net_storage_minions\n$net_monitor_minions"

# PACKET DUPLICATION
# packet duplication on half of osd nodes
prepare_rbd "network_packet_dup_osd_node"
create_netem_rules "packet_dup" "$net_storage_minions" "$net_storage_minions_simulate"
nettest "network_packet_dup_osd_node"
remove_netem_rules "packet_dup" "$net_storage_minions_simulate"

# packet duplication on half of monitors
prepare_rbd "network_packet_dup_monitor_node"
create_netem_rules "packet_dup" "$net_monitor_minions" "$net_monitor_minions_simulate"
nettest "network_packet_dup_monitor_node"
remove_netem_rules "packet_dup" "$net_monitor_minions_simulate"

# packet duplication on all osd nodes
prepare_rbd "network_packet_dup_all_osd_nodes"
create_netem_rules "packet_dup_all" "$net_storage_minions"
nettest "network_packet_dup_all_osd_nodes"
remove_netem_rules "packet_dup_all" "$net_storage_minions"

# packet duplication on all monitors
prepare_rbd "network_packet_dup_all_monitors"
create_netem_rules "packet_dup_all" "$net_monitor_minions"
nettest "network_packet_dup_all_monitors"
remove_netem_rules "packet_dup_all" "$net_monitor_minions"

# packet duplication on all monitors and osd nodes
prepare_rbd "network_packet_dup_on_all_monitors_and_all_osdnodes"
create_netem_rules "packet_dup_all" "$net_storage_minions\n$net_monitor_minions" ""
nettest "network_packet_dup_on_all_monitors_and_all_osdnodes"
remove_netem_rules "packet_dup_all" "$net_storage_minions\n$net_monitor_minions"

# PACKET CORRUPTION
# packet corruption on half of osd nodes
prepare_rbd "network_packet_corruption_osd_node"
create_netem_rules "packet_corruption" "$net_storage_minions" "$net_storage_minions_simulate"
nettest "network_packet_corruption_osd_node"
remove_netem_rules "packet_corruption" "$net_storage_minions_simulate"

# packet corruption on half of monitors
prepare_rbd "network_packet_corruption_monitor_node"
create_netem_rules "packet_corruption" "$net_monitor_minions" "$net_monitor_minions_simulate"
nettest "network_packet_corruption_monitor_node"
remove_netem_rules "packet_corruption" "$net_monitor_minions_simulate"

# packet corruption on all osd nodes
prepare_rbd "network_packet_corruption_all_osd_nodes"
create_netem_rules "packet_corruption_all" "$net_storage_minions"
nettest "network_packet_corruption_all_osd_nodes"
remove_netem_rules "packet_corruption_all" "$net_storage_minions"

# packet corruption on all monitors
prepare_rbd "network_packet_corruption_all_monitors"
create_netem_rules "packet_corruption_all" "$net_monitor_minions"
nettest "network_packet_corruption_all_monitors"
remove_netem_rules "packet_corruption_all" "$net_monitor_minions"

# packet corruption on all monitors and osd nodes
prepare_rbd "network_packet_corruption_on_all_monitors_and_all_osdnodes"
create_netem_rules "packet_corruption_all" "$net_storage_minions\n$net_monitor_minions" ""
nettest "network_packet_corruption_on_all_monitors_and_all_osdnodes"
remove_netem_rules "packet_corruption_all" "$net_storage_minions\n$net_monitor_minions"

# PACKET REORDERING
# packet reordering on half of osd nodes
prepare_rbd "network_packet_reordering_osd_node"
create_netem_rules "packet_reordering" "$net_storage_minions" "$net_storage_minions_simulate"
nettest "network_packet_reordering_osd_node"
remove_netem_rules "packet_reordering" "$net_storage_minions_simulate"

# packet reordering on half of monitors
prepare_rbd "network_packet_reordering_monitor_node"
create_netem_rules "packet_reordering" "$net_monitor_minions" "$net_monitor_minions_simulate"
nettest "network_packet_reordering_monitor_node"
remove_netem_rules "packet_reordering" "$net_monitor_minions_simulate"

# packet reordering on all osd nodes
prepare_rbd "network_packet_reordering_all_osd_nodes"
create_netem_rules "packet_reordering_all" "$net_storage_minions"
nettest "network_packet_reordering_all_osd_nodes"
remove_netem_rules "packet_reordering_all" "$net_storage_minions"

# packet reordering on all monitors
prepare_rbd "network_packet_reordering_all_monitors"
create_netem_rules "packet_reordering_all" "$net_monitor_minions"
nettest "network_packet_reordering_all_monitors"
remove_netem_rules "packet_reordering_all" "$net_monitor_minions"

# packet reordering on all monitors and osd nodes
prepare_rbd "network_packet_reordering_on_all_monitors_and_all_osdnodes"
create_netem_rules "packet_reordering_all" "$net_storage_minions\n$net_monitor_minions" ""
nettest "network_packet_reordering_on_all_monitors_and_all_osdnodes"
remove_netem_rules "packet_reordering_all" "$net_storage_minions\n$net_monitor_minions"

# print results
echo " *** RESULTS: "
echo $time_consumed | tr ';' '\n'
