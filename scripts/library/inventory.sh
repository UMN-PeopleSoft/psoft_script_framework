# Library: inventory
# Script: inventory.sh
# Purpose: functions to read,write from inventory file (domain.list) controlled by
#          an NFS 4 safe file locking (fcntl_lock) https://github.com/magnumripper/fcntl-lock
# CB: Nate Werner
# Created: 10/28/2017
#
# Functions:
#   getDomainsByEnv(app, env, type, toolsversion, out domainArr)
#      Passing in an app and env, and type (app,web,prc,all,appweb), optional tools version
#      (If tools version not specified, most current used), it returns an array of domainNames.
#      For schedulers, the name will have the serverName appended.
#      For reporting envs, use 'qrpt' and 'rpt' for env code.
#   getDomainsByHost(host, toolsversion, out domainArr)
#      Passing in a host name, returns an array of domainNames.
#   getDomainInfo( domainName, serverName, toolsVersion, out domainAttribArr)
#      Passing in a domainName, returns array of domain Attributes,
#       that can be referenced in array by standard names listed above.
#      If searching for a scheduler, if serverName is not appended, PSUNX is assumed.
#      Returns associative array so item can be retrieved by name,
#        ie:   domainInfo[domainName]
#   addDomain(name, type, app, env, reporting, purpose, serverName, host, toolsVersion, webVersion)
#      Adds a new entry to the domain.list.  If duplicate,
#       the toolsVersion and web_version are updated.
#      If serverName is appended to name, it will be parsed out and used for serverName parameter.
#      If a non-empty serverName is already being passed in it will override the value appended to
#      the Name.  All parameters are required, pass in blank space if not used.
#   delDomain(name, serverName, toolsVersion)
#      Removes Domain from Domain List.
#   upgradeDomain(name, serverName, toolsVersion, webVersion)
#      Updated tools and web version for a domain.
#   cloneEnv(app, env, new_toolsVersion, web_version)
#      Duplicate a set of domains to new major tools version.
#      If major version already exists for any domains, none are updated, returns 1.
#      If source domains do not exist, returns 1.   Previous version in sequence assumed.
#
#   isInExcludeList() # domainName, serverName
#      Check if the domain is ignored for inventory list results.
#####################

## includes
#if [ -z "$BOOTSTRAP_LOADED" ]; then
#  source ./bootstrap.sh
#  source ./domain.sh
#fi

#### Internal support functions

# Supports access lock control to the domain inventory by locking the file access for read/writes
# Change inventory will create exclusive write lock
function __changeInventory() # commandString
{
   local commandString="$1"
   local lock_results
   if [ ! -e  $INVENTORY_LOCK ]; then
     touch $INVENTORY_LOCK
   fi
   # create exclusive (-x) write lock
   lock_results=$(fcntl-lock -x $INVENTORY_LOCK -c "$commandString $DOMAIN_LIST")
   # no output returned from command, just log results
   util::log "DEBUG" "fcntl-lock -x results: $lock_results"
}

# Read inventory will create a read / shared lock where others can read at the same time,
#  but will be blocked by a write exclusive lock
function __readInventory() # commandString
{
   local commandString="$1"
   local lock_results
   if [ ! -e  $INVENTORY_LOCK ]; then
     touch $INVENTORY_LOCK
   fi
   # use a shared read lock. (-c) will use shell and echo out the results.
   # since a read will run grep/cat, the echoed results will be the return value of the function
   lock_results=$(fcntl-lock -s $INVENTORY_LOCK -c "$commandString $DOMAIN_LIST")
   echo "$lock_results"
}

# Remaps friendly domainType codes to support lookp
function __mapDomainType() # domainType
{
   local domainType=$1
   local responseDomainType

   # if domainType is all or ALL, then get all domain types
   # if domainType is webapp, the get both domain types
   responseDomainType=$domainType
   if [[ "$domainType" == "all" || "$domainType" == "ALL" ]]; then
      responseDomainType=""
   fi
   if [[ "$domainType" == "webapp" ]]; then
      responseDomainType="(app|web)"
   fi
   echo "$responseDomainType"
}

# Utility to parse the scheduler servername from domainName
function __parseSchedServerName() # domainName , serverName, toolsVersion
{

   local inDomainName=$1
   local inServerName=$2
   local toolsVersion=$3
   local posServerName
   local checkMatch

   # check if the name includes the scheduler server name
   if [[ "$inDomainName" == *PSUNX* ]]; then
     # get character position of server name and extract
     posServerName=$( expr index "$inDomainName" PSUNX )
     posServerName=$(($posServerName - 1))
     inServerName=${inDomainName:$posServerName}
     inDomainName=${inDomainName%PSUNX*}
     # re-write the domainName to remove scheduler server Name if it was appended
     domainName="$inDomainName"
   elif [ -z "$inServerName" ]; then
     inServerName="NA"
     # Check if this is possibly a scheduler without serverName provided
     # filter by excluding app server, ren server, and not ends with number (web)
     if [[ "$inDomainName" != a* && "$inDomainName" != *ren* && ! "$inDomainName" =~ [0-9]$ ]]; then
       checkMatch=$( __readInventory "grep \"^$inDomainName \"" | grep "${toolsVersion:0:4}" | awk '{ print $7 }' )
       if [ -n "$checkMatch" ]; then
         inServerName="$checkMatch"
       fi
     fi
   fi
   util::log "DEBUG" "${indomainName}: __parseSchedServerName: $inServerName"
   serverName="$inServerName"
   return 0
}

