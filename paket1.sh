#!/bin/bash

# Pastikan script dijalankan sebagai root
if [[ $EUID -ne 0 ]]; then
   echo "Script ini harus dijalankan sebagai root!" 
   exit 1
fi

echo "Konfigurasi jaringan..."
cat <<EOF > /etc/netplan/00-installer-config.yaml
network:
  ethernets:
    enp0s3:
      addresses:
        - 192.200.30.2/30
      nameservers:
        addresses:
          - 192.200.30.2
          - 192.200.30.1
      routes:
        - to: default
          via: 192.200.30.1
  version: 2
EOF

netplan apply

echo "Update dan install BIND9..."
apt update -y
apt-get install bind9 -y

echo "Konfigurasi zona DNS..."
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

zone "30.200.192.in-addr.arpa" {
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

cp /etc/bind/db.local /etc/bind/db.domain
cat <<EOF > /etc/bind/db.domain
;
; BIND data file for local loopback interface
;
$TTL	604800
@	IN	SOA	adrian.kasir. root.adrian.kasir. (
			      2       	; Serial
			 604800		; Refresh
			  86400		; Retry
			2419200		; Expire
			 604800	)	; Negative Cache TTL
;
@	IN	NS	adrian.kasir.
@	IN	A	192.200.30.2
EOF

cp /etc/bind/db.127 /etc/bind/db.ip
cat <<EOF > /etc/bind/db.ip
;
; BIND data file for local loopback interface
;
$TTL	604800
@	IN	SOA	adrian.kasir. root.adrian.kasir. (
			      1		; Serial
			 604800		; Refresh
			  86400		; Retry
			2419200		; Expire
			 604800 )	; Negative Cache TTL
;
@	IN	NS	adrian.kasir.
2	IN	PTR	adrian.kasir.
EOF

service bind9 restart

echo "Konfigurasi resolv.conf..."
cat <<EOF > /etc/resolv.conf
nameserver 192.200.30.2
nameserver 192.200.30.1
EOF

echo "Test DNS dengan nslookup..."
nslookup adrian.kasir

echo "Instalasi Apache, PHP, dan MariaDB..."
apt-get install apache2 php php-mysql php-cli php-cgi php-gd mariadb-server unzip -y

echo "Konfigurasi database..."
mysql -e "CREATE DATABASE db_kasir;"
mysql_secure_installation <<EOF

Y
Y
123
123
Y
Y
Y
Y
EOF

echo "Download dan konfigurasi aplikasi POS..."
cd /var/www/html
rm index.html
wget https://fnoor.my.id/app/pos.zip
unzip pos.zip
mysql db_kasir < db_toko.sql

echo "Konfigurasi file PHP..."
cat <<EOF > /var/www/html/config.php
<?php
date_default_timezone_set("Asia/Jakarta");
error_reporting(0);

\$host = "localhost";
\$user = "root";
\$pass = "123";
\$dbname = "db_kasir";

try {
    \$config = new PDO("mysql:host=\$host;dbname=\$dbname", \$user, \$pass);
} catch (PDOException \$e) {
    echo "KONEKSI GAGAL: " . \$e->getMessage();
}

\$view = "fungsi/view/view.php";
?>
EOF

echo "Mengatur izin direktori web..."
chown -R www-data:www-data /var/www/html/

echo "Setup selesai! Silakan cek konfigurasi Anda."
