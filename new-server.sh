#!/bin/bash

# To do
#   ssh-keygen -t rsa and display id_rsa.pub and instruct to place in $HOST:/root/.ssh/authorized_keys mode 600.
#   Have all the instructions at the end of this script be handled automatically via SSH.

SNAPROOT=/backup/snapshots
[ -z "$SNAPROOT" ] && { echo "SNAPROOT not defined."; exit; }
/bin/df $SNAPROOT | grep $SNAPROOT >/dev/null || {
	/bin/df -h
	echo -n "For the safety of your system, it's recommended that the snapshots get their own partition.  Proceed anyway? [y/N] "; read yn;
	[ "$yn" != "y" -a "$yn" != "Y" ] && exit;
}

echo -n "Is this the host that is storing the backups? [y/N] "; read yn
[ "$yn" != "y" -a "$yn" != "Y" ] && { echo "Run this on the host that is storing the backups."; exit; }

[ -z "$1" ] && { echo "Usage: $0 Orgcode   [name_of_machine_being_backed_up]   [hostname_that_machine_being_backed_up_will_use_to_contact_this_backup_server   [push_is_coming_from_fqdn] ]"; exit; }

LOCAL=0
ORGCODE=$1
HOST=${2:-localhost}
BHOST=${3:-localhost}
[ "$BHOST" == "localhost" ] && LOCAL=1
FQDN=${4:-$HOST}
tmd5sum=$(dd if=/dev/urandom count=128 bs=1 2>&1 | md5sum | cut -b-32)
echo -n "md5sum: [$tmd5sum] "; read md5sum; md5sum=${md5sum:-$tmd5sum}
datefmt="%Y%m%d%H:%M:%S"
DATE=$(date +$datefmt)
[ "$BHOST" == "localhost" ] && { echo -n "Friendly name of this backup server: [localhost] "; read FBHOST; FBHOST=${FBHOST:-localhost}; }
FBHOST=${FBHOST:-$BHOST}

cat <<EOF
ORGCODE=$ORGCODE
HOST=$HOST
BHOST=$BHOST
FBHOST=$FBHOST
FQDN=$FQDN
md5sum=$md5sum
datefmt=$datefmt
DATE=$DATE
EOF
echo -n "Do these values look right? [y/N] "; read yn
[ "$yn" != "y" -a "$yn" != "Y" ] && { echo "Try again then."; exit; }

cd $SNAPROOT
[ ! -e $SNAPROOT/exec-rsync ] && { echo $SNAPROOT/exec-rsync not found.; exit; }
[ ! -f $SNAPROOT/.config -o ! -s $SNAPROOT/.config ] && echo SYMNAME=current > $SNAPROOT/.config
[ -f $SNAPROOT/.config ] && . $SNAPROOT/.config
[ -z "$SYMNAME" ] && { echo "SYMNAME not defined."; exit; }
[ -e "$SNAPROOT/$ORGCODE/$HOST" ] && { echo "$SNAPROOT/$ORGCODE/$HOST already exists."; exit; }
mkdir -p $SNAPROOT/$ORGCODE/$HOST/$DATE
[ ! -f $SNAPROOT/$ORGCODE/.config -o ! -s $SNAPROOT/$ORGCODE/.config ] && cat <<EOF > $SNAPROOT/$ORGCODE/.config
#MAILTO=root@localhost
#MAILOK=Yes
#SMTP=localhost
EOF
ln -s $DATE $SNAPROOT/$ORGCODE/$HOST/$SYMNAME
[ ! -L $SNAPROOT/pre-rsync ] && rm -f $SNAPROOT/pre-rsync
[ ! -L $SNAPROOT/post-rsync ] && rm -f $SNAPROOT/post-rsync
[ ! -e $SNAPROOT/pre-rsync ] && ln -s exec-rsync $SNAPROOT/pre-rsync
[ ! -e $SNAPROOT/post-rsync ] && ln -s exec-rsync $SNAPROOT/post-rsync
chmod 755 $SNAPROOT/exec-rsync
[ ! -d /etc/xinetd.d ] && mkdir -p /etc/xinetd.d
[ ! -e /etc/xinetd.d/rsync ] && cat <<EOF > /etc/xinetd.d/rsync
# default: off
# description: The rsync server is a good addition to an ftp server, as it \
#	allows crc checksumming etc.
service rsync
{
	disable         = no
	socket_type     = stream
	wait            = no
	user            = root
	server          = /usr/bin/rsync
	server_args     = --daemon
}
EOF
[ ! -e /etc/rsyncd.conf ] && cat <<EOF > /etc/rsyncd.conf
uid = root
gid = root
pid file = /var/run/rsyncd.pid

