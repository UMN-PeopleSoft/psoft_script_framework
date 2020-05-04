#!/bin/env bash
# Library: monitor
# Script: monitor.sh
# Purpose: Functions to manage monitoring data for PeopleSoft
# CB: Nate Werner
# Created: 8/18/2018
#
# Functions:
#   startBlackout(domainName, srvrName, durationMins, description)
#     Starts a blackout for target mapped to domainName for a specified duration.  Any failure returns 1.
#   stopBlackout(domainName, srvrName)
#     Stops existing blackout on domain.
#   startBlackoutAppEnv(app, env, durationMins, description)
#     Starts a blackout for target mapped to domainName for a specified duration.  Any failure returns 1.
#   stopBlackoutAppEnv(app, env)
#     Stops existing blackout on domain.
#   isAppEnvInBlackout(app, env)
#     Returns true if app/env is in blackout (exit 0), falase if not (exit 1)
#   isDomainInBlackout(domainName, srvrName)
#
###################################

# load domain tools
source $LIB_HOME/inventory.sh
source $LIB_HOME/security.sh
source $LIB_HOME/utilities.sh

function monitor::startBlackoutAppEnv() # app, env, durationMins, description
{
   local app="$1"
   local env="$2"
   local durationMins=$3
   local blackoutDescr="$4"

   # blackout starts now
   local startBlackoutDateTime=$( date --rfc-3339=seconds | tr ' ' '_' )
   # default to 10 mins
   if [ -z "$durationMins" ]; then
     durationMins=10
   fi
   # calculate end date of blackout, adding specified mins to current date/time
   local endBlackoutDateTime=$( date -d "+${durationMins} minutes" --rfc-3339=seconds | tr ' ' '_' )

   if [ -z "$blackoutDescr" ]; then
     blackoutDescr="Manually stopping ${app}${env} from (stop/cycle)AppEnv command"
   fi

   # First see if there is already a blackout entry, and remove
   # NOTE: new shorter blackout will override existing longer blackout
   monitor::endBlackoutAppEnv "${app}" "${env}"

   # Add official blackout
   echo "ENV:${app}${env}|$endBlackoutDateTime|$blackoutDescr" >> $BLACKOUT_LIST
   # Log historical blackout durations
   echo "ENV:${app}${env}|$startBlackoutDateTime|$endBlackoutDateTime|$blackoutDescr" >> $BLACKOUT_HISTORY
   util::log "DEBUG" "Added new blackout entry: ENV:${app}${env}|$endBlackoutDateTime|$blackoutDescr"

   util::log "INFO" "Successfully started blackout for $app $env"
   return 0
}

function monitor::endBlackoutAppEnv() # app, env
{
   local app=$1
   local env=$2
   local match=""

   match=$( egrep "^ENV:${app}${env}" $BLACKOUT_LIST )
   if [ -n "$match" ]; then
     sed -i "/^ENV:${app}${env}/d" $BLACKOUT_LIST
     util::log "DEBUG" "Removed blackout entry: $match"
     util::log "INFO" "Successfully cleaned up expired blackouts for $app $env"
   else
     util::log "DEBUG" "Could not find ENV:${app}${env} in blackout list"
   fi

   return 0

}

function monitor::startBlackout() # domainName, serverName, durationMins, description
{
   local domainName="$1"
   local serverName="$2"
   local durationMins=$3
   local blackoutDescr="$4"
   declare -Ag domainInfo
   local majorToolsVer=""
   local envDateTime=""
   local match=""

   # blackout starts now
   local startBlackoutDateTime=$( date --rfc-3339=seconds | tr ' ' '_' )
   # default to 10 mins
   if [ -z "$durationMins" ]; then
     durationMins=10
   fi
   # calculate end date of blackout, adding specified mins to current date/time
   local endBlackoutDateTime=$( date -d "+${durationMins} minutes" --rfc-3339=seconds | tr ' ' '_' )

   if [ -z "$blackoutDescr" ]; then
     blackoutDescr="Manually stopping ${domainName}${serverName} from (stop/cycle)domain command"
   fi

   # First see if there is already a blackout entry, and remove
   # NOTE: new shorter blackout will override existing longer blackout
   monitor::endBlackout "${domainName}" "${serverName}"

   # Next, see if there is already an app/env entry for same env as domain
   majorToolsVer=$( inventory::getCurrentTools "$domainName")
   inventory::getDomainInfo "$domainName" "${serverName}" "$majorToolsVer" domainInfo
   # check for app/env blackout
   match=$( grep "^ENV:${domainInfo[$DOM_ATTR_APP]}${domainInfo[$DOM_ATTR_ENV]}" $BLACKOUT_LIST )
   if [ -n "$match" ]; then
     # already in blackout, see if the domain will be in a longer blackout
     envDateTime=$( echo $match | awk -F\| '{ print $2 }' )
     if [[ "$endBlackoutDateTime" < "$envDateTime" ]]; then
       # the app/env blackout lasts longer, ignore request
       util::log "WARNING" "The ${domainInfo[$DOM_ATTR_APP]}${domainInfo[$DOM_ATTR_ENV]} environment is already in a longer blackout, ignoring"
       return 0
     fi
   fi
   # either the indiviual domain has a longer blackout or just it's own
   # Add official blackout
   echo "${domainName}${serverName}|$endBlackoutDateTime|$blackoutDescr" >> $BLACKOUT_LIST
   # Log historical blackout durations
   echo "${domainName}${serverName}|$startBlackoutDateTime|$endBlackoutDateTime|$blackoutDescr" >> $BLACKOUT_HISTORY
   util::log "DEBUG" "Added new blackout entry: ${domainName}${serverName}|$endBlackoutDateTime|$blackoutDescr"

   util::log "INFO" "Successfully started blackout for ${domainName}${serverName}"
   return 0
}

