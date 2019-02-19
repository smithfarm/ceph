#!/bin/bash
set -ex 
echo "This is my workunit. It will run on the Salt Master."
systemctl status salt-master.service
sudo salt '*' test.ping
echo "All good"
