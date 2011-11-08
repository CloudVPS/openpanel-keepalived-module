PREFIX=${CURDIR}/debian/openpanel-openapp-pureftpd-auth

install:
# bin
	mkdir -p $(PREFIX)/usr/sbin
	cp sbin/openapp-pureftpd-auth $(PREFIX)/usr/sbin
	mkdir -p $(PREFIX)/etc/
	cp -r etc/ $(PREFIX)
	mkdir -p $(PREFIX)/etc/pure-ftpd/auth
	ln -sf ../conf/ExtAuth $(PREFIX)/etc/pure-ftpd/auth/20extauth


uninstall:
# bin
	rm /usr/sbin/openapp-pureftpd-auth
	rm /etc/pure-ftpd/auth/20extauth
	rm /etc/pure-ftpd/conf/ExtAuth
	rm /etc/init/pure-authd.conf

clean:
	-echo "NOP"

