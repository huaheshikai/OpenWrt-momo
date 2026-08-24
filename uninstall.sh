#!/bin/sh

# uninstall
if [ -x "/bin/opkg" ]; then
	opkg remove momo
elif [ -x "/usr/bin/apk" ]; then
	apk del momo
fi
# remove config
rm -f /etc/config/momo
# remove files
rm -rf /etc/momo
# remove log
rm -rf /var/log/momo
# remove temp
rm -rf /var/run/momo
# remove feed
if [ -x "/bin/opkg" ]; then
	if grep -q momo /etc/opkg/customfeeds.conf; then
		sed -i '/momo/d' /etc/opkg/customfeeds.conf
	fi
	wget -O "momo.pub" "https://momomomo.pages.dev/key-build.pub"
	opkg-key remove momo.pub
	rm -f momo.pub
elif [ -x "/usr/bin/apk" ]; then
	if grep -q momo /etc/apk/repositories.d/customfeeds.list; then
		sed -i '/momo/d' /etc/apk/repositories.d/customfeeds.list
	fi
	rm -f /etc/apk/keys/momo.pem
fi
