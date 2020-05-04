#!/bin/env bash

# BASE_PATH will be applied to PATH when selecting a domain environment
export PS_BASE=/psoft

# PSSA Admin folder
export PS_ADMIN_BASE=$PS_BASE/admin

########
# RHEL7 path order
BASE_PATH=/psoft/.local/bin:/usr/local/bin:/usr/bin:/usr/local/sbin:/usr/sbin:/psoft/bin

# Standard location for all psoft deployed instances
export DOMAIN_BASE=/psoft/domains
# Domain Env scripts and current
BASE_PATH="${DOMAIN_BASE}:.:$BASE_PATH"

# reset these paths to allow Psoft config scripts to be re-runnable
CLASSPATH=; export CLASSPATH
# Lasest openssl software build is in /usr/local/ssl/lib
LD_LIBRARY_PATH=/usr/local/lib:/usr/local/ssl/lib
SHLIB_PATH=; export SHLIB_PATH
JAVA_FONTS=; export JAVA_FONTS
PS_APP_HOME=; export PS_APP_HOME
PS_CUST_HOME=; export PS_CUST_HOME

## setup bash history with date/time
export HISTTIMEFORMAT="%d/%m/%y %T "
export HISTSIZE=8000
# Disable options: remove annoying email notices
shopt -u mailwarn
unset MAILCHECK

# common/default DB Client
export ORACLE_HOME="$PS_BASE/dbclient/product/12.2.0/client_1"
export TNS_ADMIN="$PS_BASE/dbclient/admin/tnsadmin"
export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:$ORACLE_HOME/lib"
export PATH="$ORACLE_HOME/bin:$PATH"

# Ansible setup
if [ -z "$ANSIBLE_HOME" ]; then
  # applies only when ansible is ran from non-psoft user
  ANSIBLE_HOME=$PS_ADMIN_BASE/ansible
  export ANSIBLE_CONFIG=$ANSIBLE_HOME/ansible.cfg; export ANSIBLE_CONFIG
else
  #user work directory, or loading from bootstrap
  export ANSIBLE_CONFIG=$ANSIBLE_HOME/ansible.cfg; export ANSIBLE_CONFIG
fi

## Hide Tuxedo warning message in PIA domains (already loaded in app/sched env scripts)
export LLE_DEPRECATION_WARN_LEVEL=NONE

## RunDeck Env
export RDECK_BASE=$PS_BASE/rundeck/rundeckapp

## force use of ipv4 for RMI servers
export _JAVA_OPTIONS="-Djava.net.preferIPv4Stack=true"
