#!/bin/env bash
## F5
# Script: f5.sh
# Purpose: functions to control F5 pool members for a specific domain
# CB: Nate Werner
# Created: 9/26/2019
#
# Functions:
#
#  disablePoolMember(domainName)
#     Disable pool member matching domainName.  Any error return 1
#  enablePoolMember(domainName)
#     Enable pool member matching domainName.  Any error return 1
#
#  bigip_pool_member:
#    state: forced_offline
#    pool: csdev
#    partition: ENTS
#    host: "{{ host_ip }}"
#    port: 6701
#    provider:
#      server: lb.f5.company.com
#      user: f5user
#      password: secret
#
####

# Standard env setup
if [ -z "$BOOTSTRAP_LOADED" ]; then
  currentPath="$( cd "$(dirname "$0")" && pwd )"
  source ${currentPath%${currentPath#*scripts*/}}library/bootstrap.sh
fi

# load domain tools and utilities
source $LIB_HOME/inventory.sh
source $LIB_HOME/utilities.sh
source $LIB_HOME/security.sh

### Gobal standard f5 Values
F5_POOL_MEMBER="bigip_pool_member"
F5_USER="psoftf5"

# module variables
webHost=""
poolName=""
webHTTPport=""

##### internal helper funtions
function __setAnsibleFile()
{
   ## Setup vault access
   # use env var to get vault pass
   sec::getGenSecurity "vault" vaultPass
   # temporarilly write file for F5 ansible access
   echo "${vaultPass}" > $vaultPassFile
   chmod 600 $vaultPassFile
}

function __setF5Provider()
{

   local f5Pass
   sec::getGenSecurity "f5" f5Pass
   export F5_PASSWORD=$f5Pass
   export F5_USER="$F5_USER"

 }

# Function to format a direct URL to web server
function __getWebSiteInfo() # domainName
{
  local domainName=$1
  local webPurpose
  local webEnv
  local hostseq

  declare -Ag siteDomainInfo

  # get domain details and extract OTD config from it
  inventory::getDomainInfo $domainName "" "" siteDomainInfo

  webHost="${siteDomainInfo[$DOM_ATTR_HOST]}"
  #webIP=$( nslookup $webHost | grep "Address: 10" | awk '{ print $2 }' )
  webPurpose="${siteDomainInfo[$DOM_ATTR_PURPOSE]}"
  webEnv="${siteDomainInfo[$DOM_ATTR_ENV]}"
  if [[ "${siteDomainInfo[$DOM_ATTR_REPORT]}" == "Y" && "$webEnv" == "qat" ]]; then
     webEnv="qrpt"
  fi
  if [[ "${siteDomainInfo[$DOM_ATTR_REPORT]}" == "Y" && "$webEnv" == "prd" ]]; then
     webEnv="rpt"
  fi
  if [[ "$webPurpose" == "trace" ]]; then
     util::log "DEBUG" "Domain $domainName does not use F5 Load Balancing, skipping"
     return 2
  elif [[ "$webPurpose" == "ib" || "$webPurpose" == "ren" ]]; then
     poolName="${siteDomainInfo[$DOM_ATTR_APP]}${siteDomainInfo[$DOM_ATTR_ENV]}${siteDomainInfo[$DOM_ATTR_PURPOSE]}"
  else
     poolName="${siteDomainInfo[$DOM_ATTR_APP]}$webEnv"
  fi
  if [[ "$webPurpose" == "ren" ]]; then
     if [[ "${domainName:(-1)}" == "2" ]]; then
       poolName="${poolName}2"
     fi
     if [[ "$webEnv" == "cls" ]]; then
       poolName="fsclsren"
     fi
  fi

  util::getWebPortforDomain $domainName webHTTPport
  unset siteDomainInfo
}

##### Main F5 functions

function f5::disablePoolMember() # (domainName)
{
   local domainName=$1
   # get domain details and determine if appropriate for F5
   __getWebSiteInfo "$domainName"
   local result=$?
   if [ $result -ne 0 ]; then
     if [ $result -eq 2 ]; then
       # Skip F5
       return 0
     else
       # failed attribute validation or does not apply
       return 1
     fi
   fi
   vaultPassFile="$ANSIBLE_HOME/tmp/${domainName}_vp"
   __setAnsibleFile
   __setF5Provider

   util::log "DEBUG" "f5::disablePoolMember: Running ansible localhost -m ${F5_POOL_MEMBER} -a \"state=forced_offline pool=$poolName partition=$F5_PARTITION fqdn=${webHost}.company.com port=$webHTTPport\""

   local result=$( ansible localhost -m ${F5_POOL_MEMBER} -a "state=forced_offline pool=$poolName partition=$F5_PARTITION fqdn=${webHost}.company.com port=$webHTTPport" --vault-password-file $vaultPassFile )
   local exitcode=$?

   rm $vaultPassFile > /dev/null 2>&1

   util::log "DEBUG" "f5::disablePoolMember: Results: $result"
   if [[ $result = *"SUCCESS"* || $result = *"CHANGED"* ]]; then
      util::log "INFO" "${domainName}: Disabled F5 pool member $webHost:$webHTTPport"
      return 0
   else
      util::log "ERROR" "${domainName}: $exitcode: Unable to disable F5 pool member $webHost:$webHTTPport"
      return 1
   fi
}

function f5::enablePoolMember() # domainName
{
   local domainName=$1
   # get domain details and determine if appropriate for F5
   __getWebSiteInfo "$domainName"
   local result=$?
   if [ $result -ne 0 ]; then
     if [ $result -eq 2 ]; then
       # Skip F5
       return 0
     else
       # failed attribute validation or does not apply
       return 1
     fi
   fi
   vaultPassFile="$ANSIBLE_HOME/tmp/${domainName}_vp"
   __setAnsibleFile
   __setF5Provider

   util::log "DEBUG" "f5::enablePoolMember: Running ansible localhost -m $F5_POOL_MEMBER -a \"state=enabled pool=$poolName partition=$F5_PARTITION fqdn=${webHost}.company.com port=$webHTTPport\""

   local result=$( ansible localhost -m $F5_POOL_MEMBER -a "state=enabled pool=$poolName partition=$F5_PARTITION fqdn=${webHost}.company.com port=$webHTTPport" --vault-password-file $vaultPassFile )
   local exitcode=$?

   rm $vaultPassFile > /dev/null 2>&1

   util::log "DEBUG" "f5::enablePoolMember: Results: $result"
   if [[ $result = *"SUCCESS"* || $result = *"CHANGED"* ]]; then
      util::log "INFO" "${domainName}: Enabled F5 pool member $webHost:$webHTTPport"
      return 0
   else
      util::log "ERROR" "${domainName}: $exitcode: Unable to enable F5 pool member $webHost:$webHTTPport"
      return 1
   fi
}

#  end f5.sh
