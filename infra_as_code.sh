#!/bin/bash

#
# sample script to deploy cms + loadbalancer on openstack IaaS
#

case "$OS_USERNAME" in
facebook100000270138421)
	IMAGE=tinyweb.img
	;;
cms|admin|snsakala)
	IMAGE=wordpress.img
	MYSQL=yes
	;;
*)
	echo "source the keystonerc before running this script"
	exit 1
	;;
esac

case "$1" in
deploy)
	neutron net-create private
	neutron subnet-create --name service --dns-nameserver 172.16.2.1 private 10.0.0.0/24
	neutron router-create router
	neutron router-gateway-set router external
	neutron router-interface-add router service

	echo Using $IMAGE as wordpress image
	glance image-create \
	--name wordpress \
	--disk-format qcow2 \
	--container-format bare \
	--file $PWD/$IMAGE \
	--progress

	[ -n "$MYSQL" ] && glance image-create \
	--name mysql \
	--disk-format qcow2 \
	--container-format bare \
	--file $PWD/mysql.img \
	--progress


	nova secgroup-create web web
	nova secgroup-add-rule web tcp 80 80 0.0.0.0/0

	nova keypair-add --pub-key $PWD/snsakala_rsa.pub snsakala

	NETID=$( neutron net-list | perl -lne 'print $1 if /^\| (\S{10,}) \| private/' )

	[ -n "$MYSQL" ] && { 
		nova boot --key-name snsakala --security-groups default --flavor m1.medium --image mysql \
        	--nic net-id=$NETID mysql
		while [ "$( nova list | grep mysql | grep ACTIVE | wc -l )" -ne 1 ]; do sleep 1; done
	}

	nova boot --key-name snsakala --security-groups default,web --flavor m1.small --image wordpress --nic net-id=$NETID cms1
	nova boot --key-name snsakala --security-groups default,web --flavor m1.small --image wordpress --nic net-id=$NETID cms2

	while [ "$( nova list | grep cms | grep ACTIVE | wc -l )" -ne 2 ]; do sleep 1; done

	neutron lb-pool-create --lb-method ROUND_ROBIN --name wordpress --protocol HTTP --subnet-id service
	neutron lb-vip-create --name wordpress --protocol-port 80 --protocol HTTP --subnet-id service wordpress
	IPS=$( nova list | perl -lne 'print $1 if / cms. .* private=((\d+\.){3}\d+)/' )
	for IP in $IPS; do
		neutron lb-member-create --address $IP --protocol-port 80 wordpress
	done

	nova floating-ip-create external
	VIPID=$( neutron lb-vip-list | perl -lne 'print $1 if /^\| (\S{10,})/' )
	VIPPORT=$( neutron lb-vip-show $VIPID | perl -lne 'print $1 if /port_id\s+\| (\S+)/' )
	FIPID=$( neutron floatingip-list | perl -lne 'print $1 if /^\| (\S{10,})/' )
	neutron floatingip-associate $FIPID $VIPPORT

	;;
undeploy)
	FIPID=$( neutron floatingip-list | perl -lne 'print $1 if /^\| (\S{10,})/' )
	neutron floatingip-disassociate $FIPID

	VIPID=$( neutron lb-vip-list | perl -lne 'print $1 if /^\| (\S{10,})/' )
	neutron lb-vip-delete $VIPID

	MEMBERS=$( neutron lb-member-list | perl -lne 'print $1 if /^\| (\S{10,})/' )
	for MEMBER in $MEMBERS; do
		neutron lb-member-delete $MEMBERS
	done

	neutron lb-pool-delete wordpress

	IP=$( nova floating-ip-list | perl -lne 'print $1 if /((\d+\.){3}\d+)/' )
	[ -n "$IP" ] && nova floating-ip-delete $IP

	nova delete cms2
	nova delete cms1
	[ -n "$MYSQL" ] && nova delete mysql

	nova keypair-delete snsakala

	nova secgroup-delete web

	glance image-delete wordpress
	[ -n "$MYSQL" ] && glance image-delete mysql

	neutron router-interface-delete router service
	neutron router-gateway-clear router 
	neutron router-delete router
	neutron subnet-delete service
	neutron net-delete private
	;;
*)
	echo `basename $0` "deploy|undeploy"
	;;
esac
