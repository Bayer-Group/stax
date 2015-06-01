#!/bin/bash -v
# set up ha nat monitoring
# read command line arguments
other_route_table="$1"
my_route_table="$2"
aws_region="$3"
nat_monitor_bucket="$4"

ec2_url="https://ec2.${aws_region}.amazonaws.com"

# Configure iptables
/sbin/iptables -t nat -A POSTROUTING -o eth0 -s 0.0.0.0/0 -j MASQUERADE
/sbin/iptables-save > /etc/sysconfig/iptables
# Configure ip forwarding and redirects
echo 1 >  /proc/sys/net/ipv4/ip_forward && echo 0 >  /proc/sys/net/ipv4/conf/eth0/send_redirects
mkdir -p /etc/sysctl.d/
cat <<EOF > /etc/sysctl.d/nat.conf
net.ipv4.ip_forward = 1
net.ipv4.conf.eth0.send_redirects = 0
EOF
# Get ID of other NAT
NAT_ID=
# CloudFormation should have updated the other route table by now (due to yum update), however loop to make sure
while [ -z "$NAT_ID" ]; do
  sleep 60
  NAT_ID=`/opt/aws/bin/ec2-describe-route-tables "$other_route_table" -U "$ec2_url" | awk '/0.0.0.0\/0/ {print $2}'`
done
# Download nat_monitor.sh and configure
aws s3 cp "s3://$nat_monitor_bucket/nat_monitor.sh" /root/nat_monitor.sh
nat_monitor="/bin/bash /root/nat_monitor.sh $NAT_ID $other_route_table $my_route_table $ec2_url"
echo "@reboot $nat_monitor > /tmp/nat_monitor.log" | crontab
$nat_monitor >> /tmp/nat_monitor.log &
#### 20141202 - added to provide traffic logging
## Enable logging of this userdata script for review post build
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1
##Tell Rsyslog to log all Netfilter traffic to its own file
echo ':msg, contains, "NETFILTER"       /var/log/iptables.log' >>/etc/rsyslog.conf
echo ':msg, contains, "NETFILTER"     ~' >>/etc/rsyslog.conf
##Restart rsyslog
service rsyslog restart
##Create log rotation for connection logging
cat > /etc/logrotate.d/iptables << EOF
/var/log/iptables.log {
   missingok
   notifempty
   compress
   size 20k
   daily
   rotate 28
   create 0600 root root
}
EOF
##Stop IPtables if started
service iptables stop
##Backup current IPtables
cp /etc/sysconfig/iptables /etc/sysconfig/iptables.bkup
##Start IP Tables
service iptables start
##Clear all current rules
iptables --flush
##Enable logging on all new connections inbound and outbound
iptables -I INPUT -m state --state NEW -j LOG --log-prefix "NETFILTER"
iptables -I OUTPUT -m state --state NEW -j LOG --log-prefix "NETFILTER"
##Save our IPtables rules to persist reboot
service iptables save
#### 20141202 - added to provide traffic logging
