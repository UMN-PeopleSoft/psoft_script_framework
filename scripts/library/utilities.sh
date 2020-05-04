# Library: util
# Script: utilities.sh
# Purpose: General utility functions that don't fall into any particular bucket
# CB: Nate Werner
# Created: 11/18/2017
#
### Mapping
#  getWebPortforDomain(domainName)
#     Generates a port number for a specified web domain by ID.   If domain does not exist, returns 1.
#
#### SQL
#
#  runPSSQL(app, env, sqlString, out sqlResult)
#     Run a SQL script as a PSoft schema owner
#
#### Notification
#  sendNotification(severityCode, subject, body, (opt) ToList, (opt) FromName)
#     Provides a standard mean to distribute any notification from servers.
#     Routing by severityCode
#        urgent   : (24/7) pagerduty (on call rotation), service now incident
#        critical :   service now incident, email
#        warning  :   email and Hipchat
#        info     :   HipChat
#     ToList will override email
#
### Logging
#  log( messageType,  MessageString )
#     Log message to standard log file.  Debug messages will write to file/screen
#     if debugging is enabled.
##################

#includes
if [ -z "$BOOTSTRAP_LOADED" ]; then
  currentPath="$( cd "$(dirname "$0")" && pwd )"
  echo "currentP: $currentPath"
  source ${currentPath%${currentPath#*scripts*/}}library/bootstrap.sh
fi

# load domain tools
source $LIB_HOME/inventory.sh
source $LIB_HOME/security.sh

# Global Vars
WEB_PORT_RULE_FILE="$CONFIG_HOME/ps_web/web_port_map.csv"
WEB_ALT_DOMAIN_FILE="$CONFIG_HOME/ps_web/alt_domain.csv"
#WEB_ALT_SEC_NAME_FILE="$CONFIG_HOME/ps_web/alt_domain_secondary.csv"

# Function that will generate correct port for any app/env
# using the web port matrix config.
function util::getWebPortforDomain() # domainName, out portNumber
{
  local domainName=$1
  local digit
  local webPort
  local webDomainAltString=""
  local varPortNum=$2
  local webEnv
  declare -Ag domainInfo

  # get domain details and extract F5 config from it
  inventory::getDomainInfo "$domainName" "" "" domainInfo
  webEnv="${domainInfo[$DOM_ATTR_ENV]}"
  digit=$(grep "^${domainInfo[$DOM_ATTR_APP]}" $WEB_PORT_RULE_FILE | awk -F, '{ print $2}')
  webPort="$digit"
  digit=$(grep "^$webEnv" $WEB_PORT_RULE_FILE | awk -F, '{ print $2}')
  webPort="${webPort}${digit}"
  if [[ "${domainInfo[$DOM_ATTR_REPORT]}" == "Y" && "$webEnv" == "qat" ]]; then
     webEnv="qrpt"
  fi
  if [[ "${domainInfo[$DOM_ATTR_REPORT]}" == "Y" && "$webEnv" == "prd" ]]; then
     webEnv="rpt"
  fi
  webDomainAltString=$(grep "^$webEnv" $WEB_ALT_DOMAIN_FILE | awk -F, '{ print $2}')
  #if [ -z "$webDomainAltString" ]; then
  #  webDomainAltString=$(grep "^${domainInfo[$DOM_ATTR_NAME]}" $WEB_ALT_SEC_NAME_FILE | awk -F, '{ print $2}')
  #fi
  digit=$(grep "^${webDomainAltString}${domainInfo[$DOM_ATTR_PURPOSE]}" $WEB_PORT_RULE_FILE | awk -F, '{ print $2}')
  webPort="${webPort}${digit}1"
  if [[ "${domainInfo[$DOM_ATTR_PURPOSE]}" == "ren" ]]; then
    webPort="7180"
  fi
  util::log "DEBUG" "${domainName}: util::getWebPortforDomain: Port #: $webPort"

  eval "$varPortNum"'="${webPort}"'
}

# Run a SQL Query.  Env is 3 char code, plus qrpt and rpt for reporting instances
function util::runSQL() #app, env, sqlString, out sqlResult
{
   local app="$1"
   local env="$2"
   local query="$3"
   local varSqlResult=$4
   local tnsName=""
   local appOwner=""
   local appPasswd=""
   local sqlResult=""
   local connectString=""

   # Upper case
   tnsName="${app^^}${env^^}"
   appOwner="PS_${app^^}"

   sec::getAppEnvDBSecurity "$app" "$env" appPasswd

   connectString="${appOwner}/${appPasswd}@${tnsName}\n set heading off\n $query;\nexit"
   util::log "DEBUG" "util::runSQL for $app$env sqlstring: $query"
   sqlResult="$( echo -e "$connectString" | $ORACLE_HOME/bin/sqlplus -S )"
   sqlErrorCode=$?
   util::log "DEBUG" "util::runSQL for $app$env sqlresult: $sqlResult"
   sqlResult="${sqlResult##*( )}"
   sqlResult="${sqlResult:1}"
   eval "$varSqlResult"'="${sqlResult}"'
   if [[ "$sqlResult" == *ORA-* ]]; then
     return 1
   else
     return $sqlErrorCode
   fi

}

# Use the SQLCl (SQL Developer client).  Usefull for dumpting json formatted output
function util::runSQLCli() #app, env, sqlString, out sqlResult
{
   local app="$1"
   local env="$2"
   local query="$3"
   local varSqlResult=$4
   local tnsName=""
   local appOwner=""
   local appPasswd=""
   local sqlResult=""
   local connectString=""

   # Upper case
   tnsName="${app^^}${env^^}"
   appOwner="PS_${app^^}"

   sec::getAppEnvDBSecurity "$app" "$env" appPasswd
   connectString="${appOwner}/${appPasswd}@${tnsName}\n SET HEADING OFF\nSET SQLFORMAT json\n $query"
   util::log "DEBUG" "util::runSQL for $app$env sqlstring: $sqlString"
   sqlResult="$( echo -e "$connectString" | sql -S )"
   sqlErrorCode=$?
   util::log "DEBUG" "util::runSQL for $app$env sqlresult: $sqlResult"
   sqlResult="${sqlResult##*( )}"
   sqlResult="${sqlResult:1}"
   eval "$varSqlResult"'="${sqlResult}"'
   if [[ "$sqlResult" == *ORA-* ]]; then
     return 1
   else
     return $sqlErrorCode
   fi

}

# Check if specific app/env is current in a SLA window
# Returns 0 = True or 1= false
# How to use:   if util::isInSLA "$app" "$env"; then
#                  echo "I am in SLA"
#               else
#                  echo "I am outside of SLA"
#               fi
function util::isInSLA() # app env
{
   local app=$1
   local env=$2
   local SLAresults=0
   local currentHour=0
   local currentDay=0

   currentDay=$( date +%w )
   currentHour=$( date +%H )
   currentMin=$( date +%M )

   # Identify the times when the environment is not in SLA time
   # production in SLA 24/7 except for mainence window
   if [[ "$env" == "prd" ]]; then
      # IH/Myu will remain in SLA during maint window
      if [[ "$app" == "fs" ]]; then
         # Describe sunday maint window, some cycles go past top of the hour a bit
         if (( 10#$currentDay == 0 && 10#$currentHour > 5 && ( 10#$currentHour < 14  || ( 10#$currentHour == 14 && 10#$currentMin < 20 ) ) )); then
           SLAresults=1
         fi
      elif [[ "$app" != "ih" ]]; then
         # Describe sunday maint window, some cycles go past top of the hour a bit
         if (( 10#$currentDay == 0 && 10#$currentHour > 5 && ( 10#$currentHour < 12 || ( 10#$currentHour == 12 && 10#$currentMin < 20 ) ) )); then
           SLAresults=1
         fi
      fi
   elif [[ "$env" == "rpt" ]]; then
      # allow time for RPT DB Snapshot process
      if (( 10#$currentHour < 4  )); then
         SLAresults=1
      fi
   else  #All non-prod envs
      if (( (10#$currentHour < 7 || 10#$currentHour > 17 ) || 10#$currentDay == 0 || 10#$currentDay == 6 )); then
         SLAresults=1
       fi
   fi
   # Also filter out invalid combination of app/env from looping scripts.
   if [[ "$app" != "fs" && ( "$env" == "rpt" || "$env" == "qrpt" ) ]]; then
       SLAresults=1
   elif [[ ( "$env" = "trn" || "$env" = "cls" ) && "$app" == "ih" ]]; then
       SLAresults=1
   fi

   return $SLAresults
}

function util::sendNotification() #SeverityCode, subject, body, ToList, FromName
{
   local SeverityCode="$1"
   local subject="$2"
   local body="$3"
   local ToList="$4"
   local FromName="$5"

   #Pager notification only for prd, fix and rpt
   case "${SeverityCode}" in
      "CRITICAL")
         echo -e "$body" | mailx -s "$SeverityCode: $subject" "$PAGER_NOTIFICATION"
         echo -e "$body" | mailx -s "$SeverityCode: $subject" "$EMAIL_NOTIFICATION"
         ;;
      "WARN")
         echo -e "$body" | mailx -s "$SeverityCode: $subject" "$EMAIL_NOTIFICATION"
         ;;
      "FYI")
         echo -e "$body" | mailx -s "$SeverityCode: $subject" "$EMAIL_NOTIFICATION"
         ;;

   esac

   #setup a new var to hold the final ToLIST         -- default = pssa-l, if TOLIST exists, append it to pssa-l
   #setup a new var to hold the final FromList(opt)  -- ex) noreply

}

function util::setLogFile()  #logfilepath
{
  gblLogFilePath="$1"

}
function util::log() # messageType,  MessageString
{
  local messageType="$1"
  local messageString="$2"
  local currentScript="$0"
  local currentDate="$(date +%y/%m/%d-%H:%M:%S )"
  local RED='\033[0;31m'
  local GREEN='\033[0;32m'
  local YELLOW='\033[0;33m'
  local NC='\033[0m' # No Color
  if [[ -n "$gblLogFilePath" ]]; then
     maintLogFile="$gblLogFilePath"
  else
    if [[ -z "$maintLogFile" ]]; then
       maintLogFile="$MAINT_LOG_FILE"
    fi
  fi
  if [[ "$currentScript" == *bash* ]]; then
    currentScript=""
  fi

  if [[ "$debugFlag" == "y" && "$messageType" == "DEBUG" ]]; then
    # If in debug mode, display message to screen
    echo "    ${messageType}: $messageString"
    #local test=1
  elif [[ "$messageType" != "DEBUG" ]]; then
    if [[ "$messageType" == "ERROR" ]]; then
      echo -e "${RED}*${messageType}${NC}: $messageString"
    elif [[ "$messageType" == "WARNING" ]]; then
      echo -e "${YELLOW}${messageType}${NC}: $messageString"
    else
      echo -e "  ${GREEN}${messageType}${NC}: $messageString"
    fi
  fi
  # all logs types are written to file
  echo "$currentDate - $currentScript > $messageType: $messageString" >> $maintLogFile

}

## Use for monitoring scripts that will run as special DB user, and not PSoft Access/Schema user
function util::runMonitorSQL() #app, env, sqlString, out sqlResult
{
   local app="$1"
   local env="$2"
   local query="$3"
   local varSqlResult=$4
   local tnsName=""
   local appOwner=""
   local appPasswd=""
   local sqlResult=""
   local connectString=""

   # Upper case
   tnsName="${app^^}${env^^}"
   # get actual owner from global variable config: mainDefault.sh
   dbUser="$DB_MONITOR_USER"

   sec::getGenSecurity "monitordb" monitorPass

   connectString="${dbUser}/${monitorPass}@${tnsName}\n set heading off\n $query;\nexit"
   util::log "DEBUG" "util::runSQL for $app$env sqlstring: $query"
   sqlResult="$( echo -e "$connectString" | $ORACLE_HOME/bin/sqlplus -S )"
   sqlErrorCode=$?
   util::log "DEBUG" "util::runSQL for $app$env sqlresult: $sqlResult"
   sqlResult="${sqlResult##*( )}"
   sqlResult="${sqlResult:1}"
   eval "$varSqlResult"'="${sqlResult}"'
   if [[ "$sqlResult" == *ORA-* ]]; then
     return 1
   else
     return $sqlErrorCode
   fi

}

## Wrapper to run a DMS script on a scheduler
function util::runDMS() # app, #env, DMS file, bootstrap=N
{
  local app="$1"
  local env="$2"
  local dbName="${app^^}${env^^}"
  local dmsFile="$3"
  local bootstrap="$4"
  local runHost=""
  local currentDateTime="$( date +%y%m%d_%H%M_%N )"
  local configFile="/psoft/admin/tmp/.dmxcfg${currentDateTime}.txt"
  local dmsResult=""
  local dmsExitCode=""
  local schedulerList=()
  local DBUser="PS_${app^^}"
  local DMSPass=""
  local DMSUser="UMSUPER"
  local DMSLogDir="/psoft/logs/$app$env/dms"

  mkdir -p $DMSLogDir

  if [[ "$bootstrap" == "Y" || "$bootstrap" == "bootstrap" ]]; then
    DMSUser=$DBUser
    # DB Access PWD
    sec::getAppEnvDBSecurity "$app" "$env" DMSPass
    util::log "DEBUG" "Running DMS $dmsFile in Bootstrap mode"
  else
    # Get the UMSUPER password
    sec::getGenSecurity "ps" DMSPass
    util::log "DEBUG" "Running DMS $dmsFile in User mode"
  fi

  local majorToolsVer=$( inventory::getCurrentToolsAppEnv "$app" "$env" "prc")
  inventory::getDomainsByEnv "$app" "$env" "prc" "" "$majorToolsVer" schedulerList
  # Grab the first scheduler, we'll run it there
  inventory::getDomainInfo "${schedulerList[0]}" "" "$majorToolsVer" prcAttribs
  runHost="${prcAttribs[$DOM_ATTR_HOST]}"
  util::log "DEBUG" "Using $runHost from domain ${schedulerList[0]} to run psdmtx"

  #Write config
  cat <<EOT > $configFile
-CT ORACLE
-CD ${dbName}
-CO ${DMSUser}
-CP "${DMSPass}"
-FP ${dmsFile}
EOT

  util::log "INFO" "Starting DMS $dmsFile on $app$env..."
  # Now run script on scheduler
  util::log "DEBUG" "Running DMS: $SSH_CMD $runHost \"source ${app}${env}.env && PS_SERVER_CFG=\$PS_CONFIG_HOME/appserv/prcs/${app}${env}/psprcs.cfg psdmtx $configFile\""
  dmsResult=$( $SSH_CMD $runHost "source ${app}${env}.env && PS_SERVDIR=$DMSLogDir && PS_SERVER_CFG=\$PS_CFG_HOME/appserv/prcs/${app}${env}/psprcs.cfg psdmtx $configFile 2>&1" )
  dmsExitCode=$?
  util::log "DEBUG" "DMS Exit Code: $dmsExitCode, Result: $dmsResult"
  if (( $dmsExitCode != 0 )); then
    return 1
  else
    return 0
  fi
}

# Wrapper to run an AE on scheduler
function util::runAE() # app, #env, AE Program, RunControl_name
{
  local app="$1"
  local env="$2"
  local dbName="${app^^}${env^^}"
  local aeProgram="$3"
  local runControl="$4"
  local runHost=""
  local currentDateTime="$( date +%y%m%d_%H%M_%N )"
  local configFile="/psoft/admin/tmp/.aecfg${currentDateTime}.txt"
  local dmsResult=""
  local dmsExitCode=""
  local schedulerList=()
  local DBUser="PS_${app^^}"
  local AEPass=""
  local AEUser="UMSUPER"
  local AELogDir="/psoft/logs/$app$env/ae"

  mkdir -p $AELogDir

  if [ -z "$runControl" ]; then
    runControl="pssa"
  fi
  # Get the UMSUPER password
  sec::getGenSecurity "ps" AEPass
  util::log "DEBUG" "Running AE Program $aeProgram as $AEUser"

  local majorToolsVer=$( inventory::getCurrentToolsAppEnv "$app" "$env" "prc")
  inventory::getDomainsByEnv "$app" "$env" "prc" "" "$majorToolsVer" schedulerList
  # Grab the first scheduler, we'll run it there
  inventory::getDomainInfo "${schedulerList[0]}" "" "$majorToolsVer" prcAttribs
  runHost="${prcAttribs[$DOM_ATTR_HOST]}"
  util::log "DEBUG" "Using $runHost from domain ${schedulerList[0]} to run psae"

  #Write config
  cat <<EOT > $configFile
-CT ORACLE
-CD ${dbName}
-CO ${AEUser}
-CP "${AEPass}"
-R ${runControl}
-AI ${aeProgram}
EOT

  util::log "INFO" "Starting program $aeProgram on $app$env..."
  # Now run script on scheduler
  util::log "DEBUG" "Running AE: $SSH_CMD $runHost \"source ${app}${env}.env && PS_SERVER_CFG=\$PS_CONFIG_HOME/appserv/prcs/${app}${env}/psprcs.cfg psae $configFile\""
  aeResult=$( $SSH_CMD $runHost "source ${app}${env}.env && PS_SERVDIR=$AELogDir && PS_SERVER_CFG=\$PS_CFG_HOME/appserv/prcs/${app}${env}/psprcs.cfg psae $configFile 2>&1" )
  aeExitCode=$?
  util::log "INFO" "AE Results: $aeResult"
  util::log "DEBUG" "AE Exit Code: $aeExitCode, Result: $aeResult"
  if (( $aeExitCode != 0 )); then
    return 1
  else
    return 0
  fi
}

#END