# Utility to validate domain Attributes before adding
function __checkAttributes()
{
  # Store input parameters
  local domainName=$1
  local domainType=$2
  local app=$3
  local env=$4
  local reporting=$5
  local purpose=$6
  local host=$7
  local toolsVersion=$8
  local webVersion=$9
  local proceed

  # Input validation
  if [[ ! "$ATTR_APP_LIST" =~ ",${app}," ]]; then
    util::log "ERROR" "Invalid Application of $app, valid options are: ${ATTR_APP_LIST:1}"
    return 1
  fi

  if [[ ! "$ATTR_ENV_LIST" =~ ",${env}," ]]; then
    util::log "ERROR" "Invalid Environment of $env, Valid options are: ${ATTR_ENV_LIST:1}"
    return 1
  fi

  if [[ ! "$ATTR_TYPE_LIST" =~ ",${domainType}," ]]; then
    util::log "ERROR" "Invalid Domain Type of $domainType, Valid options are: ${ATTR_TYPE_LIST:1}"
    return 1
  fi

  if [[ ! "$ATTR_PURPOSE_LIST" =~ ",${purpose}," ]]; then
    util::log "ERROR" "Invalid Purpose of $purpose, Valid options are: ${ATTR_PURPOSE_LIST:1}"
    return 1
  fi

  if [[ ! "$ATTR_REPORTING_LIST" =~ "${reporting}" ]]; then
    util::log "ERROR" "Invalid Reporting Flag of $reporting, Valid options are: ${ATTR_REPORTING_LIST:1}"
    return 1
  fi

  if [[ ! "$ATTR_TOOLS_VERSION_LIST" =~ "$toolsVersion" ]]; then
    util::log "ERROR" "Invalid Tools Version of $toolsVersion, Valid options are: ${ATTR_TOOLS_VERSION_LIST:1}"
    return 1
  fi

  if [ "$domainType" == "web" ]; then
    if [[ ! "$ATTR_WEBLOGIC_VERISON_LIST" =~ "$webVersion" ]]; then
      util::log "ERROR" "Invalid Weblogic Version of $webVersion, Valid options are: ${ATTR_WEBLOGIC_VERISON_LIST:1}"
      return 1
    fi
  fi

  # basic validation
  if [[ "$domainName" != *"$env"* && "$reporting" == "N" ]]; then
    util::log "ERROR" "Domain name $domainName is not consistent with environment specified: $env"
    return 1
  fi
  if [[ "$domainName" != *"$app"* && "$purpose" != "ren" ]]; then
    util::log "ERROR" "Domain name $domainName is not consistent with app specified: $app"
    return 1
  fi
  if [[ "${domainName:0:1}" != "a" && "$domaintype" == "app" && "$purpose" != "ren" ]]; then
    util::log "ERROR" "App Server domain names should start with an 'a'"
    return 1
  fi
  if [[ "$host" != *"$env"* && "$reporting" == "N" && "$purpose" != "trace" ]]; then
    if [[ $- == *i* ]]; then
      read -e -p "Warning: the host name $host does not seem to be consistent with environment '$env', ok to proceed? (Y/N):" proceed
      if [[ "$proceed" != "Y" && "$proceed" != "y" ]]; then
        echo "Chosen to exit"
        return 1
      fi
    fi
  fi
  if [[ "$purpose" == "ib" && ! "$domainName" == *"ib"* ]]; then
    util::log "ERROR" "Domain names should contain an 'ib' for IB domain purpose"
    return 1
  fi
  if [[ "$purpose" == "main" && "$domainName" == *"ib"* ]]; then
    util::log "ERROR" "Domain names should not contain an 'ib' for Main/PIA domain purpose"
    return 1
  fi

  if [[ "$purpose" == "ren" && ! "$domainName" == *"ren"* ]]; then
    util::log "ERROR" "Domain names should contain an 'ren' for REN server domain purpose"
    return 1
  fi
  if [[ "$purpose" == "trace" && ! "$domainName" == *"t"* ]]; then
    util::log "ERROR" "Trace domain names should contain a 't' for trace domain purpose"
    return 1
  fi

# End Function
}