# Secrets file MUST be chmod 600!
# dd if=/dev/urandom count=128 bs=1 2>&1 | md5sum | cut -b-32

EOF
[ ! -e /etc/rsyncd.secrets ] && touch /etc/rsyncd.secrets
grep ^root: /etc/rsyncd.secrets || echo root:secret > /etc/rsyncd.secrets
SECRET=$(grep ^root: /etc/rsyncd.secrets | cut -d: -f2)
chmod 600 /etc/rsyncd.secrets

SSH=""
if [ "$LOCAL" -eq 1 ]; then
	echo "Setting up for local backups"
	grep "$ORGCODE-$md5sum" /etc/rsyncd.conf || sed "s/\$ORGCODE/$ORGCODE/g; s/\$md5sum/$md5sum/g" <<EOF >> /etc/rsyncd.conf
[$ORGCODE-$md5sum]
	path = $SNAPROOT/$ORGCODE
	hosts allow = 127.0.0.1
	auth users = root
	secrets file = /etc/rsyncd.secrets
	list = false
	read only = false
	write only = true
	pre-xfer exec = $SNAPROOT/pre-rsync
	post-xfer exec = $SNAPROOT/post-rsync

EOF
	for i in /root/.cpan /root/rpmbuild \
		/usr/src /usr/share/doc /usr/share/man \
		/var/log /var/apache-mm /var/cache /var/catman /var/empty /var/nis /var/opt /var/preserve /var/qmail.bak /var/tmp /var/yp \
		/data/deleted_users /data/db_backups /data/iso /data/oldservers /data/backup /data/backup-old \
		$SNAPROOT; do
		[ -d "$i" -a ! -e "$i/.snapshot-exclude" ] && { echo '- *' > $i/.snapshot-exclude; }
	done
else
	echo "Setting up for remote backups"
	which host >/dev/null || { echo "Install package bind-utils for the 'host' executable"; }
	IP=$(host -t a "$FQDN" | sed "s/$FQDN has address //")
	[ -z "$IP" ] && { echo -n "IP of $FQDN: "; read IP; IP=${IP:-127.0.0.1}; }
	grep "$ORGCODE-$md5sum" /etc/rsyncd.conf || sed "s/\$ORGCODE/$ORGCODE/g; s/\$md5sum/$md5sum/g" <<EOF >> /etc/rsyncd.conf
[$ORGCODE-$md5sum]
	path = $SNAPROOT/$ORGCODE
	auth users = root
	secrets file = /etc/rsyncd.secrets
	use chroot = true
	list = false
	read only = false
	write only = true
	pre-xfer exec = $SNAPROOT/pre-rsync
	post-xfer exec = $SNAPROOT/post-rsync

EOF
	SSH="-e \"ssh -p 22\""
	echo The public key from $IP for root@$HOST is now needed.  To generate the key, on $HOST as root, execute:
        echo "   ssh-keygen -t rsa ; cat ~/.ssh/id_rsa.pub"
	echo And paste that key here.
	echo -n "Public Key: "; read key
	[ ! -d /root/.ssh ] && mkdir -p /root/.ssh
	[ ! -e /root/.ssh/authorized_keys ] && touch /root/.ssh/authorized_keys
	grep "$key" /root/.ssh/authorized_keys || echo -e "from=\"$IP\",command=\"$SNAPROOT/validate-rsync\"\t$key" >> /root/.ssh/authorized_keys
	chmod 700 /root/.ssh
	chmod 600 /root/.ssh/authorized_keys
	cat <<EOF > $SNAPROOT/validate-rsync
#!/bin/bash

