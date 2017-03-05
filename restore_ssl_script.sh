#!/bin/bash

clear

source ~/vars.sh

yum update -y

#install packages
yum install httpd \
            mariadb-server  \
            mariadb \
            php \
            php-mysql \
            php-gd \
            python-dateutil \
            firewalld \
            epel-release -y

#install varnish
yum install varnish -y

#install nginx
yum install nginx -y

#install certbot
yum install certbot -y

#start apache
systemctl start httpd.service

#set apache to start when server is booted
systemctl enable httpd.service

#start mariadb service
systemctl start mariadb

#set mariadb to start when server is booted
systemctl enable mariadb.service

#install firewalld
systemctl start firewalld

#start and enable varnish
systemctl start varnish
systemctl enable varnish

###############################################################
#firewalld settings
#set firewall for apache on port 80
firewall-cmd --zone=public --add-port=80/tcp --permanent
firewall-cmd --reload

#set firewall permissions for mariadb
firewall-cmd --permanent --zone=public --add-service=http
firewall-cmd --permanent --zone=public --add-service=https
firewall-cmd --add-port 3306/tcp --permanent

#reload firewall to apply changes
firewall-cmd --reload
###############################################################

#restart apache to apply changes
systemctl restart httpd.service

cd ~

#create .my.cnf for passwordless database login
echo "[client]" >> .my.cnf
echo "user = root" >> .my.cnf

#random password generation
RAND_PASS=$(date +%s | sha256sum | base64 | head -c 32)

#set mysql root password
mysqladmin -u root password "$RAND_PASS"

#place new password in .my.cnf for passwordless login
echo "password = $RAND_PASS" >> .my.cnf

#change privileges on .my.cnf file
chmod 0600 .my.cnf

#######################################################################
#automating mysql_secure_installation items
mysql -e "DROP USER ''@'localhost';"
mysql -e "DROP USER ''@'$(hostname)';"
mysql -e "DELETE FROM mysql.user WHERE USER='';"
mysql -e "DELETE FROM mysql.user WHERE USER='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
mysql -e "DROP DATABASE test;"
mysql -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\_%';"
mysql -e "FLUSH PRIVILEGES;"
######################################################################

#Install s3cmd for backups to dreamObjects
mkdir ~/bin
curl -O -L https://github.com/s3tools/s3cmd/archive/v1.6.1.tar.gz

#untar the file
tar xzf v1.6.1.tar.gz

#change into the directory that was created upon unzipping
cd s3cmd-1.6.1

#copy s3cmd and S3 directories into the bin folder initially created for s3cmd
cp -R s3cmd S3 /opt/

cd ~

#add symlink to /usr/bin
ln -s /opt/s3cmd /usr/bin
ln -s /opt/S3 /usr/bin


#######################################################################
#create the .s3cfg file and enter some information - assuming dreamobjects
echo "[default]" >> .s3cfg
echo "access_key = $ACCESS_KEY" >> .s3cfg
echo "secret_key = $SECRET_KEY" >> .s3cfg
echo "host_base = objects-us-west-1.dream.io" >> .s3cfg
echo "host_bucket = %(bucket)s.objects-us-west-1.dream.io" >> .s3cfg
echo "enable_multipart = True" >> .s3cfg
echo "multipart_chunk_size_mb = 15" >> .s3cfg
echo "use_https = True" >> .s3cfg
#########################################################################

#change permissions on .s3cfg file
chmod 0600 .s3cfg

#install wp-cli
curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar

#make file executable
chmod +x wp-cli.phar

#move the file to a folder so that you can execute it from anywhere
mv wp-cli.phar /usr/local/bin/wp

