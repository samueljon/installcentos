#!/bin/bash

## see: https://youtu.be/aqXSbDZggK4

## Default variables to use
export INTERACTIVE=${INTERACTIVE:="true"}
export PVS=${INTERACTIVE:="true"}
export DOMAIN=${DOMAIN:="$(curl -s ipinfo.io/ip).nip.io"}
export USERNAME=${USERNAME:="$(whoami)"}
export PASSWORD=${PASSWORD:=password}
export VERSION=${VERSION:="3.11"}
export SCRIPT_REPO=${SCRIPT_REPO:="https://raw.githubusercontent.com/gshipley/installcentos/master"}
export IP=${IP:="$(ip route get 8.8.8.8 | awk '{print $NF; exit}')"}
export API_PORT=${API_PORT:="8443"}

# Add confirm logic 
confirm () {
    # call with a prompt string or use a default
    read -r -p "${1:-Are you sure? [y/N]} " response
    case $response in
        [yY][eE][sS]|[yY])
            true
            ;;
        *)
            false
            ;;
    esac
}

letsencrypt_console() {
	export LETSENCRYPT_CONSOLE="true"
}

letsencrypt_router() {
	export LETSENCRYPT_ROUTER="true"
}

## Make the script interactive to set the variables
if [ "$INTERACTIVE" = "true" ]; then
	read -rp "Domain to use: ($DOMAIN): " choice;
	if [ "$choice" != "" ] ; then
		export DOMAIN="$choice";
	fi

	read -rp "Username: ($USERNAME): " choice;
	if [ "$choice" != "" ] ; then
		export USERNAME="$choice";
	fi

	read -rp "Password: ($PASSWORD): " choice;
	if [ "$choice" != "" ] ; then
		export PASSWORD="$choice";
	fi

	read -rp "OpenShift Version: ($VERSION): " choice;
	if [ "$choice" != "" ] ; then
		export VERSION="$choice";
	fi
	read -rp "IP: ($IP): " choice;
	if [ "$choice" != "" ] ; then
		export IP="$choice";
	fi

	read -rp "API Port: ($API_PORT): " choice;
	if [ "$choice" != "" ] ; then
		export API_PORT="$choice";
	fi 

	confirm "Use Let's encrypt wildcard certificate for console and router ? [y/N]" && letsencrypt_console
	#confirm "Use Let's encrypt certificate for router ( *.apps.$DOMAIN ) ? [y/N]" && letsencrypt_router

	echo

fi

echo "******"
echo "* Your domain is $DOMAIN "
echo "* Your IP is $IP "
echo "* Your username is $USERNAME "
echo "* Your password is $PASSWORD "
echo "* OpenShift version: $VERSION "
echo "******"

# install updates
yum update -y

# install the following base packages
yum install -y  wget git zile nano net-tools docker-1.13.1\
				bind-utils iptables-services \
				bridge-utils bash-completion \
				kexec-tools sos psacct openssl-devel \
				httpd-tools NetworkManager \
				python-cryptography python2-pip python-devel  python-passlib \
				java-1.8.0-openjdk-headless "@Development Tools"

#install epel
yum -y install epel-release

# Install certbot if Let's encrypt is selected
if [ "$LETSENCRYPT_CONSOLE" = "true" ] || [  "$LETSENCRYPT_ROUTER" = "true" ]; then
    echo "Installing Let's encrypt CertBot" 
    yum install --enablerepo epel -y certbot 
fi


# Disable the EPEL repository globally so that is not accidentally used during later steps of the installation
sed -i -e "s/^enabled=1/enabled=0/" /etc/yum.repos.d/epel.repo

systemctl | grep "NetworkManager.*running" 
if [ $? -eq 1 ]; then
	systemctl start NetworkManager
	systemctl enable NetworkManager
fi

# install the packages for Ansible
yum -y --enablerepo=epel install pyOpenSSL

curl -o ansible.rpm https://releases.ansible.com/ansible/rpm/release/epel-7-x86_64/ansible-2.6.5-1.el7.ans.noarch.rpm
yum -y --enablerepo=epel install ansible.rpm

[ ! -d openshift-ansible ] && git clone https://github.com/openshift/openshift-ansible.git

cd openshift-ansible && git fetch && git checkout release-${VERSION} && cd ..

cat <<EOD > /etc/hosts
127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4 
::1         localhost localhost.localdomain localhost6 localhost6.localdomain6
${IP}		$(hostname) console console.${DOMAIN}  
EOD

if [ -z $DISK ]; then 
	echo "Not setting the Docker storage."
else
	cp /etc/sysconfig/docker-storage-setup /etc/sysconfig/docker-storage-setup.bk

	echo DEVS=$DISK > /etc/sysconfig/docker-storage-setup
	echo VG=DOCKER >> /etc/sysconfig/docker-storage-setup
	echo SETUP_LVM_THIN_POOL=yes >> /etc/sysconfig/docker-storage-setup
	echo DATA_SIZE="100%FREE" >> /etc/sysconfig/docker-storage-setup

	systemctl stop docker

	rm -rf /var/lib/docker
	wipefs --all $DISK
	docker-storage-setup
fi

systemctl restart docker
systemctl enable docker

if [ ! -f ~/.ssh/id_rsa ]; then
	ssh-keygen -q -f ~/.ssh/id_rsa -N ""
	cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
	ssh -o StrictHostKeyChecking=no root@$IP "pwd" < /dev/null
fi

export METRICS="True"
export LOGGING="True"

