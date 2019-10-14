set -ex


curl_cmd (){

	# $1 = request type (POST or GET or DELETE)
	# $2 = login_token
	# $3 = url
	# $4 = data

	if [ ! -z "$4" ]
	then
	       	sudo su -c "curl -X $1 -s -H \"accept: */*\" -H \"Authorization: Bearer $2\" \"${dashboard_addr}$3\" -H \"Content-Type: application/json\" -d \"$(cat $4)\""
	else
	       	sudo su -c "curl -X $1 -s -H \"accept: */*\" -H \"Authorization: Bearer $2\" \"${dashboard_addr}$3\""
	fi
}

rgw_bucket(){
 # $1 path
 # $2 pseudo
 # $3 tag
cat << EOF > /tmp/rgw_export.json
{
  "path": "$1",
  "cluster_id": "$cluster_id",
  "daemons": $daemons,
  "pseudo": "$2",
  "access_type": "RW",
  "tag": "$3",
  "squash": "no_root_squash",
  "security_label": false,
  "protocols": [ 3, 4 ],
  "transports": [ "TCP", "UDP" ],
  "fsal": {
    "name": "RGW",
    "rgw_user_id": "$rgw_user_id"
  },
  "clients": [],
  "reload_daemons": "true"
}
EOF
}

cephfs_bucket () {
 # $1 path
 # $2 pseudo
 # $3 tag
cat << EOF > /tmp/cephfs_export.json
{
  "path": "$1",
  "cluster_id": "$cluster_id",
  "daemons": $daemons,
  "pseudo": "$2/",
  "access_type": "RW",
  "tag": "$3",
  "squash": "no_root_squash",
  "security_label": "false",
  "protocols": [ 3, 4 ],
  "transports": [ "TCP", "UDP" ],
  "fsal": {
    "name": "CEPH",
    "user_id": "admin",
    "fs_name": "cephfs",
    "sec_label_xattr": null
  },
  "clients": [],
  "reload_daemons": "true"
}
EOF

}

# deploy services if they aren't already
storage_minions=`sudo su -c "salt-run select.minions roles=storage --output=json | jq -r .[]"`
storage_minions_num=`echo "$storage_minions" | wc -l`
if [ -z "`sudo su -c "salt-run select.minions roles=ganesha"`" ]
then
	sudo su -c "echo \"role-ganesha/cluster/$(echo \"$storage_minions\" \
		| sed \"`shuf -i 1-$storage_minions_num -n1`q;d\")\" >> /srv/pillar/ceph/proposals/policy.cfg"
fi

if [ -z "`sudo su -c "salt-run select.minions roles=mds"`" ]
then
	sudo su -c "echo \"role-mds/cluster/$(echo \"$storage_minions\" \
		| sed \"`shuf -i 1-$storage_minions_num -n1`q;d\")\" >> /srv/pillar/ceph/proposals/policy.cfg"
fi

if [ -z "`sudo su -c "salt-run select.minions roles=rgw"`" ]
then
	sudo su -c "echo \"role-rgw/cluster/$(echo \"$storage_minions\" \
		| sed \"`shuf -i 1-$storage_minions_num -n1`q;d\")\" >> /srv/pillar/ceph/proposals/policy.cfg"
fi

sudo su -c "salt-run state.orch ceph.stage.2"
sudo su -c "salt-run state.orch ceph.stage.3"
sudo su -c "salt-run state.orch ceph.stage.4"

dashboard_addr="`sudo su -c "ceph mgr services --format=json | jq -r .dashboard"`"

# test if user admin with password admin is working 
# update credentials if not
if ! curl -X POST -H "Content-Type: application/json" -d '{"username":"admin","password":"admin"}' \
	${dashboard_addr}api/auth -s | jq -r .token >/dev/null 2>&1
then
        sudo su -c "ceph dashboard set-login-credentials admin admin >/dev/null"
fi

login_token="`curl -X POST -H "Content-Type: application/json" -d '{"username":"admin","password":"admin"}' \
	${dashboard_addr}api/auth -s | jq -r .token`"
rgw_user_id="`sudo su -c "radosgw-admin user info --uid=admin --format=json | jq -r .keys[0].user"`"
rgw_access_key="`sudo su -c "radosgw-admin user info --uid=admin --format=json | jq -r .keys[0].access_key"`"
rgw_secret_key="`sudo su -c "radosgw-admin user info --uid=admin --format=json | jq -r .keys[0].secret_key"`"
cluster_id="`curl_cmd "GET" "$login_token" "api/nfs-ganesha/daemon" \
	| jq -r .[0].cluster_id`"
daemons=[\ `curl_cmd "GET" "$login_token" "api/nfs-ganesha/daemon" \
	| jq -r .[].daemon_id | xargs -I {} echo \"{}\" | tr '\n' ',' | sed 's/.$//'`\ ]


# create cephfs nfs share
cephfs_bucket "/cephfs1" "/cephfs1_pseudo" "cephfs1_tag" 
cephfs_export_id=`curl_cmd "POST" "$login_token" "api/nfs-ganesha/export" "/tmp/cephfs_export.json" \
	| jq -r .export_id`

# create rgw nfs share
rgw_bucket "rgw_bucket" "/rgw_bucket_ps" "rgw_bucket_tag"
rgw_export_id=`curl_cmd "POST" "$login_token" "api/nfs-ganesha/export" "/tmp/rgw_export.json" \
	| jq -r .export_id`


# shares testing
sudo su -c "mkdir -p /mnt/{rgw,cephfs}"

if [ ! -z "$cephfs_export_id" ]
then
	for nfs_daemon in `curl_cmd "GET" "$login_token" "api/nfs-ganesha/daemon" | jq -r .[].daemon_id`
	do
		echo
	       	echo "testing $nfs_daemon"
		if sudo su -c "showmount -e $nfs_daemon"
		then
		       	sudo su -c "mount $nfs_daemon:/cephfs1_pseudo /mnt/cephfs"
			sudo su -c "dd if=/dev/zero of=/mnt/cephfs/cephfs_testfile.bin oflag=direct bs=1M count=100"
			sleep 5
			echo
			sudo su -c "df -h /mnt/cephfs/cephfs_testfile.bin"
			sudo su -c "rm -f /mnt/cephfs/cephfs_testfile.bin"
			sudo su -c "umount /mnt/cephfs"
			echo "passed"
		fi
	done

fi

if [ ! -z "$rgw_export_id" ]
then
	for nfs_daemon in `curl_cmd "GET" "$login_token" "api/nfs-ganesha/daemon" | jq -r .[].daemon_id`
	do
		echo
	       	echo "testing $nfs_daemon"
		if sudo su -c "showmount -e $nfs_daemon"
		then
		       	sudo su -c "mount $nfs_daemon:/rgw_bucket_ps /mnt/rgw"
			sudo su -c "dd if=/dev/zero of=/mnt/rgw/rgw_testfile.bin oflag=direct bs=1M count=100"
			sleep 5
			echo
			sudo su -c "df -h /mnt/rgw/rgw_testfile.bin"
			sudo su -c "rm -f /mnt/rgw/rgw_testfile.bin"
			sudo su -c "umount /mnt/rgw"
			echo "passed"
		fi
	done

fi

sudo su -c "rm -rf /mnt/{rgw,cephfs}"

# delete nfs exports
curl_cmd "DELETE" "$login_token" "api/nfs-ganesha/export/$cluster_id/$cephfs_export_id"
curl_cmd "DELETE" "$login_token" "api/nfs-ganesha/export/$cluster_id/$rgw_export_id"
