#!/bin/bash

IP=$1
DOCKER_PORT=$2
OVS_PORT=$3
NAME="demo_cont"
BRIDGE="demo_ovs_br"
CONT_IFACE="eth1"
BRIDGE_REMOTE_PORT=6633
EXTERNAL_IFACE="enp6s0f1"
EXTERNAL_IP="10.1.1.2"
CONTAINER_IP="10.1.2.1"

# Create the container (one that will spin)                                                                        
#curl -X POST -H "Content-Type: application/json" -d '{"Image": "busybox", "Cmd": ["/bin/sh"], "NetworkDisabled": true, "HostConfig": {"AutoRemove": true}, "Tty": true}' http://"$IP":"$DOCKER_PORT"/v1.37/containers/create?name="$NAME"
curl -X POST -H "Content-Type: application/json" -d '{"Image": "busybox", "Cmd": ["/bin/sh"], "HostConfig": {"AutoRemove": true}, "Tty": true}' http://"$IP":"$DOCKER_PORT"/v1.37/containers/create?name="$NAME"

# Start the container
curl -s -X POST http://"$IP":"$DOCKER_PORT"/v1.37/containers/"$NAME"/start

# Add OVS Bridge
sudo ovs-vsctl --db=tcp:"$IP":"$OVS_PORT" --may-exist add-br "$BRIDGE"

# Add port to dataplane external interface
sudo ovs-vsctl --db=tcp:"$IP":"$OVS_PORT" --may-exist add-port "$BRIDGE" $EXTERNAL_IFACE -- set Interface $EXTERNAL_IFACE ofport_request=1

# Add port to docker container interface (make sure to include mask for ip address, otherwise assigns /32)
./ovs-docker-remote add-port $BRIDGE $CONT_IFACE $NAME $IP $OVS_PORT $DOCKER_PORT --ipaddress=$CONTAINER_IP/16

# Add route for container                                                                                
## if container has ip in it, can do this through the container:      
EXEC_ID=`curl -s -X POST -H "Content-Type: application/json" -d '{"AttachStdout": true, "Tty": true, "Cmd": ["ip", "route", "add", "10.1.0.0/16", "dev", "eth0"], "Privileged": true}' http://$IP:$DOCKER_PORT/v1.37/containers/$NAME/exec | jq -r '.Id'`

curl -s -X POST -H "Content-Type: application/json" -d '{"Detach": false, "Tty": true}' http://$IP:$DOCKER_PORT/exec/$EXEC_ID/start

# Add OVS routes               
## Make switch listen for remote commands
sudo ovs-vsctl --db=tcp:$IP:$OVS_PORT set-controller $BRIDGE ptcp:$BRIDGE_REMOTE_PORT

## Find ports
EXTERNAL_IF_OF_PORT=`sudo ovs-ofctl show tcp:$IP:$BRIDGE_REMOTE_PORT | grep $EXTERNAL_IFACE | awk -F '(' '{ print $1 }' | sed 's/ //g'`

CONTAINER_OVS_PORT=`sudo ovs-vsctl --db=tcp:$IP:$OVS_PORT --data=bare --no-heading --columns=name find interface external_ids:container_id=$NAME external_ids:container_iface=$CONT_IFACE`
CONTAINER_OF_PORT=`sudo ovs-ofctl show tcp:$IP:$BRIDGE_REMOTE_PORT | grep $CONTAINER_OVS_PORT | awk -F '(' '{ print $1 }' | sed 's/ //g'`

## Add flow rules
sudo ovs-ofctl add-flow tcp:$IP:$BRIDGE_REMOTE_PORT "priority=100 ip in_port=$EXTERNAL_IF_OF_PORT nw_src=$EXTERNAL_IP nw_dst=$CONTAINER_IP actions=output:$CONTAINER_OF_PORT"
sudo ovs-ofctl add-flow tcp:$IP:$BRIDGE_REMOTE_PORT "priority=100 ip in_port=$CONTAINER_OF_PORT nw_src=$CONTAINER_IP nw_dst=$EXTERNAL_IP actions=output:$EXTERNAL_IF_OF_PORT"