# only checks the upgrading tools and web versions
function __checkToolsWebVersion()  # toolsVersion, webVersion, domainType
{
  local toolsVersion=$1
  local webVersion=$2
  local domainType=$3

  if [[ ! "$ATTR_TOOLS_VERSION_LIST" =~ "$toolsVersion" ]]; then
    util::log "ERROR" "Invalid Tools Version of $toolsVersion\nValid options are: ${ATTR_TOOLS_VERSION_LIST:1}"
    return 1
  fi

  if [ "$domainType" == "web" ]; then
    if [[ ! "$ATTR_WEBLOGIC_VERISON_LIST" =~ "$webVersion" ]]; then
      util::log "ERROR" "Invalid Weblogic Version of $webVersion\nValid options are: ${ATTR_WEBLOGIC_VERISON_LIST:1}"
      return 1
    fi
  fi
}

##### MAIN functions ######

# Determins current tools release for a list of filtered domains
function inventory::getCurrentToolsAppEnv() # app, env, domainType
{
   local app=$1
   local env=$2
   local domainType=$3
   local reporting="N"
   local responseToolsVer

   if [[ "$env" == "qrpt" ]]; then
      env="qat"
      reporting="Y"
   elif [[ "$env" == "rpt" ]]; then
      env="prd"
      reporting="Y"
   else
      reporting="N"
   fi

   if [[ -z "$domainType" || "$domainType" == "all" ]]; then
     responseToolsVer=$( __readInventory "grep \"$app $env\"" | grep " $reporting " | awk '{ print $9 }' | sort -u | tail -1)
   else
     responseToolsVer=$( __readInventory "grep \"$domainType $app $env\"" | grep " $reporting " | awk '{ print $9 }' | sort -u | tail -1)
   fi
   echo "$responseToolsVer"
}

function inventory::getCurrentTools()  # domainName
{
   local domainName="$1"
   local serverName=""

   __parseSchedServerName "$domainName" "$serverName" "$toolsVersion"

   responseToolsVer=$( __readInventory "grep \"^$domainName \"" | awk '{ print $9 }' | sort -u | tail -1)
   echo "$responseToolsVer"
}

#  Passing in an app and env, and type (app,web,prc,all,appweb), optional tools version
#      (If tools version not specified, most current used), it returns an array of domainNames.
#      For schedulers, the name will have the serverName appended.
function inventory::getDomainsByEnv() #app, env, domainType, purpose, reqToolsVer, out domainArr)
{
   local app=$1
   local env=$2
   local domainType=$3
   local purpose="$4"
   # filter to specific tools version, default to Newest
   local reqToolsVer=$5
   local _outVar=$6
   local reporting
   local -a domainArr
   IFS=$'\n'

   if [[ "$env" == "qrpt" ]]; then
      env="qat"
      reporting="Y"
   elif [[ "$env" == "rpt" ]]; then
      env="prd"
      reporting="Y"
   else
      reporting="N"
   fi

   # map domainType code to searchable values
   domainType=$( __mapDomainType $domainType )

   # specific version not passed, use most current
   if [ -z "$reqToolsVer" ]; then
     reqToolsVer=$( inventory::getCurrentToolsAppEnv $app $env $domainType )
   fi
   util::log "DEBUG" "Current Tools version for $app $env: $reqToolsVer"

   # Wrap the output into an array
   # Note: the scheduler server name will be appended for scheduler domains
   if [ -z "$domainType" ]; then
     if [ -z "$purpose" ]; then
       domainArr=( $( __readInventory "grep \"$app $env\"" | grep " $reporting " | grep "$reqToolsVer" | awk '{ $7 == "NA" ? schedName="" : schedName=$7; print $1schedName }') )
     else  # include purpose filter
       domainArr=( $( __readInventory "grep \"$app $env\"" | grep " $reporting $purpose " | grep "$reqToolsVer" | awk '{ $7 == "NA" ? schedName="" : schedName=$7; print $1schedName }') )
     fi
   else
     if [ -z "$purpose" ]; then
       domainArr=( $( __readInventory "egrep \"$domainType $app $env\"" | grep " $reporting " | grep "$reqToolsVer" | awk '{ $7 == "NA" ? schedName="" : schedName=$7; print $1schedName }') )
     else
       domainArr=( $( __readInventory "egrep \"$domainType $app $env\"" | grep " $reporting $purpose" | grep "$reqToolsVer" | awk '{ $7 == "NA" ? schedName="" : schedName=$7; print $1schedName }') )
     fi
   fi
   # set proper return code
   if [[ "${domainArr[0]}" == "" ]]; then
     return 1
   else
     # Store the resulting array back into the variable name passed in
     eval "$_outVar"'=("${domainArr[@]}")'
     util::log "DEBUG" "Domain List for $domainType $app $env: ${domainArr[@]}"

     return 0
   fi
}

