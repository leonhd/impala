#!/bin/bash

# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

# This script bootstraps a system for Impala development from almost nothing; it is known
# to work on Ubuntu 16.04. It clobbers some local environment and system
# configurations, so it is best to run this in a fresh install. It also sets up the
# ~/.bashrc for the calling user and impala-config-local.sh with some environment
# variables to make Impala compile and run after this script is complete.
# When IMPALA_HOME is set, the script will bootstrap Impala development in the
# location specified.
#
# The intended user is a person who wants to start contributing code to Impala. This
# script serves as an executable reference point for how to get started.
#
# To run this in a Docker container:
#
#   1. Run with --privileged
#   2. Give the container a non-root sudoer wih NOPASSWD:
#      apt-get update
#      apt-get install sudo
#      adduser --disabled-password --gecos '' impdev
#      echo 'impdev ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers
#   3. Run this script as that user: su - impdev -c /bootstrap_development.sh

set -eu -o pipefail

: ${IMPALA_HOME:=~/Impala}

if [[ -t 1 ]] # if on an interactive terminal
then
  echo "This script will clobber some system settings. Are you sure you want to"
  echo -n "continue? "
  while true
  do
    read -p "[yes/no] " ANSWER
    ANSWER=$(echo "$ANSWER" | tr /a-z/ /A-Z/)
    if [[ $ANSWER = YES ]]
    then
      break
    elif [[ $ANSWER = NO ]]
    then
      echo "OK, Bye!"
      exit 1
    fi
  done
else
  export DEBIAN_FRONTEND=noninteractive
fi

set -x

# Determine whether we're running on redhat or ubuntu
REDHAT=
UBUNTU=
if [[ -f /etc/redhat-release ]]; then
  REDHAT=true
  # TODO: restrict redhat versions
else
  source /etc/lsb-release
  if ! [[ $DISTRIB_ID = Ubuntu ]]
  then
    echo "This script only supports Ubuntu or RedHat" >&2
    exit 1
  fi

  if ! [[ $DISTRIB_RELEASE = 16.04 ]]
  then
    echo "This script only supports 16.04 of Ubuntu" >&2
    exit 1
  fi
  UBUNTU=true
fi

# Helper function to execute following command only on Ubuntu
function ubuntu {
  if [[ "$UBUNTU" == true ]]; then
    "$@"
  fi
}

# Helper function to execute following command only on RedHat
function redhat {
  if [[ "$REDHAT" == true ]]; then
    "$@"
  fi
}

# Note that yum has its own retries; see yum.conf(5).
REAL_APT_GET=$(ubuntu which apt-get)
function apt-get {
  for ITER in $(seq 1 20); do
    echo "ATTEMPT: ${ITER}"
    if sudo -E "${REAL_APT_GET}" "$@"
    then
      return 0
    fi
    sleep "${ITER}"
  done
  echo "NO MORE RETRIES"
  return 1
}

echo ">>> Installing build tools"
ubuntu apt-get update
ubuntu apt-get --yes install ccache g++ gcc libffi-dev liblzo2-dev libkrb5-dev \
        krb5-admin-server krb5-kdc krb5-user libsasl2-dev libsasl2-modules \
        libsasl2-modules-gssapi-mit libssl-dev make maven ninja-build ntp \
        ntpdate python-dev python-setuptools postgresql ssh wget vim-common psmisc \
        lsof openjdk-8-jdk openjdk-8-source openjdk-8-dbg apt-utils git

if [[ "$UBUNTU" == true ]]; then
  # Don't use openjdk-8-jdk 8u181-b13-1ubuntu0.16.04.1 which is known to break the
  # surefire tests. If we detect that version, we downgrade to the last known good one.
  # See https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=911925 for details.
  JDK_BAD_VERSION="8u181-b13-1ubuntu0.16.04.1"
  if dpkg -l openjdk-8-jdk | grep -q $JDK_BAD_VERSION; then
    JDK_TARGET_VERSION="8u181-b13-0ubuntu0.16.04.1"
    DEB_DIR=$(mktemp -d)
    pushd $DEB_DIR
    wget --no-verbose \
        "https://launchpadlibrarian.net/380913637/openjdk-8-jdk_8u181-b13-0ubuntu0.16.04.1_amd64.deb" \
        "https://launchpadlibrarian.net/380913636/openjdk-8-jdk-headless_8u181-b13-0ubuntu0.16.04.1_amd64.deb" \
        "https://launchpadlibrarian.net/380913641/openjdk-8-jre_8u181-b13-0ubuntu0.16.04.1_amd64.deb" \
        "https://launchpadlibrarian.net/380913638/openjdk-8-jre-headless_8u181-b13-0ubuntu0.16.04.1_amd64.deb" \
        "https://launchpadlibrarian.net/380913642/openjdk-8-source_8u181-b13-0ubuntu0.16.04.1_all.deb" \
        "https://launchpadlibrarian.net/380913633/openjdk-8-dbg_8u181-b13-0ubuntu0.16.04.1_amd64.deb"
    sudo dpkg -i *.deb
    popd
    rm -rf $DEB_DIR
  fi
