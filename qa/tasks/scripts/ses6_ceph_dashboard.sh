set -ex

sudo su -c "ceph mgr module enable dashboard"

sudo su -c "ceph config set mgr mgr/dashboard/ssl false"

sudo su -c "ceph mgr module disable dashboard"
sudo su -c "ceph mgr module enable dashboard"

sudo su -c "ceph dashboard ac-user-create testuser testuser administrator"

sleep 15

dashboard_url=`sudo su -c "ceph mgr services" | grep dashboard | cut -d \" -f 4`

sudo su -c "curl $dashboard_url >/dev/null 2>&1"