# Get hosts where an env is running on
function inventory::getHostsbyEnv() #env, out hostsArr
{
   local env=$1
   local _outVar=$2
   local -a hostsArr
   local reporting="N"
   IFS=$'\n'

   if [[ "$env" == "qrpt" ]]; then
      env="qat"
      reporting="Y"
   elif [[ "$env" == "rpt" ]]; then
      env="prd"
      reporting="Y"
   fi

   hostsArr=( $( __readInventory "grep \" $env \"" | grep " $reporting " | awk '{ print $8 }' | sort -u ) )

   # Store the resulting array back into the variable name passed in
   eval "$_outVar"'=("${hostsArr[@]}")'
   util::log "DEBUG" "Host List for $env: ${hostsArr[@]}"

   # set proper return code
   if [[ "${hostsArr[0]}" == "" ]]; then
     return 1
   else
     return 0
   fi
}

# Get hosts where an env is running on
function inventory::getHostsbyAppEnv() #app, #env, out hostsArr
{
   local app=$1
   local env=$2
   local _outVar=$3
   local -a hostsArr
   local reporting="N"
   IFS=$'\n'

   if [[ "$env" == "qrpt" ]]; then
      env="qat"
      reporting="Y"
   elif [[ "$env" == "rpt" ]]; then
      env="prd"
      reporting="Y"
   fi

   hostsArr=( $( __readInventory "grep \" $app $env \"" | grep " $reporting " | awk '{ print $8 }' | sort -u ) )

   # Store the resulting array back into the variable name passed in
   eval "$_outVar"'=("${hostsArr[@]}")'
   util::log "DEBUG" "Host List for $env: ${hostsArr[@]}"

   # set proper return code
   if [[ "${hostsArr[0]}" == "" ]]; then
     return 1
   else
     return 0
   fi
}

function inventory::getHosts() # out hostsArr
{
   local _outVar=$1
   local -a hostsArr
   IFS=$'\n'

   hostsArr=( $( __readInventory "cat" | grep -v 'Domain' | awk '{ print $8 }' | sort -u ) )

   # Store the resulting array back into the variable name passed in
   eval "$_outVar"'=("${hostsArr[@]}")'

   # set proper return code
   if [[ "${hostsArr[0]}" == "" ]]; then
     return 1
   else
     return 0
   fi
}

function inventory::getSchedulerDomains() # out domainArr
{
   local _outVar=$1
   local -a domainArr

   local currToolsVer=$( inventory::getCurrentToolsAppEnv "cs" "tst" "app" )
   IFS=$'\n'
   domainArr=( $( __readInventory "grep \"prc\"" | grep "${currToolsVer:0:5}" | awk '{ $7 == "NA" ? schedName="" : schedName=$7; print $1schedName }') )

   # Store the resulting array back into the variable name passed in
   eval "$_outVar"'=("${domainArr[@]}")'
   util::log "DEBUG" "Domain List for 'prc': ${domainArr[@]}"

   # set proper return code
   if [[ "${domainArr[0]}" == "" ]]; then
     return 1
   else
     return 0
   fi

}

# Passing in a host name, returns an array of domainNames.  optional tools version
#      (If tools version not specified, most current used), it returns an array of domainNames.
#      For schedulers, the name will have the serverName appended.
function inventory::getDomainsByHost() # host, toolsVersion, out domainArr
{
   local psHost=$1
   # filter to specific tools version, default to Newest
   local reqToolsVer=$2
   local _outVar=$3
   local -a domainArr
   IFS=$'\n'

   # Wrap the output into an array
   # Note: the scheduler server name will be appended for scheduler domains
   if [ -z "$reqToolsVer" ]; then
      domainArr=( $( __readInventory "grep \"$psHost\"" | awk '{ $7 == "NA" ? schedName="" : schedName=$7; print $1schedName }') )
   else
      domainArr=( $( __readInventory "grep \"$psHost\"" | grep "$reqToolsVer" | awk '{ $7 == "NA" ? schedName="" : schedName=$7; print $1schedName }') )
   fi
   # Store the resulting array back into the variable name passed in
   eval "$_outVar"'=("${domainArr[@]}")'
   util::log "DEBUG" "Host Domain List for $psHost: ${domainArr[@]}"

   # set proper return code
   if [[ "${domainArr[0]}" == "" ]]; then
     return 1
   else
     return 0
   fi
}