fi


redhat sudo yum install -y curl gcc gcc-c++ git krb5-devel krb5-server krb5-workstation \
        libevent-devel libffi-devel make ntp ntpdate openssl-devel cyrus-sasl \
        cyrus-sasl-gssapi cyrus-sasl-devel cyrus-sasl-plain \
        python-devel python-setuptools postgresql postgresql-server \
        wget vim-common nscd cmake lzo-devel fuse-devel snappy-devel zlib-devel \
        psmisc lsof openssh-server redhat-lsb java-1.8.0-openjdk-devel \
        java-1.8.0-openjdk-src python-argparse

# CentOS repos don't contain ccache, so install from EPEL
redhat sudo yum install -y epel-release
redhat sudo yum install -y ccache

# Clean up yum caches
redhat sudo yum clean all

# Download ant and mvn for centos
redhat sudo wget -nv \
  https://www-us.apache.org/dist/maven/maven-3/3.5.4/binaries/apache-maven-3.5.4-bin.tar.gz \
  https://www-us.apache.org/dist/ant/binaries/apache-ant-1.9.13-bin.tar.gz
redhat sha512sum -c - <<< '2a803f578f341e164f6753e410413d16ab60fabe31dc491d1fe35c984a5cce696bc71f57757d4538fe7738be04065a216f3ebad4ef7e0ce1bb4c51bc36d6be86  apache-maven-3.5.4-bin.tar.gz'
redhat sha512sum -c - <<< 'c8321aa223f70d7e64d3d0274263000cfffb46fbea61488534e26f9f0245d99e9872d0888e35cd3274416392a13f80c748c07750caaeffa5f9cae1220020715f  apache-ant-1.9.13-bin.tar.gz'
redhat sudo tar -C /usr/local -xzf apache-maven-3.5.4-bin.tar.gz
redhat sudo tar -C /usr/local -xzf apache-ant-1.9.13-bin.tar.gz
redhat sudo ln -s /usr/local/apache-maven-3.5.4/bin/mvn /usr/local/bin
redhat sudo ln -s /usr/local/apache-ant-1.9.13/bin/ant /usr/local/bin

if ! { service --status-all | grep -E '^ \[ \+ \]  ssh$'; }
then
  ubuntu sudo service ssh start
  # TODO: CentOS/RH 7 uses systemd, and this doesn't work.
  redhat sudo service sshd start
fi

# TODO: config ccache to give it plenty of space
# TODO: check that there is enough space on disk to do a build and data load
# TODO: make this work with non-bash shells

echo ">>> Configuring system"

ubuntu sudo service ntp stop
redhat sudo service ntpd stop
sudo ntpdate us.pool.ntp.org
# If on EC2, use Amazon's ntp servers
if which dmidecode && { sudo dmidecode -s bios-version | grep amazon; }
then
  sudo sed -i 's/ubuntu\.pool/amazon\.pool/' /etc/ntp.conf
  grep amazon /etc/ntp.conf
  grep ubuntu /etc/ntp.conf
fi
# While it is nice to have ntpd running to keep the clock in sync, that does not work in a
# --privileged docker container, and a non-privileged container cannot run ntpdate, which
# is strictly needed by Kudu.
# TODO: Make privileged docker start ntpd
ubuntu sudo service ntp start || grep docker /proc/1/cgroup
redhat sudo service ntpd start || grep docker /proc/1/cgroup

# IMPALA-3932, IMPALA-3926
if [[ $UBUNTU = true && $DISTRIB_RELEASE = 16.04 ]]
then
  SET_LD_LIBRARY_PATH='export LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu/${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}'
  echo "$SET_LD_LIBRARY_PATH" >> "${IMPALA_HOME}/bin/impala-config-local.sh"
  eval "$SET_LD_LIBRARY_PATH"
fi

redhat sudo service postgresql initdb
sudo service postgresql stop

