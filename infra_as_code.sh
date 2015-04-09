#!/usr/bin/bash

#
# sample script to deploy cms + loadbalancer on openstack IaaS
#

case "$1" in
create)
	neutron net-create private
	neutron subnet-create --name service --dns-nameserver 172.16.2.1 private 10.0.0.0/24
	neutron router-create router
	neutron router-gateway-set router external
	neutron router-interface-add router service

	glance image-create \
	--name wordpress \
	--disk-format qcow2 \
	--container-format bare \
	--file $PWD/wordpress.img \
	--progress

	nova secgroup-create web web
	nova secgroup-add-rule web tcp 80 80 0.0.0.0/0

	nova keypair-add --pub-key $PWD/snsakala_rsa.pub snsakala

	nova boot --key-name snsakala --security-groups default,web --flavor m1.small --image wordpress cms1
	nova boot --key-name snsakala --security-groups default,web --flavor m1.small --image wordpress cms2

	while [ "$( nova list | grep cms | grep ACTIVE | wc -l )" -ne 2 ]; do sleep 1; done

	neutron lb-pool-create --lb-method ROUND_ROBIN --name wordpress --protocol HTTP --subnet-id service
	neutron lb-vip-create --name wordpress --protocol-port 80 --protocol HTTP --subnet-id service wordpress
	IPS=$( nova list | perl -lne 'print $1 if /((\d+\.){3}\d+)/' )
	for IP in $IPS; do
		neutron lb-member-create --address $IP --protocol-port 80 wordpress
	done

	nova floating-ip-create external
	VIPID=$( neutron lb-vip-list | perl -lne 'print $1 if /^\| (\S{10,})/' )
	VIPPORT=$( neutron lb-vip-show $VIPID | perl -lne 'print $1 if /port_id\s+\| (\S+)/' )
	FIPID=$( neutron floatingip-list | perl -lne 'print $1 if /^\| (\S{10,})/' )
	neutron floatingip-associate $FIPID $VIPPORT

	;;
delete)
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

	nova keypair-delete snsakala

	nova secgroup-delete web

	glance image-delete wordpress

	neutron router-interface-delete router service
	neutron router-gateway-clear router 
	neutron router-delete router
	neutron subnet-delete service
	neutron net-delete private
	;;
*)
	echo `basename $0` "create|delete"
	;;
esac
