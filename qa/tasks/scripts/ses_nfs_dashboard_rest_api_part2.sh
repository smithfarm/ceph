set -ex


function curl_cmd (){
    local request_type=$1
    local login_token=$2
    local url=$3
    local data=$4
    
    if [ ! -z "$data" ]
    then
        curl -X $request_type -s -H "accept: */*" -H "Authorization: Bearer $login_token" "${dashboard_addr}$url" -H "Content-Type: application/json" -d "$(cat $data)"
    else
        curl -X $request_type -s -H "accept: */*" -H "Authorization: Bearer $login_token" "${dashboard_addr}$url"
    fi
}

function rgw_bucket(){
    local path=$1
    local pseudo=$2
    local tag=$3
cat << EOF > /tmp/rgw_export.json
{
  "path": "$path",
  "cluster_id": "$cluster_id",
  "daemons": $daemons,
  "pseudo": "$pseudo",
  "access_type": "RW",
  "tag": "$tag",
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

function cephfs_bucket () {
    local path=$1
    local pseudo=$2
    local tag=$3
cat << EOF > /tmp/cephfs_export.json
{
  "path": "$path",
  "cluster_id": "$cluster_id",
  "daemons": $daemons,
  "pseudo": "$pseudo/",
  "access_type": "RW",
  "tag": "$tag",
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

ceph config set mgr mgr/dashboard/ssl false
ceph mgr module disable dashboard
ceph mgr module enable dashboard
sleep 10
radosgw-admin user create --uid=admin --display-name=admin
dashboard_addr="$(ceph mgr services --format=json | jq -r .dashboard)"

ceph dashboard set-login-credentials admin admin >/dev/null

login_token="$(curl -X POST -H "Content-Type: application/json" -d '{"username":"admin","password":"admin"}' \
	${dashboard_addr}api/auth -s | jq -r .token)"
rgw_user_id="$(radosgw-admin user info --uid=admin --format=json | jq -r .keys[0].user)"
rgw_access_key="$(radosgw-admin user info --uid=admin --format=json | jq -r .keys[0].access_key)"
rgw_secret_key="$(radosgw-admin user info --uid=admin --format=json | jq -r .keys[0].secret_key)"
cluster_id="$(curl_cmd "GET" "$login_token" "api/nfs-ganesha/daemon" \
		| jq -r .[0].cluster_id)"
daemons=[\ $(curl_cmd "GET" "$login_token" "api/nfs-ganesha/daemon" \
		| jq -r .[].daemon_id | xargs -I {} echo \"{}\" | tr '\n' ',' | sed 's/.$//')\ ]


# create cephfs nfs share
cephfs_bucket "/cephfs1" "/cephfs1_pseudo" "cephfs1_tag" 
cephfs_export_id=$(curl_cmd "POST" "$login_token" "api/nfs-ganesha/export" "/tmp/cephfs_export.json" \
	| jq -r .export_id)

# create rgw nfs share
rgw_bucket "rgw_bucket" "/rgw_bucket_ps" "rgw_bucket_tag"
rgw_export_id=$(curl_cmd "POST" "$login_token" "api/nfs-ganesha/export" "/tmp/rgw_export.json" \
	| jq -r .export_id)


# shares testing
mkdir -p /mnt/{rgw,cephfs}

if [ ! -z "$cephfs_export_id" ]
then
    for nfs_daemon in $(curl_cmd "GET" "$login_token" "api/nfs-ganesha/daemon" | jq -r .[].daemon_id)
    do
        echo "testing $nfs_daemon"
        if showmount -e $nfs_daemon
        then
            mount $nfs_daemon:/cephfs1_pseudo /mnt/cephfs
            dd if=/dev/zero of=/mnt/cephfs/cephfs_testfile.bin oflag=direct bs=1M count=100
            sleep 5
            df -h /mnt/cephfs/cephfs_testfile.bin
            rm -f /mnt/cephfs/cephfs_testfile.bin
            umount /mnt/cephfs
            echo "passed"
        fi
    done
fi

if [ ! -z "$rgw_export_id" ]
then
    for nfs_daemon in $(curl_cmd "GET" "$login_token" "api/nfs-ganesha/daemon" | jq -r .[].daemon_id)
    do
        echo "testing $nfs_daemon"
        if showmount -e $nfs_daemon
        then
            mount $nfs_daemon:/rgw_bucket_ps /mnt/rgw
            dd if=/dev/zero of=/mnt/rgw/rgw_testfile.bin oflag=direct bs=1M count=100
            sleep 5
            df -h /mnt/rgw/rgw_testfile.bin
            rm -f /mnt/rgw/rgw_testfile.bin
            umount /mnt/rgw
            echo "passed"
        fi
    done
fi

rm -rf /mnt/{rgw,cephfs}

# delete nfs exports
curl_cmd "DELETE" "$login_token" "api/nfs-ganesha/export/$cluster_id/$cephfs_export_id"
curl_cmd "DELETE" "$login_token" "api/nfs-ganesha/export/$cluster_id/$rgw_export_id"