memory=$(cat /proc/meminfo | grep MemTotal | sed "s/MemTotal:[ ]*\([0-9]*\) kB/\1/")

if [ "$memory" -lt "4194304" ]; then
	export METRICS="False"
fi

if [ "$memory" -lt "16777216" ]; then
	export LOGGING="False"
fi

curl -o inventory.download $SCRIPT_REPO/inventory.ini
envsubst < inventory.download > inventory.ini

# Add proxy in inventory.ini if proxy variables are set
if [ ! -z "${HTTPS_PROXY:-${https_proxy:-${HTTP_PROXY:-${http_proxy}}}}" ]; then
	echo >> inventory.ini
	echo "openshift_http_proxy=\"${HTTP_PROXY:-${http_proxy:-${HTTPS_PROXY:-${https_proxy}}}}\"" >> inventory.ini
	echo "openshift_https_proxy=\"${HTTPS_PROXY:-${https_proxy:-${HTTP_PROXY:-${http_proxy}}}}\"" >> inventory.ini
	if [ ! -z "${NO_PROXY:-${no_proxy}}" ]; then
		__no_proxy="${NO_PROXY:-${no_proxy}},${IP},.${DOMAIN}"
	else
		__no_proxy="${IP},.${DOMAIN}"
	fi
	echo "openshift_no_proxy=\"${__no_proxy}\"" >> inventory.ini
fi

# Add lets encrypt certificates if let's encrypt variables are set
if [ "$LETSENCRYPT_CONSOLE" = "true" ] || [  "$LETSENCRYPT_ROUTER" = "true" ]; then

CERT_NAME="${DOMAIN}"

  if [ ! -f /etc/letsencrypt/live/${CERT_NAME}/fullchain.pem ] && [ ! -f /etc/letsencrypt/live/${CERT_NAME}/privkey.pem ]; then
    yum install -y augeas-libs libffi-devel python-tools python-virtualenv 

    wget https://dl.eff.org/certbot-auto
    chmod a+x certbot-auto
    mv certbot-auto /usr/local/bin/
	
    /usr/local/bin/certbot-auto certonly --preferred-challenges dns --manual --cert-name ${CERT_NAME} --server https://acme-v02.api.letsencrypt.org/directory -d "*.${DOMAIN}" -d "*.apps.${DOMAIN}" 

  fi

  echo >> inventory.ini
  echo "# Let's Encrypt Certificates begin " >> inventory.ini
  echo "openshift_master_overwrite_named_certificates=true" >> inventory.ini
  echo "openshift_master_named_certificates=[{\"certfile\": \"/etc/letsencrypt/live/${CERT_NAME}/fullchain.pem\", \"keyfile\": \"/etc/letsencrypt/live/${CERT_NAME}/privkey.pem\", \"names\": [\"console.${DOMAIN}\"] , \"cafile\": \"/etc/letsencrypt/live/${CERT_NAME}/fullchain.pem\"}]" >> inventory.ini
  echo "openshift_hosted_router_certificate={\"certfile\": \"/etc/letsencrypt/live/${CERT_NAME}/fullchain.pem\", \"keyfile\": \"/etc/letsencrypt/live/${CERT_NAME}/privkey.pem\", \"cafile\": \"/etc/letsencrypt/live/${CERT_NAME}/fullchain.pem}\" }" >> inventory.ini
  echo >> "# Let's Encrypt Certificates end " >> inventory.ini

fi


run_playbook() { 

  mkdir -p /etc/origin/master/
  touch /etc/origin/master/htpasswd

  ansible-playbook -i inventory.ini openshift-ansible/playbooks/prerequisites.yml
  ansible-playbook -i inventory.ini openshift-ansible/playbooks/deploy_cluster.yml

  htpasswd -b /etc/origin/master/htpasswd ${USERNAME} ${PASSWORD}
  oc adm policy add-cluster-role-to-user cluster-admin ${USERNAME}

  if [ "$PVS" = "true" ]; then

	curl -o vol.yaml $SCRIPT_REPO/vol.yaml

	for i in `seq 1 200`;
	do
		DIRNAME="vol$i"
		mkdir -p /mnt/data/$DIRNAME 
		chcon -Rt svirt_sandbox_file_t /mnt/data/$DIRNAME
		chmod 777 /mnt/data/$DIRNAME
		
		sed "s/name: vol/name: vol$i/g" vol.yaml > oc_vol.yaml
		sed -i "s/path: \/mnt\/data\/vol/path: \/mnt\/data\/vol$i/g" oc_vol.yaml
		oc create -f oc_vol.yaml
		echo "created volume $i"
	done
	rm oc_vol.yaml
  fi

  echo "******"
  echo "* Your console is https://console.$DOMAIN:$API_PORT"
  echo "* Your username is $USERNAME "
  echo "* Your password is $PASSWORD "
  echo "*"
  echo "* Login using:"
  echo "*"
  echo "$ oc login -u ${USERNAME} -p ${PASSWORD} https://console.$DOMAIN:$API_PORT/"
  echo "******"

  oc login -u ${USERNAME} -p ${PASSWORD} https://console.$DOMAIN:$API_PORT/
} 

# Add option to edit inventory.ini before running. 
if [ "$INTERACTIVE" = "true" ]; then
  echo 
  echo "######################################" 
  echo 
  confirm "You can now edit inventory.ini if you need to modify. When you are ready to run the playbook press y to continue ? [y/N]" && run_playbook
else 
  run_playbook
fi 


