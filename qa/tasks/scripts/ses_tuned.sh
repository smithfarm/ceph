set -ex

check_tuned(){
role=$1

if [ $(echo "$roles_list" | wc -l) -gt 1 ]
then
    for server in $(eval $getservers | awk '{print $2}')
    do 
        role=$(salt $server cmd.run "tuned-adm active | egrep '$role|virtual-guest'" --output=json | jq -r .[] | cut -d : -f 2)
    done
fi 
  
salt -L $(eval $getservers | awk '{print $2}' | tr '\n' ',') cmd.run "tuned-adm active | egrep '$role|virtual-guest'"
}

# listing all roles on all minions
echo "Listing all roles on all minions"
salt '*' cmd.run "tuned-adm list"

roles_list=$(salt '*' pillar.get "roles" | sort -u | grep "\- " | awk '{print $2}' | egrep -v 'admin|master|grafana')

# checking if correct tuned profile is set 
for role in $roles_list
do
    getservers="salt-run select.minions roles=$role | grep -v $(hostname -f)"
    if [ $role == ceph-osd ]
    then
        role=storage
        getservers="salt-run select.minions roles=$role | grep -v $(hostname -f)"
    fi
    
    if [ ! -z "$(eval $getservers)" ]
    then
        check_tuned $role
        salt -L $(eval $getservers | awk '{print $2}' | tr '\n' ',') service.restart tuned.service
        check_tuned $role
    fi
done

salt '*' service.enabled tuned.service
