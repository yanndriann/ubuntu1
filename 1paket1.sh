#!/bin/bash
set -e
set -o pipefail

LOG_FILE="/var/log/setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1

if [[ $EUID -ne 0 ]]; then
   echo "SCRIPT BY ADRIAN"
   echo "Script ini harus dijalankan sebagai root!" 
   exit 1
fi

echo "🔧 Konfigurasi jaringan..."
INTERFACE="enp0s3"
cat <<EOF > /etc/netplan/00-installer-config.yaml
network:
  ethernets:
    $INTERFACE:
      dhcp4: no
      addresses:
        - 192.202.30.2/30
      nameservers:
        addresses:
          - 192.202.30.2
          - 192.202.30.1
      routes:
        - to: default
          via: 192.202.30.1
  version: 2
EOF

netplan try && netplan apply || echo "❌ Konfigurasi jaringan gagal!"
sleep 5

echo "🔄 Update sistem dan install paket yang diperlukan..."
apt update -y && apt upgrade -y

echo "📦 Instalasi paket yang diperlukan..."
apt install -y bind9 apache2 php php-mysql php-cli php-cgi php-gd php-mbstring mariadb-server unzip wget dnsutils net-tools ufw

echo "⚙️ Konfigurasi zona DNS..."
cat <<EOF > /etc/bind/named.conf.default-zones
// prime the server with knowledge of the root servers
zone "." {
    type hint;
    file "/usr/share/dns/root.hints";
};

// be authoritative for the localhost forward and reverse zones, and for
// broadcast zones as per RFC 1912

zone "adrian.kasir" {
    type master;
    file "/etc/bind/db.domain";
};

zone "30.202.192.in-addr.arpa" {
    type master;
    file "/etc/bind/db.ip";
};

zone "0.in-addr.arpa" {
    type master;
    file "/etc/bind/db.0";
};

zone "255.in-addr.arpa" {
    type master;
    file "/etc/bind/db.255";
};
EOF

cat <<EOF > /etc/bind/db.domain
;
; BIND data file for local loopback interface
;
\$TTL 	604800
@	IN	SOA	adrian.kasir. root.adrian.kasir. (
			      2       	; Serial
			 604800		; Refresh
			  86400		; Retry
			2419200		; Expire
			 604800	)	; Negative Cache TTL
;
@	IN	NS	adrian.kasir.
@	IN	A	192.202.30.2
EOF

cat <<EOF > /etc/bind/db.ip
;
; BIND data file for local loopback interface
;
\$TTL 	604800
@   	IN  	SOA 	adrian.kasir. root.adrian.kasir. (
        		     1		; Serial
        		604800		; Refresh
        		86400		; Retry
        		2419200		; Expire
        		604800 )	; Negative Cache TTL
;
@	IN  	NS 	adrian.kasir.
2	IN  	PTR 	adrian.kasir.
EOF

echo "✅ Validasi konfigurasi DNS..."
named-checkconf
named-checkzone adrian.kasir /etc/bind/db.domain || echo "❌ Konfigurasi zona DNS adrian.kasir salah!"
named-checkzone 30.202.192.in-addr.arpa /etc/bind/db.ip || echo "❌ Konfigurasi zona PTR salah!"
systemctl restart bind9

echo "🔧 Konfigurasi DNS Resolver..."
systemctl stop systemd-resolved
systemctl disable systemd-resolved
systemctl mask systemd-resolved
rm -f /etc/resolv.conf
cat <<EOF > /etc/resolv.conf
nameserver 192.202.30.2
nameserver 192.202.30.1
EOF
chattr +i /etc/resolv.conf

echo "🔍 Test DNS dengan nslookup..."
nslookup adrian.kasir || echo "❌ DNS lookup gagal! Cek konfigurasi Bind9."
nslookup 192.202.30.2 || echo "❌ DNS lookup gagal! Cek resolv.conf."

echo "🗄️ Konfigurasi database MariaDB..."
systemctl restart mariadb
sleep 2

mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '123';"
mysql -u root -p123 -e "CREATE DATABASE IF NOT EXISTS db_kasir;"
mysql -u root -p123 -e "DELETE FROM mysql.user WHERE User='';"
mysql -u root -p123 -e "DROP DATABASE IF EXISTS test;"
mysql -u root -p123 -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';"
mysql -u root -p123 -e "FLUSH PRIVILEGES;"

echo "⬇️ Download dan konfigurasi aplikasi POS..."
cd /var/www/html
rm -f index.html
wget --timeout=10 -q --show-progress --tries=3 -O pos.zip https://fnoor.my.id/app/pos.zip
unzip -o pos.zip -d /var/www/html/
rm -f pos.zip

if [ -f "/var/www/html/db_toko.sql" ]; then
    mysql -u root -p123 db_kasir < /var/www/html/db_toko.sql
    echo "✅ Database berhasil diimpor!"
else
    echo "❌ File db_toko.sql tidak ditemukan!"
fi

echo "📜 Konfigurasi file PHP..."
cat <<EOF > /var/www/html/config.php
<?php
date_default_timezone_set("Asia/Jakarta");
error_reporting(0);

\$host   = 'localhost';
\$user   = 'root';
\$pass   = '123';
\$dbname = 'db_kasir';

try {
    \$config = new PDO("mysql:host=\$host;dbname=\$dbname;", \$user,\$pass);
} catch(PDOException \$e) {
    echo 'KONEKSI GAGAL: ' . \$e->getMessage();
}
?>
EOF

chown -R www-data:www-data /var/www/html/
chmod -R 755 /var/www/html/

echo "🔄 Restart layanan web server..."
systemctl restart apache2

ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 53/tcp
ufw allow 53/udp
ufw enable

echo "✅ Setup selesai!"