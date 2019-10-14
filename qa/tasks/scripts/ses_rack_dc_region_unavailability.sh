set -ex

master=( `sudo salt-run select.minions roles=master 2>/dev/null | awk '{print $2}'` )
storage_minions=( `sudo salt-run select.minions roles=storage 2>/dev/null | awk '{print $2}'` )
monitor_minions=( `sudo salt-run select.minions roles=mon 2>/dev/null | awk '{print $2}'` )
minions_num=$((${#storage_minions[@]}+${#monitor_minions[@]}))

# split nodes
split_nodes(){

first_part=$(($1 / 2))
second_part=$(($1 - $first_part))

}

# wait for cluster health OK
cluster_health(){
until [ "`sudo ceph health`" == HEALTH_OK ]
do
 sleep 30
done
}

# calculating PG and PGP number
num_of_osd=`sudo ceph osd ls | wc -l`

k=4
m=2

num_of_existing_pools=`sudo ceph osd pool ls | wc -l`
num_of_pools=1

power2() { echo "x=l($1)/l(2); scale=0; 2^((x+0.5)/1)" | bc -l; }
size=`sudo ceph-conf -c /dev/null -D | grep "osd_pool_default_size" | cut -d = -f 2 | sed 's/\ //g'`
osd_num=`sudo ceph osd ls | wc -l`
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


crushmap_file=crushmap
sudo su -c "ceph osd getcrushmap -o ${crushmap_file}.bin"
sudo su -c "crushtool -d ${crushmap_file}.bin -o ${crushmap_file}.txt"

hosts=(`grep ^host ${crushmap_file}.txt | awk '{print $2}' | sort -u`)
root_name=`grep ^root ${crushmap_file}.txt | awk '{print $2}'`

# exit 1 if storage nodes are less then 4
if [ ${#hosts[@]} -lt 4 ]
then
	echo "Too less nodes with storage role. Minimum is 4."
	exit 1
fi

### rack failure
sudo su -c "ceph osd crush add-bucket rack1 rack"
sudo su -c "ceph osd crush add-bucket rack2 rack"
sudo su -c "ceph osd crush add-bucket rack3 rack"
sudo su -c "ceph osd crush add-bucket rack4 rack"

sudo su -c "ceph osd crush move rack1 root=$root_name"
sudo su -c "ceph osd crush move rack2 root=$root_name"
sudo su -c "ceph osd crush move rack3 root=$root_name"
sudo su -c "ceph osd crush move rack4 root=$root_name"

### region 1
split_nodes ${#hosts[@]}

# nodes for region1
for region1 in `seq 0 $(($first_part - 1))`
do
 region1_hosts+=(${hosts[$region1]})
done

# split region1 nodes to racks
split_nodes ${#region1_hosts[@]}

# nodes for rack1 in region1
for rack1 in `seq 0 $(($first_part - 1))`
do
 rack1_hosts+=(${region1_hosts[$rack1]})
done

# nodes for rack2 in region1
for rack2 in `seq 1 $second_part`
do
 rack2_hosts+=(${region1_hosts[-$rack2]})
done

# move nodes in crush map to rack1 (region1)
for osd_node in ${rack1_hosts[@]}
do
 sudo su -c "ceph osd crush move $osd_node rack=rack1"
done
 
# move nodes in crush map to rack2 (region1)
for osd_node in ${rack2_hosts[@]}
do
 sudo su -c "ceph osd crush move $osd_node rack=rack2"
done
 


# region2
split_nodes ${#hosts[@]}

# nodes for region2
for region2 in `seq 1 $second_part`
do
 region2_hosts+=(${hosts[-$region2]})
done

# split region2 nodes to racks
split_nodes ${#region2_hosts[@]}

# nodes for rack3 in region2
for rack3 in `seq 0 $(($first_part - 1))`
do
 rack3_hosts+=(${region2_hosts[$rack3]})
done

# nodes for rack4 in region2
for rack4 in `seq 1 $second_part`
do
 rack4_hosts+=(${region2_hosts[-$rack4]})
done

for osd_node in ${rack3_hosts[@]}
do
 sudo su -c "ceph osd crush move $osd_node rack=rack3"
done
 
for osd_node in ${rack4_hosts[@]}
do
 sudo su -c "ceph osd crush move $osd_node rack=rack4"
done
 
# creates pool
sudo su -c "ceph osd pool create crushmap $pg_num $pgp_num"
while [ $(sudo su -c "ceph -s | grep creating -c") -gt 0 ]; do echo -n .;sleep 1; done

# bring down rack
for node2fail in ${rack4_hosts[@]}
do
  sudo su -c "salt ${node2fail}.teuthology cmd.run \"iptables -I OUTPUT -d localhost -j ACCEPT\""
  sudo su -c "salt ${node2fail}.teuthology cmd.run \"iptables -I OUTPUT -d $master -j ACCEPT\""
  sudo su -c "salt ${node2fail}.teuthology cmd.run \"iptables -I INPUT -s localhost -j ACCEPT\""
  sudo su -c "salt ${node2fail}.teuthology cmd.run \"iptables -I INPUT -s $master -j ACCEPT\""
  sudo su -c "salt ${node2fail}.teuthology cmd.run \"iptables -P INPUT DROP\""
  sudo su -c "salt ${node2fail}.teuthology cmd.run \"iptables -P OUTPUT DROP\""
done

until sudo su -c "ceph -s | grep \".* rack.* down\""
do
 sleep 30
done 

sudo ceph -s

sudo su -c "ceph osd tree"

# bring rack up
for node2fail in ${rack4_hosts[@]}
do
  sudo su -c "salt ${node2fail}.teuthology cmd.run \"iptables -P INPUT ACCEPT\""
  sudo su -c "salt ${node2fail}.teuthology cmd.run \"iptables -P OUTPUT ACCEPT\""
  sudo su -c "salt ${node2fail}.teuthology cmd.run \"iptables -F\""
done

cluster_health

### DC failure
sudo su -c "ceph osd crush add-bucket dc1 datacenter"
sudo su -c "ceph osd crush add-bucket dc2 datacenter"
sudo su -c "ceph osd crush move dc1 root=$root_name"
sudo su -c "ceph osd crush move dc2 root=$root_name"
sudo su -c "ceph osd crush move rack1 datacenter=dc1"
sudo su -c "ceph osd crush move rack2 datacenter=dc1"
sudo su -c "ceph osd crush move rack3 datacenter=dc2"
sudo su -c "ceph osd crush move rack4 datacenter=dc2"

dc1_nodes=(${rack1_hosts[@]} ${rack2_hosts[@]})
dc2_nodes=(${rack3_hosts[@]} ${rack4_hosts[@]})

# bringing down DC
for node2fail in ${dc1_nodes[@]}
do
  sudo su -c "salt ${node2fail}.teuthology cmd.run \"iptables -I OUTPUT -d localhost -j ACCEPT\""
  sudo su -c "salt ${node2fail}.teuthology cmd.run \"iptables -I OUTPUT -d $master -j ACCEPT\""
  sudo su -c "salt ${node2fail}.teuthology cmd.run \"iptables -I INPUT -s localhost -j ACCEPT\""
  sudo su -c "salt ${node2fail}.teuthology cmd.run \"iptables -I INPUT -s $master -j ACCEPT\""
  sudo su -c "salt ${node2fail}.teuthology cmd.run \"iptables -P INPUT DROP\""
  sudo su -c "salt ${node2fail}.teuthology cmd.run \"iptables -P OUTPUT DROP\""
done

until sudo su -c "ceph -s | grep \".* datacenter.* down\""
do 
 sleep 30
done

sudo ceph -s 

sudo su -c "ceph osd tree"

# bring DC up
for node2fail in ${dc1_nodes[@]}
do
  sudo su -c "salt ${node2fail}.teuthology cmd.run \"iptables -P INPUT ACCEPT\""
  sudo su -c "salt ${node2fail}.teuthology cmd.run \"iptables -P OUTPUT ACCEPT\""
  sudo su -c "salt ${node2fail}.teuthology cmd.run \"iptables -F\""
done

cluster_health

### region failure
sudo su -c "ceph osd crush add-bucket dc3 datacenter"
sudo su -c "ceph osd crush add-bucket dc4 datacenter"
sudo su -c "ceph osd crush add-bucket region1 region"
sudo su -c "ceph osd crush add-bucket region2 region"
sudo su -c "ceph osd crush move region1 root=$root_name"
sudo su -c "ceph osd crush move region2 root=$root_name"
sudo su -c "ceph osd crush move dc1 region=region1"
sudo su -c "ceph osd crush move dc2 region=region1"
sudo su -c "ceph osd crush move dc3 region=region2"
sudo su -c "ceph osd crush move dc4 region=region2"
sudo su -c "ceph osd crush move rack2 datacenter=dc2"
sudo su -c "ceph osd crush move rack3 datacenter=dc3"
sudo su -c "ceph osd crush move rack4 datacenter=dc4"

region1_nodes=(${rack1_hosts[@]} ${rack2_hosts[@]})
region2_nodes=(${rack3_hosts[@]} ${rack4_hosts[@]})

# bringing down region
for node2fail in ${region1_nodes[@]}
do
  sudo su -c "salt ${node2fail}.teuthology cmd.run \"iptables -I OUTPUT -d localhost -j ACCEPT\""
  sudo su -c "salt ${node2fail}.teuthology cmd.run \"iptables -I OUTPUT -d $master -j ACCEPT\""
  sudo su -c "salt ${node2fail}.teuthology cmd.run \"iptables -I INPUT -s localhost -j ACCEPT\""
  sudo su -c "salt ${node2fail}.teuthology cmd.run \"iptables -I INPUT -s $master -j ACCEPT\""
  sudo su -c "salt ${node2fail}.teuthology cmd.run \"iptables -P INPUT DROP\""
  sudo su -c "salt ${node2fail}.teuthology cmd.run \"iptables -P OUTPUT DROP\""
done

until sudo su -c "ceph -s | grep \".* region.* down\""
do 
 sleep 30
done

sudo ceph -s
 
sudo su -c "ceph osd tree"

# bring region up
for node2fail in ${region1_nodes[@]}
do
  sudo su -c "salt ${node2fail}.teuthology cmd.run \"iptables -P INPUT ACCEPT\""
  sudo su -c "salt ${node2fail}.teuthology cmd.run \"iptables -P OUTPUT ACCEPT\""
  sudo su -c "salt ${node2fail}.teuthology cmd.run \"iptables -F\""
done

cluster_health

# remove pool
sudo su -c "ceph osd pool rm crushmap crushmap --yes-i-really-really-mean-it"
while [ $(sudo su -c "ceph -s | grep creating -c") -gt 0 ]; do echo -n .;sleep 1; done

# set back default crushmap
sudo su -c "ceph osd setcrushmap -i ${crushmap_file}.bin"

sudo su -c "ceph osd crush tree"

cluster_health

rm -f ${crushmap_file}.{txt,bin}