function monitor::endBlackout() # domainName, serverName
{
   local domainName=$1
   local serverName=$2
   local match=""

   match=$( egrep "^${domainName}${serverName}" $BLACKOUT_LIST )
   if [ -n "$match" ]; then
     sed -i "/^${domainName}${serverName}/d" $BLACKOUT_LIST
     util::log "DEBUG" "Removed blackout entry: $match"
     util::log "INFO" "Successfully cleaned up expired blackout for ${domainName}${serverName}"
   else
     util::log "DEBUG" "Could not find ${domainName}${serverName} in blackout list"
   fi

   return 0

}

function monitor::isAppEnvInBlackout() # app, env
{

   local app="$1"
   local env="$2"
   local match=""
   local blackoutDateTime=""

   local currentDateTime=$( date --rfc-3339=seconds | tr ' ' '_' )

   match=$( grep "^ENV:${app}${env}" $BLACKOUT_LIST)
   if [ -n "$match" ]; then
     # found a blackout, see if it is still valid
     blackoutDateTime=$( echo $match | awk -F\| '{ print $2 }' )
     if [[ "$blackoutDateTime" < "$currentDateTime" ]]; then
       # blackout expired, remove blackout
       monitor::endBlackoutAppEnv "${app}" "${env}"
       # now return 1/false, stating the app/env is not in blackout
       return 1
     else
       # app/env still in blackout
       return 0
     fi
   else
     # no recent blackout
     return 1
   fi
}

function monitor::isDomainInBlackout() #domainName, serverName
{
   local domainName="$1"
   local serverName="$2"
   declare -Ag domainInfo
   local majorToolsVer=""
   local match=""
   local blackoutDateTime=""
   local envDateTime=""

   local currentDateTime=$( date --rfc-3339=seconds | tr ' ' '_' )

   match=$( grep "^${domainName}${serverName}" $BLACKOUT_LIST)
   if [ -n "$match" ]; then
     # found a blackout, see if it is still valid
     blackoutDateTime=$( echo $match | awk -F\| '{ print $2 }' )
     if [[ "$blackoutDateTime" < "$currentDateTime" ]]; then
       # blackout expired, remove blackout
       monitor::endBlackout "${domainName}" "${serverName}"
       # now return 1/false, stating the domain is not in blackout
       return 1
     else
       # domain still in blackout
       return 0
     fi
   else
     # now check if the entire env is in a blackout
     majorToolsVer=$( inventory::getCurrentTools "$domainName")
     inventory::getDomainInfo "$domainName" "$serverName" "$majorToolsVer" domainInfo

     local dEnv="${domainInfo[$DOM_ATTR_ENV]}"
     local dReport="${domainInfo[$DOM_ATTR_REPORT]}"
     if [[ "$dEnv" == "qat" && "$dReport" == "Y" ]]; then
       dEnv="qrpt"
     elif [[ "$dEnv" == "prd" && "$dReport" == "Y" ]]; then
       dEnv="rpt"
     fi
     # check for app/env blackout
     match=$( grep "^ENV:${domainInfo[$DOM_ATTR_APP]}${dEnv}" $BLACKOUT_LIST )
     if [ -n "$match" ]; then
       # already in blackout, see if the domain will be in a longer blackout
       envDateTime=$( echo $match | awk -F\| '{ print $2 }' )
       if [[ "$envDateTime" < "$currentDateTime" ]]; then
         # blackout expired, remove blackout
         monitor::endBlackoutAppEnv "${domainInfo[$DOM_ATTR_APP]}" "${dEnv}"
         # now return 1/false, stating the app/env is not in blackout
         return 1
       else
         # app/env still in blackout
         return 0
       fi
     else
       # all clear no recent blackout
       return 1
     fi
   fi
}