# These configurations expose connectiong to PostgreSQL via md5-hashed
# passwords over TCP to localhost, and the local socket is trusted
# widely.
ubuntu sudo sed -ri 's/local +all +all +peer/local all all trust/g' \
  /etc/postgresql/*/main/pg_hba.conf
redhat sudo sed -ri 's/local +all +all +ident/local all all trust/g' \
  /var/lib/pgsql/data/pg_hba.conf
# Accept md5 passwords from localhost
redhat sudo sed -i -e 's,\(host.*\)ident,\1md5,' /var/lib/pgsql/data/pg_hba.conf

sudo service postgresql start

# Set up postgress for HMS
if ! [[ 1 = $(sudo -u postgres psql -At -c "SELECT count(*) FROM pg_roles WHERE rolname = 'hiveuser';") ]]
then
  sudo -u postgres psql -c "CREATE ROLE hiveuser LOGIN PASSWORD 'password';"
fi
sudo -u postgres psql -c "ALTER ROLE hiveuser WITH CREATEDB;"
sudo -u postgres psql -c "SELECT * FROM pg_roles WHERE rolname = 'hiveuser';"

# Setup ssh to ssh to localhost
mkdir -p ~/.ssh
chmod go-rwx ~/.ssh
if ! [[ -f ~/.ssh/id_rsa ]]
then
  ssh-keygen -t rsa -N '' -q -f ~/.ssh/id_rsa
fi
cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
echo "NoHostAuthenticationForLocalhost yes" >> ~/.ssh/config
ssh localhost whoami

# Workarounds for HDFS networking issues: On the minicluster, tests that rely
# on WebHDFS may fail with "Connection refused" errors because the namenode
# will return a "Location:" redirect to the hostname, but the datanode is only
# listening on localhost. See also HDFS-13797. To reproduce this, the following
# snippet may be useful:
#
#  $impala-python
#  >>> import logging
#  >>> logging.basicConfig(level=logging.DEBUG)
#  >>> logging.getLogger("requests.packages.urllib3").setLevel(logging.DEBUG)
#  >>> from pywebhdfs.webhdfs import PyWebHdfsClient
#  >>> PyWebHdfsClient(host='localhost',port='5070', user_name='hdfs').read_file(
#         "/test-warehouse/tpch.region/region.tbl")
#  INFO:...:Starting new HTTP connection (1): localhost
#  DEBUG:...:"GET /webhdfs/v1//t....tbl?op=OPEN&user.name=hdfs HTTP/1.1" 307 0
#  INFO:...:Starting new HTTP connection (1): HOSTNAME.DOMAIN
#  Traceback (most recent call last):
#    ...
#  ...ConnectionError: ('Connection aborted.', error(111, 'Connection refused'))
echo "127.0.0.1 $(hostname -s) $(hostname)" | sudo tee -a /etc/hosts
#
# In Docker, one can change /etc/hosts as above but not with sed -i. The error message is
# "sed: cannot rename /etc/sedc3gPj8: Device or resource busy". The following lines are
# basically sed -i but with cp instead of mv for -i part.
NEW_HOSTS=$(mktemp)
sed 's/127.0.1.1/127.0.0.1/g' /etc/hosts > "${NEW_HOSTS}"
diff -u /etc/hosts "${NEW_HOSTS}" || true
sudo cp "${NEW_HOSTS}" /etc/hosts
rm "${NEW_HOSTS}"

sudo mkdir -p /var/lib/hadoop-hdfs
sudo chown $(whoami) /var/lib/hadoop-hdfs/

# TODO: restrict this to only the users it is needed for
echo "* - nofile 1048576" | sudo tee -a /etc/security/limits.conf

# Default on CentOS limits a user to 1024 processes (threads) , which isn't
# enough for minicluster with all of its friends.
redhat sudo sed -i 's,\*\s*soft\s*nproc\s*1024,* soft nproc unlimited,' \
  /etc/security/limits.d/90-nproc.conf

echo ">>> Checking out Impala"

# If there is no Impala git repo, get one now
if ! [[ -d "$IMPALA_HOME" ]]
then
  time -p git clone https://git-wip-us.apache.org/repos/asf/impala.git "$IMPALA_HOME"
fi
cd "$IMPALA_HOME"
SET_IMPALA_HOME="export IMPALA_HOME=$(pwd)"
echo "$SET_IMPALA_HOME" >> ~/.bashrc
eval "$SET_IMPALA_HOME"

# Ubuntu and RH install JDK's in slightly different paths.
if [[ $UBUNTU == true ]]; then
  SET_JAVA_HOME="export JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64"
else
  # Assert that there's only one glob match.
  [ 1 == $(compgen -G "/usr/lib/jvm/java-1.8.0-openjdk-*" | wc -l) ]
  SET_JAVA_HOME="export JAVA_HOME=$(compgen -G '/usr/lib/jvm/java-1.8.0-openjdk-*')"
fi

echo "$SET_JAVA_HOME" >> "${IMPALA_HOME}/bin/impala-config-local.sh"
eval "$SET_JAVA_HOME"

# Assert that we have a java available
test -f $JAVA_HOME/bin/java

# LZO is not needed to compile or run Impala, but it is needed for the data load
echo ">>> Checking out Impala-lzo"
: ${IMPALA_LZO_HOME:="${IMPALA_HOME}/../Impala-lzo"}
if ! [[ -d "$IMPALA_LZO_HOME" ]]
then
  git clone https://github.com/cloudera/impala-lzo.git "$IMPALA_LZO_HOME"
fi

echo ">>> Checking out and building hadoop-lzo"

: ${HADOOP_LZO_HOME:="${IMPALA_HOME}/../hadoop-lzo"}
if ! [[ -d "$HADOOP_LZO_HOME" ]]
then
  git clone https://github.com/cloudera/hadoop-lzo.git "$HADOOP_LZO_HOME"
fi
cd "$HADOOP_LZO_HOME"
time -p ant package
cd "$IMPALA_HOME"