case "$SSH_ORIGINAL_COMMAND" in
	*\&*) echo "Rejected";;
	*\(*) echo "Rejected";;
	*\{*) echo "Rejected";;
	*\;*) echo "Rejected";;
	*\<*) echo "Rejected";;
	*\`*) echo "Rejected";;
	*\|*) echo "Rejected";;
	rsync\ *--server*) $SSH_ORIGINAL_COMMAND;;
	*) echo "Rejected";;
esac
EOF
	chmod 755 $SNAPROOT/validate-rsync
	echo Run this once on the pushing host to be backed up.
	for i in /root/.cpan /root/rpmbuild \
		/usr/src /usr/share/doc /usr/share/man \
		/var/log /var/apache-mm /var/cache /var/catman /var/empty /var/nis /var/opt /var/preserve /var/qmail.bak /var/tmp /var/yp \
		/data/deleted_users /data/db_backups /data/iso /data/oldservers /data/backup /data/backup-old \
		$SNAPROOT; do
		echo "[ -d \"$i\" -a ! -e \"$i/.snapshot-exclude\" ] && { echo '- *' > $i/.snapshot-exclude; }"
	done

	echo
	echo \*\*\* Make sure that $HOST can resolv $BHOST and that this backup server can reverse resolv $HOST
	echo
fi

echo
echo Put this in cron on the host to be backed up.  A script called snapshots or whatever in cron.hourly or daily or tab or whatever.  Your call.  \(See $SNAPROOT/snapshot-$FBHOST.sh\)
echo Of course, modify the list of sources and excludes.  Easiest is to create files named by the rsync filter with contents \'- *\' in directories to ignore.
echo
cat <<EOF | tee $SNAPROOT/snapshot-$FBHOST.sh
#!/bin/bash

export SOURCES="/boot /root /downloads /service /etc /opt /usr /var /data /home"
export DATE=\$(date +"%Y%m%d%H:%M:%S")
env RSYNC_PASSWORD=$SECRET rsync -vaziAPx --stats --timeout 3600 --delete --delete-excluded -f ': .snapshot-exclude' -f ': snapshot-exclude.txt' --exclude $SNAPROOT \$SOURCES --link-dest=../$SYMNAME rsync://$BHOST/$ORGCODE-$md5sum/$HOST/.\$DATE
curl -d orgcode=$ORGCODE -d bhost=$FBHOST -d host=$HOST -d date=\$DATE -d md5sum=$md5sum -d return=\$? http://www.cogent-it.com/snapshots.cgi
EOF
[ "$LOCAL" -eq 1 -a ! -e /etc/cron.hourly/snapshot-$FBHOST.sh ] && /bin/cp $SNAPROOT/snapshot-$FBHOST.sh /etc/cron.hourly && chmod +x /etc/cron.hourly/snapshot-$FBHOST.sh && echo \*\*\* Installed +x /etc/cron.hourly/snapshot-$FBHOST.sh

echo
echo Put this in cron on the host that stores the backups.  A script called logstatus or whatever in cron.hourly or daily or tab or whatever.  Your call.  \(See $SNAPROOT/snapshot-status.sh\)
echo
cat <<EOF | tee $SNAPROOT/snapshot-status.sh
#!/bin/bash

curl -d orgcode=$ORGCODE -d bhost=$FBHOST -d md5sum=$md5sum -d system=df -d status="\$(df -h | sed 's/\"/~quot~/g; s/ /~nbsp~/g; s/\t/~tab~/g; s/\$/~crlf~/g' | paste -s -d '')" http://www.cogent-it.com/snapshots.cgi
EOF
[ "$LOCAL" -eq 1 -a ! -e /etc/cron.hourly/snapshot-status.sh ] && /bin/cp $SNAPROOT/snapshot-status.sh /etc/cron.hourly && chmod +x /etc/cron.hourly/snapshot-status.sh && echo \*\*\* Installed +x /etc/cron.hourly/snapshot-status.sh

which xinetd >/dev/null || { echo ; echo You need to install the xinetd package and make sure that xinetd is running and auto-started.; }
which curl >/dev/null || { echo ; echo You need to install the curl package.; }
