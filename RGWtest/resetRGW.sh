#!/bin/bash
# RESETRGW.sh

myPath="${BASH_SOURCE%/*}"
if [[ ! -d "$myPath" ]]; then
    myPath="$PWD" 
fi

# Variables
source "$myPath/vars.shinc"

#------------------------
# BEGIN FUNCTIONS
function delete_pools {
  for pl in ${pool_list[@]}; do
      if [ $pl != "rbd" ]; then
          $execMON ceph osd pool delete $pl $pl --yes-i-really-really-mean-it
      fi
  done

  sleep 5
  $execMON ceph osd crush rule rm default.rgw.buckets.data
}

function create_pools {
  if [ "$1" == "rep" ]; then
      cmdtail="replicated"
  elif [ "$1" == "ec" ]; then
      cmdtail="erasure myprofile"
      $execMON ceph osd erasure-code-profile rm myprofile
      $execMON ceph osd erasure-code-profile set myprofile k=$k m=$m
      $execMON ceph osd crush rule create-erasure default.rgw.buckets.data myprofile
  else
      echo "unknown value for REPLICATION in create_pools"; exit
  fi

  for pl in ${pool_list[@]}; do
      if [ $pl == "default.rgw.buckets.data" ]; then
          $execMON ceph osd pool create $pl $pg_data $cmdtail
          if [ "$1" == "rep" ]; then
              $execMON ceph osd pool set $pl size "${numREPLICAS}"
          fi
      elif [ $pl == "default.rgw.buckets.index" ]; then
          $execMON ceph osd pool create $pl $pg_index replicated
          $execMON ceph osd pool set $pl size "${numREPLICAS}"
      else
          $execMON ceph osd pool create $pl $pg replicated
          $execMON ceph osd pool set $pl size "${numREPLICAS}"
      fi
  done

  # enable RGW on the pools for RHCS 3.x builds
  if echo $CEPH_VERSION | grep -q "10.2." ; then
    echo "Skip pool enable for 2.5 versions"
  else
    for pool in $(rados lspools); do
       $execMON ceph osd pool application enable $pool rgw --yes-i-really-mean-it
    done
  fi
}

# END FUNCTIONS
#------------------------

echo "$PROGNAME: Running with these values:"
echo "RGWhostname=$RGWhostname r=$REPLICATION k=$k m=$m pgdata=$pg_data pgindex=$pg_index \
      pg=$pg f=$fast_read"

echo "runmode=$runmode"
#if [ $runmode == "containerized" ]; then
#    nt_start=$(ssh $RGWhostname 'bash -s' < Utils/thr_time.sh)
#    echo -e $nt_start
#fi

echo "Stopping RGWs, and echoing status"
#ansible -m shell -a 'systemctl stop ceph-radosgw.target' rgws
ceph orch stop rgw.rgws
sleep 30
ceph orch ls rgw
#ansible -o -m shell -a 'systemctl status ceph-radosgw.target |grep Act' rgws

# ensure that pool deletion is enabled
$execMON ceph tell mon.\* injectargs '--mon-allow-pool-delete=true'
sleep 2

echo "Removing existing/old pools"
delete_pools

echo "Creating new pools"
create_pools $REPLICATION

# echo "sleeping for $longPAUSE seconds..."; sleep "${longPAUSE}"
echo "sleeping for 30 seconds..."; sleep 30

echo "Starting RGWs, and echoing status"
#ansible -m shell -a 'systemctl start ceph-radosgw.target' rgws
ceph orch start rgw.rgws
sleep 30
ceph orch ls rgw
#ansible -o -m shell -a 'systemctl status ceph-radosgw.target |grep Act' rgws

echo "Creating User - which generates a new Password"
$execMON 'radosgw-admin user create --uid=johndoe --display-name="John Doe" --email=john@example.com' &&
$execMON 'radosgw-admin subuser create --uid=johndoe --subuser=johndoe:swift --access=full' 

# Edit the Password into the XML workload files
echo "inserting new password into XML files $FILLxml, $AGExml, $UPGRADExml, $MEASURExml"
key=$($execMON 'radosgw-admin user info --uid=johndoe | grep secret_key' | tail -1 | awk '{print $2}' | sed 's/"//g')
sed  -i "s/password=.*;/password=$key;/g" ${FILLxml}
sed  -i "s/password=.*;/password=$key;/g" ${AGExml}
sed  -i "s/password=.*;/password=$key;/g" ${MEASURExml}
sed  -i "s/password=.*;/password=$key;/g" ${UPGRADExml}
#sed  -i "s/password=.*;/password=$key;/g" *.xml

if [ $runmode == "containerized" ]; then
    nt_end=$(ssh $RGWhostname 'bash -s' < Utils/thr_time.sh)
    echo -e $nt_end
fi

ceph config set global log_to_file true
ceph config set global mon_cluster_log_to_file true

echo "log_to_file and mon_cluster_log_to_file is set" 

echo "$PROGNAME: Done"

# DONE