#Backup website using s3cmd
#wildcard to retrieve whatever object is in the bucket
s3cmd get $BUCKET_NAME/*.tar

#untar the file
tar xf *.tar

#untar and unzip backup.tgz
tar zxf *.tgz

#unzip db_backup.sql.gz
gunzip *.sql.gz

#create the database to import your files to
mysql -e "CREATE DATABASE $DATABASE_NAME;"

#import database backup into mysql
mysql $DATABASE_NAME < db_backup.sql

#mysql section - create database and user - set privileges for user
mysql -e "CREATE USER $USERNAME@'%' IDENTIFIED BY '$DATABASE_PASSWORD';"
mysql -e "GRANT ALL PRIVILEGES ON $DATABASE_NAME.* TO $USERNAME@'%' IDENTIFIED BY '$DATABASE_PASSWORD';"
mysql -e "FLUSH PRIVILEGES;"

#create backups user
useradd backups

USER_PASS=$(date +%s | sha256sum | base64 | head -c 32)

echo "backups:$USER_PASS" | chpasswd

echo "[client]" >> /home/backups/.my.cnf
echo "user = backups" >> /home/backups/.my.cnf
echo "password = $USER_PASS" >> /home/backups/.my.cnf

#set permissions on backups .my.cnf file
chmod 0600 /home/backups/.my.cnf
chown backups:backups /home/backups/.my.cnf

#add mysql backups user
mysql -e "CREATE USER backups@localhost IDENTIFIED BY '$USER_PASS';"
mysql -e "GRANT SELECT, LOCK TABLES on $DATABASE_NAME.* TO backups@localhost IDENTIFIED BY '$USER_PASS';"
mysql -e "FLUSH PRIVILEGES;"

#####################################################################
#create backups file - refer to backup script for details
#in order to echo variables into a file, escape the $ out
echo '#!/bin/bash' >> /home/backups/backup.sh
echo "source ./vars.sh" >> /home/backups/backup.sh
echo "TEMP_DIR=\$(mktemp -d)" >> /home/backups/backup.sh
echo "DEST=\$TEMP_DIR" >> /home/backups/backup.sh
echo "ARCHIVE_FILE=\"backup.tgz\"" >> /home/backups/backup.sh
echo "tar -czf \$DEST/\$ARCHIVE_FILE \$DOCROOT \${DB_CONFIG[*]} \${WEB_SERVER_CONFIG[*]} \$VARNISH \$NGINX" >> /home/backups/backup.sh
echo "NOW=\$(date +%s)" >> /home/backups/backup.sh
echo "FILENAME=\"db_backup\"" >> /home/backups/backup.sh
echo "BACKUP_FOLDER=\"\$DEST\"" >> /home/backups/backup.sh
echo "FULLPATHBACKUPFILE=\"\$BACKUP_FOLDER/\$FILENAME\"" >> /home/backups/backup.sh
echo "mysqldump \$DATABASE_NAME | gzip > \$BACKUP_FOLDER/\$FILENAME.sql.gz" >> /home/backups/backup.sh
echo "cd \$DEST" >> /home/backups/backup.sh
echo "tar -cf backup_complete_\$NOW.tar \$ARCHIVE_FILE \$FILENAME.sql.gz" >> /home/backups/backup.sh
echo "rm \$DEST/\$ARCHIVE_FILE" >> /home/backups/backup.sh
echo "rm \$DEST/\$FILENAME.sql.gz" >> /home/backups/backup.sh
echo "cd ~" >> /home/backups/backup.sh
echo "s3cmd put \$DEST/backup_complete_\$NOW.tar \$BUCKET_NAME" >> /home/backups/backup.sh
echo "rm -r \$DEST" >> /home/backups/backup.sh
######################################################################

chmod +x /home/backups/backup.sh

#put your vars.sh file into backups home folder for use when running backup Script
cp vars.sh /home/backups

#do the same for the s3config file
cp .s3cfg /home/backups
chown backups:backups /home/backups/.s3cfg

#copy files from bucket into proper places
cp -rf $BACKUP_FROM_BUCKET_DOCROOT /var/www/
cp -rf $BACKUP_FROM_BUCKET_DB_CONFIG_1 /etc/
cp -rf $BACKUP_FROM_BUCKET_DB_CONFIG_2 /etc/
cp -rf $BACKUP_FROM_BUCKET_WSC_1 /etc/httpd/
cp -rf $BACKUP_FROM_BUCKET_WSC_2 /etc/httpd/
cp -rf $BACKUP_FROM_BUCKET_WSC_3 /etc/httpd/
cp -rf $BACKUP_FROM_BUCKET_VARNISH /etc/

#restart apache
systemctl restart httpd

#Automate backups
echo "0  12  *  *  fri backups /home/backups/backup.sh" >> /etc/crontab


######################################################################
#create wp update file - see WP Update Script for details
echo '#!/bin/bash' >> /home/backups/wp-update.sh
echo "source ./vars.sh" >> /home/backups/wp-update.sh
echo "cd \$WORDPRESS_LOCATION" >> /home/backups/wp-update.sh
echo "/usr/local/bin/wp core update" >> /home/backups/wp-update.sh
echo "/usr/local/bin/wp plugin update --all" >> /home/backups/wp-update.sh
######################################################################

chmod +x /home/backups/wp-update.sh

#Automate wp updates if you'd like
echo "0  0  *  *  * backups /home/backups/wp-update.sh" >> /etc/crontab

#permission settings for apache
cd $WORDPRESS_LOCATION

chown apache wp-cron.php

cd $WORDPRESS_LOCATION/wp-content
chown apache -R uploads

cd ~

#need to get port 80 back for varnish so certbot can access website
sed -ie "s/$PORT/80/g" /etc/varnish/varnish.params

#restart varnish last
systemctl restart varnish

#generate ssl certificate
certbot certonly --non-interactive --agree-tos --email $EMAIL -d $WEBSITE --webroot -w $FULL_DOCROOT --staging

#backup nginx conf file
cp -rf $BACKUP_FROM_BUCKET_NGINX /etc/

#semanage ports - selinux
semanage port -m -t varnishd_port_t -p tcp $PORT
setsebool -P httpd_can_network_connect 1

#add auto renew to crontab
echo "0  12  *  *  sun root certbot renew --pre-hook \"systemctl stop nginx\" --post-hook \"systemctl start nginx\"" >> /etc/crontab

#remove the mess
rm -rf *.tar
rm -rf *.tgz
rm -rf *.tar.gz
rm -rf *.sql
rm -rf var/
rm -rf etc/

#put port back to desired for varnish
sed -ie "s/80/$PORT/g" /etc/varnish/varnish.params

#restart varnish last
systemctl restart varnish

#restart nginx lastest
systemctl start nginx
systemctl enable nginx