# getDomainInfo( domainName, serverName, toolsVersion, out domainAttribArr)
#      Passing in a domainName, returns array of domain Attributes,
#       that can be referenced in array by standard names listed above.
#      If searching for a scheduler, if serverName is not appended, PSUNX is assumed.
function inventory::getDomainInfo() # domainName, serverName, toolsVersion, out domainAttribArr
{
   local domainName=$1
   local serverName=$2
   local toolsVersion=$3
   local _outVar=$4
   # will use special associative array so names can be use as an index
   local -A domainArrib
   local -a domainLine
   local domainArribString
   if [[ -z "$toolsVersion" ]]; then
     toolsVersion=$( inventory::getCurrentTools "$domainName" )
   fi
   # Use utility to parse domainName and serverName fields
   __parseSchedServerName "$domainName" "$serverName" "$toolsVersion"
   # control array parition
   IFS=$' '
   # Note added space to serverName so it does not match Weblogic version
   # Node added space to domainName so scheulers do not match web domains
   domainLine=( $( __readInventory "grep \"^$domainName \"" | grep "$serverName " | grep "${toolsVersion:0:4}" ) )
   domainArrib[$DOM_ATTR_NAME]=${domainLine[0]}
   domainArrib[$DOM_ATTR_TYPE]=${domainLine[1]}
   domainArrib[$DOM_ATTR_APP]=${domainLine[2]}
   domainArrib[$DOM_ATTR_ENV]=${domainLine[3]}
   domainArrib[$DOM_ATTR_REPORT]=${domainLine[4]}
   domainArrib[$DOM_ATTR_PURPOSE]=${domainLine[5]}
   domainArrib[$DOM_ATTR_SRVNAME]=${domainLine[6]}
   domainArrib[$DOM_ATTR_HOST]=${domainLine[7]}
   domainArrib[$DOM_ATTR_TOOLSVER]=${domainLine[8]}
   domainArrib[$DOM_ATTR_WEBVER]=${domainLine[9]}
   # Returning an Associative array, need to declare -A to return to callee
   domainArribString="$(declare -p domainArrib)"
   util::log "DEBUG" "Domain Attributes: $domainArribString"
   eval "declare -Ag $_outVar="${domainArribString#*=}
   # set proper return code
   if [[ "${domainLine[0]}" == "" ]]; then
     return 1
   else
     return 0
   fi
}

#      Adds a new entry to the domain.list.  If duplicate,
#       the tools_version and web_version are updated.
#      If serverName is appended to name, it will be parsed out and used for serverName parameter.
#      If a non-empty serverName is already being passed in it will override the value appended to
#      the Name.  All parameters are required, pass in blank space if not used.
#   Return codes:
#     0 - Added new domain, new name or existing name, but different major tools version
#     1 - Updated tools/web versions on existing domain on same major tools version
#     2 - Existing domain, but unmatched attributes (host, type, purpose, app, env), no changes
#     3 - Exact match, no change
function inventory::addDomain()  #name, type, app, env, reporting, purpose, serverName, host, toolsVersion, webVersion
{
   local domainName=$1
   local domainType=$2
   local app=$3
   local env=$4
   local reporting=$5
   local purpose=$6
   local serverName=$7
   local host=$8
   local toolsVersion=$9
   local webVersion=${10}
   local domainCheck
   local attribCheck
   local versionCheck

   __checkAttributes "$domainName" "$domainType" "$app" "$env" "$reporting" "$purpose" "$host" "$toolsVersion" "$webVersion"
   if [ $? -ne 0 ]; then
     # failed attribute validation
     return 1
   fi
   if [ -z "$webVersion" ]; then
     webVersion="NA"
   fi
   __parseSchedServerName "$domainName" "$serverName" "$toolsVersion"

   # first check if the domain exists
   domainCheck=$( __readInventory "grep \"^$domainName \"" | grep "$serverName " )
   if [ -n "$domainCheck" ]; then
     # domain already exists, handle a bad config or check for new tools/web patch
     attribCheck=$( __readInventory "grep \"$domainName $domainType $app $env $reporting $purpose $serverName $host\"" )
     if [ -n "$attribCheck" ]; then
       # Matched all attributes ignoring tools/weblogic versions
       # next see if tool is different major version
       versionCheck=$( __readInventory "grep \"$domainName $domainType $app $env $reporting $purpose $serverName $host ${toolsVersion:0:4}\"" )
       if [ -n "$versionCheck" ]; then
         # same major version
         # Try for exact match
         matchCheck=$( __readInventory "grep \"$domainName $domainType $app $env $reporting $purpose $serverName $host $toolsVersion $webVersion\"" )
         if [ -n "$versionCheck" ]; then
           util::log "DEBUG" "Inventory: addDomain: Exact match $matchCheck"
           # Exact match, no change
           return 3
         else
           # update tools/web versions
           util::log "DEBUG" "Inventory: addDomain: Updating tools/web version"
           __changeInventory "sed -i \"s/$domainName $domainType $app $env $reporting $purpose $serverName $host $toolsVersion\([a-z0-9.]\+\) \([0-9.]\+\|NA\)/$domainName $domainType $app $env $reporting $purpose $serverName $host $toolsVersion $webVersion/g\""

           return 1
         fi
       else
         # Good - new tools version
         util::log "DEBUG" "Inventory: addDomain: Adding New entry: $domainName $domainType $app $env $reporting $purpose $serverName $host $toolsVersion $webVersion"
         __changeInventory "echo \"$domainName $domainType $app $env $reporting $purpose $serverName $host $toolsVersion $webVersion\" >>"
         return 0
       fi
     else
        # attribute issues, no changes
        util::log "DEBUG" "Inventory: addDomain: no Changes to domain $attribCheck"
        return 2
     fi
   else
      # good - new domain
      util::log "DEBUG" "Inventory: addDomain: Adding New entry: $domainName $domainType $app $env $reporting $purpose $serverName $host $toolsVersion $webVersion"
      __changeInventory "echo \"$domainName $domainType $app $env $reporting $purpose $serverName $host $toolsVersion $webVersion\" >>"
      return 0
   fi

}

#      Update tools and web version for a domain in domain.list
#        Error codes:  1 = not a valid domain
#                      2 = not a valid tools/Weblogic installed version
function inventory::upgradeDomain()  # domainName, serverName, toolsVersion, webVersion
{

   local domainName=$1
   local serverName=$2 # scheduler process name (PSUNX)
   local toolsVersion=$3
   local webVersion=$4
   local matchCheck
   declare -Ag domainInfo

   if [ -z "$webVersion" ]; then
     webVersion="NA"
   fi
   # Use utility to parse domainName and serverName fields
   __parseSchedServerName "$domainName" "$serverName" "$toolsVersion"

   matchCheck=$(__readInventory "grep \"^$domainName \"" | grep "${toolsVersion:0:4}" | grep "$serverName " )
   util::log "DEBUG" "${domainName}: Inventory: upgradeDomain: MatchCheck: $matchCheck"
   if [ -n "$matchCheck" ]; then
      # valid update, get all domain attributes
      inventory::getDomainInfo "$domainName" "$serverName" "$toolsVersion" domainInfo
      util::log "DEBUG" "${domainName}: Inventory: upgradeDomain: ${domainInfo[$DOM_ATTR_NAME]}"
      if __checkToolsWebVersion "$toolsVersion" "$webVersion" "${domainInfo[$DOM_ATTR_TYPE]}"; then
        util::log "DEBUG" "${domainName}: Inventory: upgradeDomain to $toolsVersion $webVersion"
        # now update the domain
        if [[ ! "${domainInfo[$DOM_ATTR_TYPE]}" == "web" ]]; then
          webVersion="NA"
        fi
        util::log "DEBUG" "${domainName}: Inventory: upgradeDomain: ${domainInfo[$DOM_ATTR_NAME]} ${domainInfo[$DOM_ATTR_TYPE]} ${domainInfo[$DOM_ATTR_APP]} ${domainInfo[$DOM_ATTR_ENV]} ${domainInfo[$DOM_ATTR_REPORT]} ${domainInfo[$DOM_ATTR_PURPOSE]} ${domainInfo[$DOM_ATTR_SRVNAME]} ${domainInfo[$DOM_ATTR_HOST]} ${domainInfo[$DOM_ATTR_TOOLSVER]:0:4}\([a-z0-9.]\+\) \([a-z0-9.]\+\|NA\)"
        __changeInventory "sed -i \"s/${domainInfo[$DOM_ATTR_NAME]} ${domainInfo[$DOM_ATTR_TYPE]} ${domainInfo[$DOM_ATTR_APP]} ${domainInfo[$DOM_ATTR_ENV]} ${domainInfo[$DOM_ATTR_REPORT]} ${domainInfo[$DOM_ATTR_PURPOSE]} ${domainInfo[$DOM_ATTR_SRVNAME]} ${domainInfo[$DOM_ATTR_HOST]} ${domainInfo[$DOM_ATTR_TOOLSVER]:0:4}\([a-z0-9.]\+\) \([a-z0-9.]\+\|NA\)/${domainInfo[$DOM_ATTR_NAME]} ${domainInfo[$DOM_ATTR_TYPE]} ${domainInfo[$DOM_ATTR_APP]} ${domainInfo[$DOM_ATTR_ENV]} ${domainInfo[$DOM_ATTR_REPORT]} ${domainInfo[$DOM_ATTR_PURPOSE]} ${domainInfo[$DOM_ATTR_SRVNAME]} ${domainInfo[$DOM_ATTR_HOST]} $toolsVersion $webVersion/g\""
        util::log "DEBUG" "${domainName}: Inventory: upgradeDomain: sed exit code: $?"
      else
         util::log "DEBUG" "${domainName}: Inventory: upgradeDomain: Invalid tools version"
         return 2
      fi
   else
     util::log "DEBUG" "${domainName}: Inventory: upgradeDomain: Domain does not exist"
     return 1
   fi
   unset domainInfo

}

#      Removes Domain from Domain List.
function inventory::delDomain()  # domainName, serverName, toolsVersion
{
   local domainName=$1
   local serverName=$2 # scheduler process name (PSUNX)
   local toolsVersion=$3
   local matchCheck
   declare -Ag domainInfo

   # Use utility to parse domainName and serverName fields
   __parseSchedServerName "$domainName" "$serverName" "$toolsVersion"

   matchCheck=$(__readInventory "grep \"^$domainName \"" | grep "${toolsVersion:0:4}" | grep "$serverName " )
   if [ -n "$matchCheck" ]; then
      inventory::getDomainInfo "$domainName" "$serverName" "$toolsVersion" domainInfo
      util::log "DEBUG" "${domainName}: Inventory: delDomain success"
      # now delete the domain
      __changeInventory "sed -i \"/${domainInfo[$DOM_ATTR_NAME]} ${domainInfo[$DOM_ATTR_TYPE]} ${domainInfo[$DOM_ATTR_APP]} ${domainInfo[$DOM_ATTR_ENV]} ${domainInfo[$DOM_ATTR_REPORT]} ${domainInfo[$DOM_ATTR_PURPOSE]} ${domainInfo[$DOM_ATTR_SRVNAME]} ${domainInfo[$DOM_ATTR_HOST]} ${domainInfo[$DOM_ATTR_TOOLSVER]:0:4}\([a-z0-9.]\+\) \([0-9.]\+\|NA\)/d\""
   else
      util::log "DEBUG" "${domainName}: Inventory: delDomain - domain does not exist"
      return 1
   fi
   unset domainInfo

}

#      Duplicate a set of domains to new major tools version.
#      If major version already exists for any domains, none are updated, returns 1.
#      If source domains do not exist, returns 1.   Previous version in sequence assumed.
#      Clone will automatically clone reporting envs with primary env.
function inventory::cloneEnv() # app, env, new_toolsVersion, webVersion
{
   local app=$1
   local env=$2
   local newToolsVersion=$3
   local newWebVersion=$4
   local matchCheck
   local oldToolsVer
   local -a oldDomainsArr
   local matchString
   declare -Ag oldDomainInfo

   if [[ "$env" == "qrpt" ]]; then
     matchString="$app qat Y"
   elif [[ "$env" == "rpt" ]]; then
     matchString="$app prd Y"
   else
     matchString="$app $env N"
   fi
   matchCheck=$(__readInventory "grep \"$matchString\"")
   if [ -n "$matchCheck" ]; then
      # env exits, now verify we're not cloning on same major tools version
      dupeCheck=$(__readInventory "grep \"$matchString\"" | grep "${newToolsVersion:0:4}")
      if [ -n "$dupeCheck" ]; then
         # cannot dupe with same major tools version
         util::log "ERROR" "${domainName}: Inventory: cloneEnv - source env is already on same tools verison"
         return 2
      else
         # request good, we will now create a new set of domains based on previous tools version
         # get latest tools version
         oldToolsVer=$( inventory::getCurrentToolsAppEnv "$app" "$env" "" )
         # get list of all domains in old env
         inventory::getDomainsByEnv "$app" "$env" "all" "$oldToolsVer" oldDomainsArr
         # now loop through the old domains and create a new one for each
         for eachOldDomain in "${oldDomainsArr[@]}"; do
            # read attributes for domain
            inventory::getDomainInfo "$eachOldDomain" "" "$oldToolsVer" oldDomainInfo
            # copy to new domain and set new versions
            util::log "DEBUG" "${domainName}: Inventory: cloneEnv: Adding domain ${oldDomainInfo[$DOM_ATTR_NAME]} to $newToolsVersion"
            inventory::addDomain "${oldDomainInfo[$DOM_ATTR_NAME]}" "${oldDomainInfo[$DOM_ATTR_TYPE]}" "${oldDomainInfo[$DOM_ATTR_APP]}" "${oldDomainInfo[$DOM_ATTR_ENV]}" "${oldDomainInfo[$DOM_ATTR_REPORT]}" "${oldDomainInfo[$DOM_ATTR_PURPOSE]}" "${oldDomainInfo[$DOM_ATTR_SRVNAME]}" "${oldDomainInfo[$DOM_ATTR_HOST]}" "$newToolsVersion" "$newWebVersion"
         done
      fi
   else
      # no match
      util::log "ERROR" "${domainName}: Inventory: cloneEnv: source env does not exist"
      return 1
   fi
   unset oldDomainInfo
}

function inventory::isInExcludeList() # domainName, serverName
{
   local domainName="$1"
   local match=""

   match=$( cat $EXCLUDE_LIST | grep -v "#" | egrep "^${domainName}${serverName}$" )
   if [ -n "$match" ]; then
     return 0  # True
   else
     return 1  # False
   fi

}

# This function captures domain info for the domain currently deploy on the
#   host this function is ran on.  Parsing domain info from the path
#   makes assumptions on certain rules on naming a domain at creation
function inventory::readHostDomains()
{
  # exported PS_SCRIPT_BASE from main script
  source $LIB_HOME/bootstrap.sh

  source $LIB_HOME/utilities.sh
  source $LIB_HOME/security.sh

  local domainFind=()
  local domainResults=()
  local domainType=""
  local domainPath=""
  local domainName=""
  local purpose=""
  local reporting=""
  local app=""
  local env=""
  local weblogic_path=""
  local weblogic_version=""
  local tools_path=""
  # Locate all valid PeopleSoft domains
  domainFind=("$( find -L /psoft/domains/8.5*/*/appserv/a*/PSTUXCFG /psoft/domains/8.5*/*/appserv/*ren*/PSTUXCFG /psoft/domains/8.5*/webserv/*/bin/setEnv.sh /psoft/domains/8.5*/*/appserv/prcs/*/PSTUXCFG 2>/dev/null | sort -u )")

  #util::log "DEBUG" "Domain Find results: ${domainFind[@]}"
  for domainPath in ${domainFind[@]}
  do
    # Skip blank output rows
    if [ -z "$domainPath" ]; then
      continue
    fi

    # Find the type of domain
    if [[ $domainPath == *webserv* ]]; then
      domainType="web"
    elif [[ $domainPath == *prcs* ]]; then
      domainType="prc"
    elif [[ $domainPath == *appserv* ]]; then
      domainType="app"
    fi

    # for web, drop bin directory too, so we can parse domain name later
    if [ "$domainType" == "web" ]; then
      domainPath=${domainPath%/*}
    fi
    # next get the domain name
    # drop file from string (/psoft/alldomains/psapp-dev01/8.53/fs/appserv/afsdev1/PSTUXCFG)
    domainName=${domainPath%/*}
    # drop base path and we get the domain name (/psoft/alldomains/psapp-dev01/8.53/fs/appserv/afsdev1)
    # Result (afsdev1)
    domainName=${domainName##*/}

    if [ "$domainType" == "web" ]; then
      domainPath=${domainPath%/*}
    fi

    # Check for purpose (REN/IB/main)
    if [[ $domainName == *ib* ]]; then
      purpose="ib"
    elif [[ $domainName == *ren* ]]; then
      purpose="ren"
    elif [[ ($domainName == *t2 || $domainName == *t1) && ( "$domainType" == "web" || "$domainType" == "app" ) && ! $domainName == *at2 && ! $domainName == *at1 && ! $domainName == *st2 && ! $domainName == *st1 && ! $domainName == *pt1 && ! $domainName == *pt2 ]]; then
      purpose="trace"
    else
      purpose="main"
    fi

    # check for reporting domains
    if [[ $domainName == *rpt* ]]; then
      reporting="Y"
    else
      reporting="N"
    fi

    # get the application
    if [ "$domainType" == "web" -o "$domainType" == "prc" ]; then
      app=${domainName:0:2}
    elif [ "$domainType" == "app" ]; then
      app=${domainName:1:2}
    fi
    # if ren domain, app is in different position
    if [ "$purpose" == "ren" ]; then
      app=${domainName:0:2}
      # for REN domains we use ps as the REN may be servicing all 4 apps
      if [ "$app" == "ps" ]; then
        app="ih"
      fi
    fi

    # get the environment for domain
    if [[ "$reporting" == "Y" && "$domainName" == *qrpt* ]]; then
      env="qat"
    elif [ "$reporting" == "Y" ]; then
      env="prd"
    elif [ "$domainType" == "web" -o  "$purpose" == "ren" -o "$domainType" == "prc" ]; then
      env=${domainName:2:3}
    else
      env=${domainName:3:3}
    fi

    # Next, get the version info for the domain
    if [ "$domainType" == "web" ]; then
      # we'll get the weblogic version from the Env file's bea_home path
      weblogic_path=$( grep 'BEA_HOME=' $domainPath/bin/setEnv.sh | awk -F'=' '{ print $2 }' | awk -F'/' '{ print $4 }' )
      weblogic_version=${weblogic_path##*/}
      tools_path=$( grep 'PS_HOME=' $domainPath/bin/setEnv.sh | awk -F'=' '{ print $2 }' | awk -F'/' '{ print $4 }' )
      tools_version=${tools_path##*/}
    else
      # for app and scheduler get version from domain env file.
      if [ "$domainType" == "prc" ]; then
        tools_version=$( grep -oh '8.5[[:digit:]]\.[[:alnum:]]*' ${domainPath%/*}/psprcsrv.env | head -1 )
      else
        tools_version=$( grep -oh '8.5[[:digit:]]\.[[:alnum:]]*' ${domainPath%/*}/psappsrv.env | head -1 )
      fi
      weblogic_version="NA"
    fi

    # Get hostname from current this this function is running on
    domainHost=$( hostname -s )

    # get the server Name
    if [ "$domainType" == "prc" ]; then
      serverName=$( grep "PrcsServerName" ${domainPath%/*}/psprcs.cfg | awk -F= '{ print $2 }' )
    else
      serverName="NA"
    fi
    linefeed=$'\n'
    #echo "Domain: $domainName $domainType $app $env $reporting $purpose $serverName $domainHost $tools_version $weblogic_version"
    # add domain to results
    domainResults=("${domainResults[@]}$domainName $domainType $app $env $reporting $purpose $serverName $domainHost $tools_version $weblogic_version$linefeed")
  done

  # Return the results to caller via stdout, do not print extra line feed (-n)
  echo -n "${domainResults[@]}"

}

#export functions so they can be called from parallel command
export -f inventory::readHostDomains
## END inventory.sh
