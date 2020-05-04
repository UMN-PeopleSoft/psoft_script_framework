# Library: domain
# Script: domain.sh
# Purpose: functions to support specific tasks to stop/start a domain.
# CB: Nate Werner
# Created: 11/26/2017
#
# Function (for core psoft domain state changes, excludes changes
#           to F5, oem)
#   startWebDomain(domainName, majorToolsVer, enc_vault_pass)
#      Starts a PSoft Weblogic domain (via psadmin) and dependent Coherence Cache servers
#
#   stopWebDomain(domainName, majorToolsVer, stopCoherence, enc_vault_pass)
#      Stops a Psoft Weblogic domain (via psadmin) and optionally the chache server
#
#   startAppDomain(domainName, majorToolsVer, clearCache, serialBoot, encrypt_vault_pas)
#      Starts a Psoft App server (tuxedo) domain with options to clear cache,
#      do a serial boot.
#
#   stopAppDomain(domainName, majorToolsVer, clearCache, forceStop, encrypt_vault_pas)
#      Stops a Psoft App server (Tuxedo) domain with options to clear cache
#      and initiate a forced shutdown, instead of gracefull shutdown.
#
#   startSchedDomain(domainName, majorToolsVer, enc_vault_pass)
#      Starts a Process Scheduler.  Will always clear cache on boot
#
#   stopSchedDomain(domainName, majorToolsVer, enc_vault_pass)
#      Stops a process Scheduler. Will attempt a gracefull shutdown, with 2 min
#      timeout, after whitch it will do a forced shutdown.
#
#######
#   startTuxDomain(domainName, majorToolsVer, clearCache, serialBoot, encrypt_vault_pas)
#      called by startAppDomain and startSchedDomain to handle Tuxedo domain start
#
#   stopTuxDomain(domainName, majorToolsVer, clearCache, forceStop, encrypt_vault_pas)
#      called by stopAppDomain and stopSchedDomain to handle Tuxedo domain stop
####################

# Sourced libraries
# Standard env setup
if [ -z "$BOOTSTRAP_LOADED" ]; then
  currentPath="$( cd "$(dirname "$0")" && pwd )"
  source ${currentPath%${currentPath#*scripts*/}}library/bootstrap.sh
fi

# load domain tools and utilities
source $LIB_HOME/utilities.sh
source $LIB_HOME/security.sh

function __clearAppCache() #domainName
{
  local domainName=$1

  if [ -e $PS_CFG_HOME/appserv/$domainName/CACHE/ ]; then
    timeout --signal=SIGKILL 20s bash -c "rm -rf $PS_CFG_HOME/appserv/$domainName/CACHE/* > /dev/null 2>&1"
    util::log "DEBUG" "${domainName}: Cleared App Server Cache, return code: $?"
    util::log "INFO" "${domainName}: Cleared App Server Cache."
  fi
}

function __clearSchedCache() #domainName
{
  local domainName=$1

  if [ -e $PS_CFG_HOME/prcserv/$domainName/CACHE/ ]; then
    timeout --signal=SIGKILL 20s bash -c "rm -rf $PS_CFG_HOME/prcserv/$domainName/CACHE/* > /dev/null 2>&1"
    util::log "DEBUG" "${domainName}: Clearing Scheduler Server Cache, return code: $?"
  fi
}

function __checkDBState() # appEnv, dbUpResult
{
  local appEnv=$1
  local dbUpResult=$2
  local dbState=""
  local SQLResult

  # split apart
  local app="${appEnv:0:2}"
  local env="${appEnv:2}"
  util::log "DEBUG" "${appEnv}: Running DB Check"
  util::runSQL "$app" "$env" "select TOOLSREL from PSSTATUS" SQLResult
  if [[ $? -eq 0 ]];then
     util::log "DEBUG" "${appEnv}: DB Check Result: $SQLResult"
     if [[ "$SQLResult" == *8.5* ]]; then
        dbState="running"
     else
        dbState="down"
     fi
     eval "$dbUpResult"'="${dbState}"'
     return 0
  else
    util::log "ERROR" "Unable to determine DB state"
    return 1
  fi
}

function __fixIPC() # domainName, envFile, IPCCommandStringOutput
{
  local domainName="$1"
  local envFile="$2"
  local ipcCommandOutput="$3"

  local configureResult=""
  local configureCode=0

  local isFailed=$(echo $ipcCommandOutput | grep "IPC resources failed")
  util::log "DEBUG" "${domainName}: IPC Check result: $isFailed"
  if [ -n "$isFailed" ]; then
    # failed cleanup, manually clear resources
    local SM=$(echo "$ipcCommandOutput" | sed -n '/Shared Memory/,/^$/p' | grep -o "[[:digit:]]*")
    for sharedmem in $SM; do
      ipcrm -m $sharedmem >/dev/null
    done
    local MQ=$(echo "$ipcCommandOutput" | sed -n '/Message Queues/,/^$/p' | grep -o "[[:digit:]]*")
    for messagequeue in $MQ; do
      ipcrm -q $messagequeue >/dev/null
    done
    local SEM=$(echo "$ipcCommandOutput" | sed -n '/Semaphores/,/^$/p' | grep -o "[[:digit:]]*")
    for semaphore in $SEM; do
       ipcrm -s $semaphore >/dev/null
    done
    # Reconfig domain to generate new queue ids
    if [[ "${domainName:0:1}" == "a" ]]; then
      configureResult=$(timeout --signal=SIGKILL 120s bash -c "source $envFile && psadmin -c configure -d $domainName 2>&1")
      configureCode=$?
    else
     configureResult=$(timeout --signal=SIGKILL 120s bash -c "source $envFile && psadmin -p configure -d $domainName 2>&1")
     configureCode=$?
    fi
    util::log "DEBUG" "${domainName}: Running psadmin configure -d $domainName, ExitCode: $ipcCode, Results: $ipcResult"
    util::log "WARNING" "${domainName}: IPC Issue fixed after failed cleanup."
  fi
  # IPC issue cleared up for next boot
}

function __stopRMIServer() # domainName
{
  local domainName=$1
  local rmiPort=""
  local rmiPrcsID=""

  util::log "DEBUG" "${domainName}: Stopping RMI service"
  # Get port # in config file
  if [[ "${domainName:0:1}" == "a" || "${domainName}" == *"ren" ]]; then
    rmiPort=$(grep "Remote Administration Port=" $PS_CFG_HOME/appserv/$domainName/psappsrv.cfg | awk -F= '{ print $2 }')
  else
    rmiPort=$(grep "Remote Administration Port=" $PS_CFG_HOME/prcserv/$domainName/psprcs.cfg | awk -F= '{ print $2 }')
  fi
  if [ -n "$rmiPort" ]; then
    local rmiPrcsID=$(netstat -anp 2>/dev/null | grep "$rmiPort" | grep "LISTEN " | awk '{ print $7 }' | awk -F/ '{print $1}')
    util::log "DEBUG" "${domainName}: Looking for RMI server $rmiPort with process ID $rmiPrcsID"
    if [ -n "$rmiPrcsID" ]; then
      util::log "DEBUG" "${domainName}: Stopping RMI server with process ID $rmiPrcsID"
      kill -9 $rmiPrcsID
    fi
  fi
  # Also stop the rmiregistry running on port 1099, default.  This is a tools bug
  rmiPrcsID=$( ps -ef | grep "rmiregistry 1099" | grep -v grep | awk '{ print $2 }' )
  if [ -n "$rmiPrcsID" ]; then
    util::log "DEBUG" "${domainName}: Stopping the buggy RMI server using wrong port, with process ID $rmiPrcsID"
    kill -9 $rmiPrcsID
  fi

}

function __startCoherenceCacheServers()
{
  local domainName=$1
  local webDomainPath="$PS_CFG_HOME/webserv/$domainName"
  local serverCount=0
  local serverUp=0
  local hostList=()
  local currentTime="$(date +%H:%M)"
  local hostSeq=0
  local currHostSeq=0
  local serverResult=""
  local cacheStatus=""

  # First see if the web domain runs with cache servers
  if [ -e $webDomainPath/config/coherence-pia.xml ]; then
    util::log "DEBUG" "${domainName}: Web Domain using Coherence, checking cache servers."
    # Extract list of hosts the cache servers are running on
    hostList=( $(grep -B1  -e '08</port>' -e '58</port>' $webDomainPath/config/coherence-pia.xml | grep address | awk -F '[<>]' '/address/{ print $3 }') )
    serverCount=${#hostList[@]}
    currHostSeq=$(hostname -s | tail -c2 | cut -c1)

    # Loop through all the cache server in this cluster and see if they are running
    for eachHost in "${hostList[@]}"; do
      # return the start time of cache server, empty is not running
      cacheStatus=$(ssh -oStrictHostKeyChecking=no $eachHost ps -ef | grep "java" | grep "/${domainName%?}" | grep -v "grep" | grep "DefaultCacheServer" | awk '{ print $5 }')
      if [ -n "${cacheStatus}" ]; then
        util::log "DEBUG" "${domainName}: Cache server running on $eachHost"
        # see if it just started within the last minute
        if [[ "${cacheStatus}" == "$currentTime" ]]; then
          # could still be booting, pause till the pia domain can connect
          util::log "DEBUG" "${domainName}: Pausing boot until cache server on $eachHost is started"
          sleep 20
        fi
      else
        hostSeq=${eachHost:(-1)}
        if [[ $currHostSeq -ne $hostSeq ]]; then
          # give the web host not running the cache server lower priority to start cache server
          # this is to ensure in parallel boots, the host with cache server does the boot
          sleep 3
          # now recheck if other web server started it
          cacheStatus=$(ssh -oStrictHostKeyChecking=no $eachHost ps -ef | grep "java" | grep "/${domainName%?}" | grep -v "grep" | grep "DefaultCacheServer" | awk '{ print $5 }')
          if [ -n "${cacheStatus}" ]; then
            # another web domain starting in parallel is starting cace server,
            #   wait till it is fully booted
            util::log "DEBUG" "${domainName}: Pausing boot until cache server on $eachHost is started."
            sleep 13
          else
            # no one else is starting it, boot it up
            util::log "INFO" "${domainName}: Starting Cache server on $eachHost."
            serverResult=$(ssh -oStrictHostKeyChecking=no $eachHost $PS_CFG_HOME/webserv/${domainName%?}$hostSeq/bin/startCoherence.sh)
            # now wait till boot is completed
            sleep 15
          fi
        else
          # cache server is running on same host (local)
          util::log "INFO" "${domainName}: Starting Cache server on current host $eachHost."
          serverResult=$( $webDomainPath/bin/startCoherence.sh )
          sleep 15
        fi
      fi
    done
    # End loop of each cache server
  fi
}

function __stopCoherenceCacheServer()
{
  local domainName=$1
  local webDomainPath="$PS_CFG_HOME/webserv/$domainName"
  local serverResult=""

  if [ -e $webDomainPath/bin/stopCoherence.sh ]; then
    util::log "INFO" "${domainName}: Stopping Cache server on current host"
    serverResult=$( $webDomainPath/bin/stopCoherence.sh )
    util::log "DEBUG" "${domainName}: StopCoherence Results: $?  $serverResult"
  fi
}

# Make sure all TUX processes are down after a stop
function __checkTUXProcesses() #domainName
{
  local domainName=$1
  local results=""
  local leftover=""
  local jshIDS=""

  # first see if anything is running
  local leftover=$( ps -ef | grep "$domainName/" | grep -v grep | grep -v "domain::stop" )
  if [ -z "$leftover" ]; then
    util::log "DEBUG" "${domainName}: checkTUXProcesses: Clean, all stopped"
    # all clean
    return 0
  else
    # first, make sure they're not still shutting down
    util::log "DEBUG" "${domainName}: checkTUXProcesses: Still running, waiting 2 secs: $leftover"
    sleep 2
  fi
  # now lets take action
  # first see if there is a JSL process, get PID
  leftover=$( ps -ef | grep "$domainName/" | grep JSL | awk '{ print $2 }' )
  if [ -n "$leftover" ]; then
    util::log "DEBUG" "${domainName}: checkTUXProcesses: Domain did not stop properly, cleaning processes: $leftover"
    # If JSL is running still, kill the JSHs first since the parent ID is the only association
    jshIDS=$( ps --ppid $leftover | grep -v PID | awk '{ print $1 }' )
    if [ -n "$jshIDS" ]; then
      util::log "DEBUG" "${domainName}: checkTUXProcesses: Cleaning JSl/JSH: $jshIDS"
      results=$( parallel -j 10 kill -9 {} ::: $jshIDS )
    fi
  else
    # JSL is down, could JSHs be running.  They will have a parent id of 1
    # this only happens if JSL is down, safe to filter all JSHs.
    jshIDS=$( ps --ppid 1 | grep JSH | awk '{ print $1 }' )
    if [ -n "$jshIDS" ]; then
      util::log "DEBUG" "${domainName}: checkTUXProcesses: Cleaning JSl/JSHi: $jshIDS"
      results=$( parallel -j 10 kill -9 {} ::: $jshIDS )
    fi
  fi
  # Clean up any other existing processes
  leftover=$( ps -ef | grep "$domainName/" | grep -v "domain::stop" | grep -v "TUXdown" | grep -v "PSCHED" | grep -v "maint" | grep -v grep | awk '{ print $2 }' )
  if [ -n "$leftover" ]; then
    util::log "DEBUG" "${domainName}: checkTUXProcesses: Cleaning remaining domain processes: $leftover"
    results=$( parallel -j 10 kill -9 {} ::: $leftover )
    return 2
  fi
  # all clean
  return 0
}

# Make sure there are no old in-flight stop/start commands running
#    before stopping/starting
function __cleanStuckTUXCommands() #domainName
{
   local domainName=$1
   local results=""

   # pause to allow processes to finish stopping
   sleep 1
   # look for hung processes to stop/start.  exclude those within same minute
   local curTime=$( date +%H:%M )
   local stuckList=$( ps -ef | grep -E "boot|psadmin|tmshutdown" | grep -v grep | grep "$domainName" | grep -v "$curTime" | awk '{ print $2 }' )

   # now kill off the stuck processes
   if [ -n "$stuckList" ]; then
     util::log "INFO" "${domainName}: Clearing old stuck processes: $stuckList"
     results=$( parallel -j 10 kill -9 {} ::: $stuckList )
     util::log "DEBUG" "${domainName}: Cleanup Results: $?"
   fi
   return 0
}

function __pauseIBNode() #domainName
{
   local domainName="$1"
   local startDayofWeek startSeconds startDay startDate
   local endDayofWeek endSeconds endDay endDate
   local IBstartSeconds
   local IBendSeconds
   local masterSQLCheck
   local AppEnv=""
   local SQLResult
   local addPauseSQL

   # get app/env code
   __parseAppEnv "$domainName" AppEnv
   # split apart
   local app="${AppEnv:0:2}"
   local env="${AppEnv:2}"

   # Determine if a master IB domain
   masterSQLCheck="select * from PSAPMSGDOMSTAT where DOMAIN_STATUS = 'A' AND IB_SLAVEMODE = 0 AND APPSERVER_PATH like '%${domainName}%'"
   util::log "DEBUG" "${domainName}: IB Master domain check"
   util::runSQL "$app" "$env" "$masterSQLCheck" SQLResult
   sqlCode=$?
   util::log "DEBUG" "${domainName}: IB Master domain check results: $sqlCode : $SQLResult"
   if [[ -n "$SQLResult" && $sqlCode -eq 0 && ! "$SQLResult" == *"no rows selected"* ]]; then
     # returned a row, this is a master IB, pause the domain
     ### Calculate fields for pause duration
     # current date/time in seconds/epoc
     startSeconds=$( date +%s )
     # current date/end date
     startDate=$( date +%m/%d/%Y )
     # Today at 12am in seconds
     startDay=$( date --date=$startDay +%s )
     # 0 based day of week
     startDayofWeek=$( date +%w )
     # pause will end in x seconds
     endSeconds=$( date --date='+10 minutes' +%s )
     endDate=$( date --date='+10 minutes' +%m/%d/%Y )
     endDay=$( date --date=$endDate +%s )
     endDayofWeek=$( date --date='+10 minutes' +%w )

     IBstartSeconds=$( echo "$startSeconds - $startDay" | bc )
     IBendSeconds=$( echo "$endSeconds - $endDay" | bc )

     addPauseSQL=$(cat <<EOF
SELECT VERSION, OBJECTTYPENAME FROM PSLOCK WHERE OBJECTTYPENAME IN ('SPTM') FOR UPDATE OF VERSION;
UPDATE PSLOCK SET VERSION = VERSION + 1 WHERE OBJECTTYPENAME IN ('SPTM');
SELECT VERSION FROM PSSPTDEFN WHERE MSGSPTNAME = 'SINGLETON' UNION SELECT VERSION FROM PSSPTDEL WHERE MSGSPTNAME = 'SINGLETON';
DELETE FROM PSSPTDEFN WHERE MSGSPTNAME = 'SINGLETON';
DELETE FROM PSSPTIMES WHERE MSGSPTNAME = 'SINGLETON';
DELETE FROM PSSPTDEL WHERE MSGSPTNAME = 'SINGLETON';
INSERT INTO PSSPTIMES (MSGSPTNAME, STARTINGDAY, STARTINGSECOND, ENDINGDAY, ENDINGSECOND)   VALUES ('SINGLETON','$startDayofWeek', $IBstartSeconds, '$endDayofWeek', $IBendSeconds);
INSERT INTO PSSPTDEFN (MSGSPTNAME, VERSION) SELECT 'SINGLETON', VERSION FROM PSLOCK WHERE OBJECTTYPENAME IN ('SPTM');
UPDATE PSVERSION SET VERSION = VERSION + 1 WHERE OBJECTTYPENAME = 'SYS';
UPDATE PSLOCK SET VERSION = (SELECT VERSION FROM PSLOCK WHERE OBJECTTYPENAME IN ('SPTM')) WHERE OBJECTTYPENAME = 'SPTM';
UPDATE PSVERSION SET VERSION = (SELECT VERSION FROM PSLOCK WHERE OBJECTTYPENAME IN ('SPTM')) WHERE OBJECTTYPENAME = 'SPTM';
COMMIT
EOF
)

     util::log "DEBUG" "${domainName}: Updating IB Pause Tables"
     util::runSQL "$app" "$env" "$addPauseSQL" SQLResult
     sqlCode=$?
     util::log "DEBUG" "${domainName}: Updating IB Pause Tables results: $sqlCode : $SQLResult"
     if [[ -n "$SQLResult" && $sqlCode -eq 0 ]]; then
       util::log "INFO" "$domainName : Paused IB Master domain"
     else
       util::log "ERROR" "$domainName : Unable to pause IB Master domain: $sqlCode : $SQLResult"
     fi
   elif [[ "$SQLResult" == *"no rows selected"* ]]; then
     util::log "DEBUG" "${domainName}: Skipping IB Pause, not a master domain"
     return 0
   else
     util::log "ERROR" "$domainName : Unable to determine if master IB domain: $sqlCode : $SQLResult"
     return 1
   fi
}

function __resumeIBNode() #domainName
{
   local domainName="$1"
   local masterSQLCheck
   local AppEnv=""
   local SQLResult
   local removePauseSQL

   # get app/env code
   __parseAppEnv "$domainName" AppEnv
   # split apart
   local app="${AppEnv:0:2}"
   local env="${AppEnv:2}"

   # Determine if a master IB domain
   masterSQLCheck="select * from PSAPMSGDOMSTAT where DOMAIN_STATUS = 'A' AND IB_SLAVEMODE = 0 AND APPSERVER_PATH like '%${domainName}%'"
   util::log "DEBUG" "${domainName}: IB Master domain check"
   util::runSQL "$app" "$env" "$masterSQLCheck" SQLResult
   sqlCode=$?
   util::log "DEBUG" "${domainName}: IB Master domain check results: $sqlCode : $SQLResult"
   if [[ -n "$SQLResult" && $sqlCode -eq 0 && ! "$SQLResult" == *"no rows selected"* ]]; then

     removePauseSQL=$(cat <<EOF
SELECT VERSION, OBJECTTYPENAME FROM PSLOCK WHERE OBJECTTYPENAME IN ('SPTM') FOR UPDATE OF VERSION;
UPDATE PSLOCK SET VERSION = VERSION + 1 WHERE OBJECTTYPENAME IN ('SPTM');
SELECT VERSION FROM PSSPTDEFN WHERE MSGSPTNAME = 'SINGLETON' UNION SELECT VERSION FROM PSSPTDEL WHERE MSGSPTNAME = 'SINGLETON';
DELETE FROM PSSPTDEFN WHERE MSGSPTNAME = 'SINGLETON';
DELETE FROM PSSPTIMES WHERE MSGSPTNAME = 'SINGLETON';
DELETE FROM PSSPTDEL WHERE MSGSPTNAME = 'SINGLETON';
INSERT INTO PSSPTDEFN (MSGSPTNAME, VERSION) SELECT 'SINGLETON', VERSION FROM PSLOCK WHERE OBJECTTYPENAME IN ('SPTM');
UPDATE PSVERSION SET VERSION = VERSION + 1 WHERE OBJECTTYPENAME = 'SYS';
UPDATE PSLOCK SET VERSION = (SELECT VERSION FROM PSLOCK WHERE OBJECTTYPENAME IN ('SPTM')) WHERE OBJECTTYPENAME = 'SPTM';
UPDATE PSVERSION SET VERSION = (SELECT VERSION FROM PSLOCK WHERE OBJECTTYPENAME IN ('SPTM')) WHERE OBJECTTYPENAME = 'SPTM';
COMMIT
EOF
)

     util::log "DEBUG" "${domainName}: Clearing IB Pause Tables"
     util::runSQL "$app" "$env" "$removePauseSQL" SQLResult
     sqlCode=$?
     util::log "DEBUG" "${domainName}: Clearing IB Pause Tables results: $sqlCode : $SQLResult"
     if [[ -n "$SQLResult" && $sqlCode -eq 0 ]]; then
       util::log "INFO" "$domainName : Unpaused IB Master domain"
     else
       util::log "ERROR" "$domainName : Unable to unpause IB Master domain: $sqlCode : $SQLResult"
     fi
  elif [[ "$SQLResult" == *"no rows selected"* ]]; then
     util::log "DEBUG" "${domainName}: Skipping IB Pause, not a master domain"
     return 0
  else
     util::log "ERROR" "$domainName : Unable to determine if master IB domain: $sqlCode : $SQLResult"
     return 1
  fi
}

function __suspendFailoverSchedulers() #domainName
{
   local domainName="$1"
   local serverName="$2"
   local suspendSchedulerSQL
   local AppEnv=""
   local SQLResult

   # get app/env code
   __parseAppEnv "$domainName" AppEnv
   # split apart
   local app="${AppEnv:0:2}"
   local env="${AppEnv:2}"

   if [[ "$env" == "prd" && ( "$serverName" == "PSUNX2" || "$serverName" == "PSUNX4") ]]; then
     # Auto suspend the two failover schedulers
     if [[ "$serverName" == "PSUNX2" ]]; then
       suspendSchedulerSQL=$(cat <<EOF
UPDATE PSSERVERSTAT SET SERVERSTATUS = 2, SERVERACTION = 2, LASTUPDDTTM = CAST(SYSTIMESTAMP AS TIMESTAMP) WHERE SERVERNAME = 'PSUNX2';
COMMIT
EOF
)
     else
       suspendSchedulerSQL=$(cat <<EOF
UPDATE PSSERVERSTAT SET SERVERSTATUS = 2, SERVERACTION = 2, LASTUPDDTTM = CAST(SYSTIMESTAMP AS TIMESTAMP) WHERE SERVERNAME = 'PSUNX4';
COMMIT
EOF
)
     fi

     util::log "DEBUG" "${domainName}: Suspending server $serverName"
     util::runSQL "$app" "$env" "$suspendSchedulerSQL" SQLResult
     sqlCode=$?
     util::log "DEBUG" "${domainName}: Suspending server $serverName results: $sqlCode : $SQLResult"
     if [[ -n "$SQLResult" && $sqlCode -eq 0 && ! "$SQLResult" == *"no rows selected"* ]]; then
        util::log "INFO" "$domainName: Suspended server $serverName"
     else
        util::log "ERROR" "$domainName : Unable to suspended server $serverName: $sqlCode : $SQLResult"
     fi
   fi
}

# create an app/env code from domain name
function __parseAppEnv() #domainName, varAppEnv
{
   local domainName=$1
   local varAppEnv=$2
   local inAppEnv=""

   # trim app server 'a', to use for both app and schedulers
   if [[ "${domainName:0:1}" == "a" ]]; then
     domainName="${domainName:1}"
   fi
   inAppEnv="${domainName:0:5}"
   if [[ "$domainName" == *qrpt* ]]; then
     inAppEnv="${domainName:0:6}"
   fi
   if [[ "$domainName" == *ren* ]]; then
     if [[ "${domainName:0:2}" == "ps" ]]; then
       inAppEnv="ih${domainName:2:3}"
     fi
   fi
   util::log "DEBUG" "${1}: AppEnv Code: $inAppEnv"
   # Return string
   eval "$varAppEnv"'="${inAppEnv}"'
}

function __generateEnvFile() # appEnv, majorToolsVer (3 char), out envFile
{
   local appEnv=$1
   local majorToolsVer=$2
   local varEnvFile=$3
   local inEenvFile=""
   util::log "DEBUG" "${domainName}: Checking env file: $DOMAIN_BASE/${appEnv}_${majorToolsVer}.env"
   # see if a specific version is being used
   if [ -e $DOMAIN_BASE/${appEnv}_${majorToolsVer}.env ]; then
     inEnvFile="$DOMAIN_BASE/${appEnv}_${majorToolsVer}.env"
   else
     # use the default, most current
     inEnvFile="$DOMAIN_BASE/${appEnv}.env"
   fi
   util::log "DEBUG" "${domainName}: Environment File: $inEnvFile"
   # return string
   eval "$varEnvFile"'="${inEnvFile}"'
}

function __checkWeblogFiles() # domainName
{
  local domainName="$1"
  local logPath="$PS_CFG_HOME/webserv/$domainName/servers/PIA/logs"
  local match
  local debugMatch

  # pause for any nfs lag
  sleep 1
  # Verify servlet log files were created
  # If cache servers are not running, the log files are missing
  util::log "DEBUG" "${domainName}: Checking Log file $logPath/PIA_servlets0.log.0"
  if [[ ! -e "$logPath/PIA_servlets0.log.0" ]]; then
    util::log "ERROR" "$domainName: Web domain did not start properly, missing log files"
    return 1
  fi
  return 0
}

function __checkWeblogicUp() #domainName
{
  local domainName="$1"
  local domainHome="$PS_CFG_HOME/webserv/$domainName"
  local wlStatus=""

  wlStatus=$(timeout --signal=SIGKILL 20s bash -c "$domainHome/bin/singleserverStatus.sh 2>&1" )
  if [[ $wlStatus == *"Status Check Successful"* ]]; then
    util::log "DEBUG" "${domainName}: Web domain status check: UP"
    return 0
  else
    util::log "DEBUG" "${domainName}: Web domain status check: DOWN"
    util::log "DEBUG" "${domainName}: Web domain status output: $wlStatus"
    return 1
  fi
}

function __startWeblogicInstance() #domainName
{
  local domainName="$1"
  local domainHome="$PS_CFG_HOME/webserv/$domainName"
  local logPath="$domainHome/servers/PIA/logs"
  local wlStart=""
  local wlStartCode=0
  local currentTime="$(date +%m%d%Y_%H%M)"
  local prcsID=""
  local logRunCheck=""
  local logFailCheck=""
  local webstatus=""

  if  __checkWeblogicUp $domainName ; then
    # already running
    return 3
  fi

  # make sure process is down even if 'status' is down
  prcsID=$( ps -ef | grep java | grep weblogic.Server | grep "$domainName" | awk '{ print $2 }' )
  if [ -n "$prcsID" ]; then
    util::log "DEBUG" "${domainName}: Web domains status down but process runing, killing"
    kill -9 $prcsID
    sleep 1
  fi

  # rotate logs, so we have a clean log file to monitor
  util::log "DEBUG" "${domainName}: Rotating web domain logs to $currentTime"
  mv $logPath/PIA_stdout.log $logPath/PIA_stdout.log_$currentTime >/dev/null 2>&1
  mv $logPath/PIA_stderr.log $logPath/PIA_stderr.log_$currentTime >/dev/null 2>&1
  mv $logPath/VirusScan0.log $logPath/VirusScan0.log_$currentTime >/dev/null 2>&1

  # actually try to start domain in background
  util::log "DEBUG" "${domainName}: Web domain, calling startPIA.sh"
  wlStart=$(timeout --signal=SIGKILL 20s bash -c "$domainHome/bin/startPIA.sh 2>&1" )
  wlStartCode=$?
  util::log "DEBUG" "${domainName}: Web start PIA domain result: $wlStart, errorCode: $wlStartCode"

  # quickest start is 30 secs, will check after that time
  sleep 30
  # loop for what equates to 2 mins (5 sec x 24)
  i=0
  util::log "DEBUG" "${domainName}: Web domain, checking startup results"
  while [ $i -lt 24 ]; do
    # check log file for running
    logRunCheck=$( grep "Server state changed to RUNNING" $logPath/PIA_stdout.log )
    if [ -z "$logRunCheck" ]; then
      logFailCheck=$( grep "Server state changed to FAILED" $logPath/PIA_stdout.log )
      if [ -n "$logFailCheck" ]; then
         util::log "DEBUG" "${domainName}: Web domain failed to start, log result: $logFailCheck"
         return 1
      else
        # no start or fail, still starting, pause for next check
        util::log "DEBUG" "${domainName}: Web domain not yet started, waiting 10 secs"
        sleep 10
      fi
    else
      # success, verify services started
      util::log "DEBUG" "${domainName}: Web domain start successfully, checking domain status"
      __checkWeblogicUp $domainName
      return $?
    fi

    # increment loop/time limit
    i=$[$i+1]
  done
  # if at this point, the domain did not start in time
  util::log "DEBUG" "${domainName}: Web domain did not start in 4 mins 30 secs."
  return 2
}

function __stopWeblogicInstance() #domainName
{
  local domainName="$1"
  local domainHome="$PS_CFG_HOME/webserv/$domainName/"
  local wlStop=""

  util::log "DEBUG" "${domainName}: Running stopPIA.sh..."
  wlStop=$(timeout --signal=SIGKILL 40s bash -c "$domainHome/bin/stopPIA.sh 2>&1" )
  wlStopCode=$?
  util::log "DEBUG" "${domainName}: stopPIA results: $wlStop, error Code: $wlStopCode"
  if [[ $wlStopCode -ne 0 ]]; then
    # failed to stop, force down
    sleep 2
    util::log "DEBUG" "${domainName}: Web domain did not properly stop, forcing down"
    prcsID=$( ps -ef | grep java | grep weblogic.Server | grep "$domainName" | awk '{ print $2 }' )
    if [ -n "$prcsID" ]; then
      util::log "DEBUG" "${domainName}: Killing web domain process $prcsID"
      kill -9 $prcsID
    fi
    sleep 1
  fi
}

function __startShibSP() # "$domainName"
{
  local domainName="$1"
  local shibHome="/psoft/domains/shibSP"
  local shibspStart=""
  local shibspCode=""

  # skip if this domain is not setup with shib service
  if [ ! -e $shibHome/startShibd.sh ]; then
    return
  fi
  util::log "DEBUG" "${domainName}: Running startShibd.sh..."
  shibspStart=$(timeout --signal=SIGKILL 40s bash -c "$shibHome/startShibd.sh 2>&1" )
  shibspCode=$?
  if [[ $shibspCode -ne 0 ]]; then
     util::log "ERROR" "${domainName}: Failed to start shibSP service"
  fi
  util::log "DEBUG" "${domainName}: startShibd results: $shibspStart, error Code: $shibspCode"
  util::log "INFO" "${domainName}: Started the ShibSP Service"
}

function __startApacheProxy() # "$domainName"
{
  local domainName="$1"
  local domainHome="$PS_CFG_HOME/webserv/$domainName/"
  local proxyStart=""
  local proxyCode=""

  # Skip if this domain is not setup with apache proxy
  if [ ! -e $domainHome/bin/startShibProxy.sh ]; then
    return
  fi

  util::log "DEBUG" "${domainName}: Running startShibProxy.sh..."
  proxyStart=$(timeout --signal=SIGKILL 40s bash -c "$domainHome/bin/startShibProxy.sh 2>&1" )
  proxyCode=$?
  if [[ $proxyCode -ne 0 ]]; then
     util::log "ERROR" "${domainName}: Failed to start ShibProxy service"
  fi
  util::log "DEBUG" "${domainName}: startShibProxy results: $proxyStart, error Code: $proxyCode"
  util::log "INFO" "${domainName}: Started the Shib Apache Proxy Service"
}

function __stopShibSP() # "$domainName"
{
  local domainName="$1"
  local shibHome="/psoft/domains/shibSP"
  local shibspStart=""
  local shibspCode=""

  # skip if this domain is not setup with shib service
  if [ ! -e $shibHome/stopShibd.sh ]; then
    return
  fi

  util::log "DEBUG" "${domainName}: Running stopShibd.sh..."
  shibspStop=$(timeout --signal=SIGKILL 40s bash -c "$shibHome/stopShibd.sh 2>&1" )
  shibspCode=$?
  util::log "DEBUG" "${domainName}: stopShibd results: $shibspStop, error Code: $shibspCode"
  util::log "INFO" "${domainName}: Stopped the ShibSP Service"
}

function __stopApacheProxy() # "$domainName"
{
  local domainName="$1"
  local domainHome="$PS_CFG_HOME/webserv/$domainName/"
  local proxyStop=""
  local proxyCode=""

  # Skip if this domain is not setup with apache proxy
  if [ ! -e $domainHome/bin/stopShibProxy.sh ]; then
    return
  fi

  util::log "DEBUG" "${domainName}: Running stopShibProxy.sh..."
  proxyStop=$(timeout --signal=SIGKILL 40s bash -c "$domainHome/bin/stopShibProxy.sh 2>&1" )
  proxyCode=$?
  # can be slow to clean up
  sleep 1
  util::log "DEBUG" "${domainName}: stopShibProxy results: $proxyStop, error Code: $proxyCode"
  util::log "INFO" "${domainName}: Stopped the Shib Apache Proxy Service"

}

#################
#################

# Start PeopleSoft Weblogic Domains via psadmin
function domain::startWebDomain() # domainName, majorToolsVer, enc_vault_pass, debugFlag, maintLogFile, parallelseq
{
   local domainName="$1"
   local majorToolsVer="$2"
   ANSIBLE_VAULT="$3"
   debugFlag=$4
   maintLogFile="$5"
   PARALLEL_SEQ=$6
   local appEnv=""
   local envFile=""
   local bootResult=0
   local domainStatus=""
   local cachePath=""
   local webProcessID=""

   util::log "DEBUG" "${domainName}: Initiating StartWebDomain Function, thread $PARALLEL_SEQ"
   # generate an appenv code from domain name
   __parseAppEnv "$domainName" appEnv

   # make sure the tools version is only 3 chars
   majorToolsVer="${majorToolsVer:0:1}${majorToolsVer:2:2}"
   envFile="tools${majorToolsVer}.env"
   util::log "DEBUG" "${domainName}: Env File: $envFile"
   source $envFile

   if __checkWeblogicUp $domainName ; then
     util::log "WARNING" "$domainName: Domain is already running.  Skipping boot of domain."
   else
     # check if "not started" but web process in limbo state
     domainStatus=$(ps -ef | grep java | grep weblogic.Server | grep "${domainName}")
     if [ -n "$domainStatus" ]; then
       # running in limbo, kill
       util::log "WARNING" "$domainName: psadmin does not show down running, but found process, killing"
       webProcessID=$( echo $domainStatus | awk '{ print $2 }')
       kill -9 $webProcessID
     fi
     # clear cache
     if [ -n $PS_CFG_HOME ]; then
       cachePath="$PS_CFG_HOME/webserv/$domainName/applications/peoplesoft/PORTAL.war/*/cache"
       util::log "DEBUG" "${domainName}: Removing Web cache from $cachePath/*"
       rm -rf $cachePath/* > /dev/null 2>&1
       # clear diagnostic data
       rm -f $PS_CFG_HOME/webserv/$domainName/servers/PIA/data/*.DAT > /dev/null 2>&1
     fi

     __startCoherenceCacheServers "$domainName"

     __startWeblogicInstance $domainName

     # Startup the Shibboleth authentication layers
     if [[ "${domainName:0:2}" == "ih" && "${domainName:5:2}" != "ib" && "$domainName" != *ren* ]]; then
       __startShibSP "$domainName"
       __startApacheProxy "$domainName"
     fi

     bootResult=$?
     util::log "DEBUG" "${domainName}: Ran __startWeblogicInstance Results: $bootResult"
     if [[ $bootResult -eq 3 ]]; then
       util::log "INFO" "${domainName}: Domain is already running"
       return 1
     elif [[ $bootResult -eq 2 ]]; then
       util::log "ERROR" "${domainName}: Weblogic domain is not properly starting, timeout"
       return 1
     elif [[ $bootResult -eq 1 ]]; then
       util::log "ERROR" "${domainName}: Weblogic domain failed to start"
       return 1
     else
       # success
       if __checkWeblogFiles "$domainName" ; then
         util::log "INFO" "${domainName}: Web Domain started successfully."
         # Restart lsyncd after domain start to ensure it's running
         sudo systemctl restart lsyncd.service
         return 0
       else
         sleep 1
         if __checkWeblogFiles "$domainName" ; then
           util::log "INFO" "${domainName}: Web Domain started successfully."
           # Restart lsyncd after domain start to ensure it's running
           sudo systemctl restart lsyncd.service
           return 0
         else
           util::log "WARNING" "${domainName}: Weblogic domain is not properly starting, attempting to restart domain"
           # shutdown again
           domain::stopWebDomain "$domainName" "$2" 0 "$ANSIBLE_VAULT" "$debugFlag" "$maintLogFile" "$PARALLEL_SEQ"
           __startWeblogicInstance $domainName
           bootResult=$?
           if [[ $bootResult -eq 0 ]]; then
             if __checkWeblogFiles "$domainName" ; then
                util::log "INFO" "${domainName}: Web Domain started successfully."
                # Restart lsyncd after domain start to ensure it's running
                sudo systemctl restart lsyncd.service
                return 0
             else
                util::log "ERROR" "${domainName}: Cannot get web domain to properly start after second attempt"
                return 1
             fi
           else
             util::log "ERROR" "${domainName}: Cannot get web domain to properly start after second attempt"
             return 1
           fi
         fi
       fi
     fi
   fi
}

function domain::stopWebDomain() # domainName, majorToolsVer, stopCoherence, enc_vault_pass, debugFlag, maintLogFile
{
  local domainName="$1"
  local majorToolsVer="$2"
  local stopCoherence=$3
  ANSIBLE_VAULT="$4"
  debugFlag=$5
  maintLogFile="$6"
  PARALLEL_SEQ=$7
  local envFile=""
  local domainStatus=""
  local webProcessID=""

  util::log "DEBUG" "${domainName}: Initiating StopWebDomain Function $PARALLEL_SEQ"

  # make sure the tools version is only 3 chars
  majorToolsVer="${majorToolsVer:0:1}${majorToolsVer:2:2}"
  envFile="tools${majorToolsVer}.env"
  util::log "DEBUG" "${domainName}: Env File: $envFile"
  source $envFile

  if __checkWeblogicUp $domainName; then
    # domain is running, shutdown

    __stopWeblogicInstance $domainName

    util::log "INFO" "${domainName}: Web domain stopped successfully."

    # Stop the Shibboleth authentication layers
    if [[ "${domainName:0:2}" == "ih" && "${domainName:5:2}" != "ib" && "$domainName" != *ren* ]]; then
      __stopShibSP "$domainName"
      __stopApacheProxy "$domainName"
    fi

    # optionally stop cache server in same domain
    if [[ $stopCoherence -eq 1 ]]; then
      __stopCoherenceCacheServer "$domainName"
    fi
    # clean up an obscure cache file that can sometimes cause bootup issues
    results=$( rm $PS_CFG_HOME/webserv/$domainName/applications/peoplesoft/META-INF/.WL_internal/cache/PSEMHUB.war/.classinfos/.cache.ser >/dev/null 2>&1 )
    return 0
  else
    util::log "WARNING" "${domainName}: Domain is already stopped.  Skipping shutdown of domain"
    # check if "stopped" but web process in limbo state
    sleep 2
    domainStatus=$(ps -ef | grep java | grep weblogic.Server | grep "${domainName}")
    if [ -n "$domainStatus" ]; then
      # running in limbo, kill
      webProcessID=$( echo $domainStatus | awk '{ print $2 }')
      util::log "WARNING" "${domainName}: Process still running, killing process $webProcessID."
      kill -9 $webProcessID
    fi
  fi

}

# Support both app and scheduler Tuxedo domain startup
function __startTuxDomain() #domainType, domainName, majorToolsVer, clearCache, serialBoot, forceBoot, enc_pass, debugFlag, maintLogFile
{
   local domainType="$1"
   local domainName="$2"
   local majorToolsVer="$3"
   local clearCache="$4"
   local serialBoot="$5"
   local forceBoot="$6"
   ANSIBLE_VAULT="$7"
   debugFlag=$8
   maintLogFile="$9"

   local dbStatus=""
   local appEnv=""
   local envFile=""
   local bootResult=""
   local checkResult=""
   local configResults=""
   local ipcResult=""
   local configCode=""
   local domainStatus=""
   local bootExit=""
   local bootTimeout=""
   local processName=""
   local typeString=""
   local typeFlag=""
   local bblCheck=""
   local cache_start=""
   local cache_end=""
   local cacheResult=""
   local cacheExitCode=""
   local runtime=""
   local posServerName=0
   local serverName=""

   # setup unique values for App vs Sched for psadmin command
   if [[ "$domainType" == "APP" ]]; then
     typeFlag="-c"
     bootTimeout="240s"
     processName="PSAPPSRV"
     typeString="App"
   else  # Scheduler
     typeFlag="-p"
     bootTimeout="720s"
     processName="PSPRCSRV"
     typeString="Scheduler"
     # Scrub server name from domainName
     posServerName=$( expr index "$domainName" PSUNX )
     posServerName=$(($posServerName - 1))
     serverName=${domainName:$posServerName}
     domainName=${domainName%PSUNX*}
   fi
   # Make sure the tempfs for cache dir exists
   mkdir -p /psoft/cache/$domainName

   util::setLogFile "$maintLogFile"

   # generate an appenv code from domain name
   __parseAppEnv "$domainName" appEnv
   util::log "DEBUG" "${domainName}: AppEnv Results: $appEnv"
   majorToolsVer="${majorToolsVer:0:1}${majorToolsVer:2:2}"
   __generateEnvFile "$appEnv" "$majorToolsVer" envFile
   source $envFile
   # make sure the tools version is only 3 chars
   util::log "DEBUG" "${domainName}: Env File: $envFile"
   if [[ "$domainType" == "APP" ]]; then
     export ULOGPFX=$PS_CFG_HOME/appserv/$domainName/LOGS/TUXLOG
   else  # Scheduler
     export ULOGPFX=$PS_CFG_HOME/appserv/prcs/$domainName/LOGS/TUXLOG
   fi

   domainStatus=$(ps -ef | grep "$processName" | grep "$domainName/")
   if [[ -n "$domainStatus" && $forceBoot -ne 1 ]]; then
     util::log "WARNING" "$domainName: Domain is already running.  Skipping boot of domain."
   else
     # check if DB is up
     #__checkDBState "$appEnv" dbStatus
     dbStatus="running"
     util::log "DEBUG" "${domainName}: DB Status: $dbStatus"

     if [[ "$dbStatus" == "running" ]]; then
       util::log "DEBUG" "${domainName}: DB $appEnv is running, clear to start domain"

       # make sure there are no residual processes still running from previous stop
       __checkTUXProcesses "$domainName"
       checkResult=$?
       if [[ $checkResult -eq 2 ]]; then
         if [[ -z "$domainStatus" ]]; then
           util::log "WARNING" "${domainName}: Invalid configuration state, auto-recovering domain and re-configuring..."
           # Had a shutdown in a bad state, and BBL was killed, reconfigure.
           configResults=$(timeout --signal=SIGKILL 40s bash -c "source $envFile && psadmin $typeFlag configure -d $domainName 2>&1")
           configCode=$?
           util::log "DEBUG" "${domainName}: Issues before booting, re-configure psadmin $typeFlag configure -d $domainName, ExitCode: $configCode, Results: $configResults"
           if [[ $configCode -ne 0 && $configCode -ne 255 ]]; then
             # one more configure attempt and IPC call
             ipcResult=$(timeout --signal=SIGKILL 120s bash -c "source $envFile && psadmin $typeFlag cleanipc -d $domainName 2>&1")
             configResults=$(timeout --signal=SIGKILL 40s bash -c "source $envFile && psadmin $typeFlag configure -d $domainName 2>&1")
             configCode=$?
             util::log "DEBUG" "${domainName}: Still more issues before booting, re-configure psadmin $typeFlag configure -d $domainName, ExitCode: $?, Results: $configResults"
           fi
         fi
       fi

       # clear cache if requested
       if [[ "$domainType" == "APP" ]]; then
         if [[ $clearCache -eq 1 && -z "$domainStatus" ]]; then
           __clearAppCache "$domainName"
         fi
         # Add support for preload cache
         cacheProject=$(grep "PreloadCache=" $PS_CFG_HOME/appserv/$domainName/psappsrv.cfg | awk -F= '{ print $2 }')
         if [[ -n "$cacheProject" && -z "$domainStatus" ]]; then
            # there is a preload cache project defined, run cache utility
            util::log "DEBUG" "${domainName}: Domain configured for pre-load cache, starting pre-load"
            export PS_SERVDIR=$PS_CFG_HOME/appserv/$domainName
            export PS_SERVER_CFG=$PS_CFG_HOME/appserv/$domainName/psappsrv.cfg
            cache_start=$(date +%s)
            # start the utility with a 5 minute timeout in case OS/DB hung
            cacheResult=$(timeout --signal=SIGKILL 300 bash -c "psadmutil -Preload $cacheProject 2>&1")
            cacheExitCode=$?
            cache_end=$(date +%s)
            util::log "DEBUG" "${domainName}: Preload cache results: $cacheResult, Exit Code: $cacheExitCode"
            runtime=$(python2.7 -c "print '%u:%02u' % ((${cache_end} - ${cache_start})/60, (${cache_end} - ${cache_start})%60)")
            if [ $cacheExitCode -eq 0 ]; then
               util::log "INFO" "${domainName}: Completed Pre-load cache in (min:sec): $runtime"
            else
               util::log "WARNING" "${domainName}: Failed to pre-load cache, results: $cacheResult, exit code: $cacheExitCode"
            fi
         fi
       else
          __clearSchedCache "$domainName"
       fi
       # Clear any stuck tux/tm commands
       if [ -z "$domainStatus" ]; then
         __cleanStuckTUXCommands "$domainName"
       fi

       ## Main Startup calls
       # start domain in serial mode
       bootResult=$(timeout --signal=SIGKILL $bootTimeout bash -c "source $envFile && psadmin $typeFlag start -d $domainName 2>&1")
       bootExit=$?
       util::log "DEBUG" "${domainName}: Running psadmin $typeFlag start -d $domainName, ExitCode: $bootExit, Results: $bootResult"

       sleep 2
       # Check various exit code and try to recover
       if [[ $bootExit -eq 137 ]]; then
         # Timed out on boot process, check to see if it is stuck starting the PSMONITORSRV process.
         # If this started, then the domain is started, don't throw error
         if [[ "$bootResult" == *PSMONITORSRV* && "$bootResult" != *processes* ]]; then
           util::log "WARNING" "${domainName}: Stuck boot process, connot get past Monitor Server, attempting second startup"
         else
           util::log "WARNING" "${domainName}: Timeout occurred starting domain, attempting second startup..."
         fi
         __stopTuxDomain "$domainType" "$domainName" "$3" "$clearCache" "1" "$ANSIBLE_VAULT" "$debugFlag" "$maintLogFile"
         configResults=$(timeout --signal=SIGKILL 40s bash -c "source $envFile && psadmin $typeFlag configure -d $domainName 2>&1")
         util::log "DEBUG" "${domainName}: Configuring domain, ExitCode: $?"
         bootResult=$(timeout --signal=SIGKILL $bootTimeout bash -c "source $envFile && psadmin $typeFlag start -d $domainName 2>&1")
         bootExit=$?
         util::log "DEBUG" "${domainName}: Running psadmin $typeFlag start -d $domainName, ExitCode: $bootExit, Results: $bootResult"
         if [[ $bootExit -eq 137 ]]; then
           util::log "ERROR" "${domainName}: Second startup timed out, not all services started, shutting domain back down, ExitCode: $bootExit, Results: $bootResult"
           __stopTuxDomain "$domainType" "$domainName" "$3" "$clearCache" "1" "$ANSIBLE_VAULT" "$debugFlag" "$maintLogFile"
           return 1
         fi
       fi
       if [[ $bootExit -eq 255 ]]; then
         # Config error, reconfigure and restart
         util::log "WARNING" "${domainName}: Domain seems to have an invalid configuration state, reconfiguring and restarting..."
         sleep 2
         __stopTuxDomain "$domainType" "$domainName" "$3" "$clearCache" "1" "$ANSIBLE_VAULT" "$debugFlag" $maintLogFile
         configResults=$(timeout --signal=SIGKILL 40s bash -c "source $envFile && psadmin $typeFlag configure -d $domainName 2>&1")
         util::log "DEBUG" "${domainName}: Configuring domain, ExitCode: $?"
         bootResult=$(timeout --signal=SIGKILL $bootTimeout bash -c "source $envFile && psadmin $typeFlag start -d $domainName 2>&1")
         bootExit=$?
         util::log "DEBUG" "${domainName}: Running psadmin $typeFlag start -d $domainName, ExitCode: $bootExit, Results: $bootResult"
       fi

       # success boot(0) or already started (40)
       if [[ $bootExit -eq 0 || $bootExit -eq 40 ]]; then
         if [[ $bootExit -eq 40 && -z "$domainStatus" ]]; then
           util::log "WARNING" "${domainName}: Appears to be already started or started twice at same time. Second start ignored."
           # let duplicate start finish before cleanup would kill it
           sleep 10
         fi
         # clean up any lingering/stuck shutdown commands
         __cleanStuckTUXCommands "$domainName"
         util::log "INFO" "${domainName}: $typeString domain started successfully."

         # Unpause IB Node if starting master IB
         if [[ "$domainName" == *ib* ]]; then
           __resumeIBNode "$domainName"
         fi

         if [[ "$domainType" == "SCHED" ]]; then
           __suspendFailoverSchedulers "$domainName" "$serverName"
         fi

         # BBL audit
         bblCheck=$(ps -ef | grep "$processName" | grep "$domainName/")
         if [ -z "$bblCheck" ]; then
            util::log "WARNING" "${domainName}: $processName check failed to find $processName process running after boot attempt"
         fi
         return 0
       elif [[ $bootExit -eq 5 && -z "$domainStatus" ]]; then
         util::log "INFO" "${domainName}: $typeString domain started successfully. Restarted any stopped services."
       elif [[ $bootExit -eq 5 ]]; then
         # common start error code
         if [[ "$bootResult" == *Duplicate* ]]; then
           #parallel startup occuring, domain started.
           util::log "WARNING" "${domainName}: Appears to be already started or started twice at same time. Second start ignored."
         else
           util::log "ERROR" "${domainName}: Startup failed, stopping domain, ExitCode: $bootExit, BootResults: $bootResult"
           __stopTuxDomain "$domainType" "$domainName" "$3" "$clearCache" "1" "$ANSIBLE_VAULT" "$debugFlag" "$maintLogFile"
           return 1
         fi
       else
         # 2nd failed attempt or all other error, consider the starup a failure.
         util::log "ERROR" "${domainName}: Startup failed, stopping domain, ExitCode: $bootExit, BootResults: $bootResult"
         __stopTuxDomain "$domainType" "$domainName" "$3" "$clearCache" "1" "$ANSIBLE_VAULT" "$debugFlag" "$maintLogFile"
         return 1
       fi
     else
       util::log "ERROR" "DB is down for domain $domainName"
       return 0
     fi
   fi

}

function __stopTuxDomain() #domainType domainName majorToolsVer clearCache forceStop enc_pass debugFlag maintLogFile
{
   local domainType="$1"
   local domainName="$2"
   local majorToolsVer="$3"
   local clearCache="$4"
   local forceStop="$5"
   ANSIBLE_VAULT="$6"
   debugFlag=$7
   maintLogFile="$8"
   local domainStatus=""
   local appEnv=""
   local envFile=""
   local shutdownResult=""
   local shutdownExit=""
   local checkResult=""
   local ipcCode=0
   local ipcResult=""
   local typeFlag=""

   # setup unique values for App vs Sched for psadmin command
   if [[ "$domainType" == "APP" ]]; then
     typeFlag="-c"
     processName="PSAPPSRV"
     typeString="App"
   else  # Scheduler
     # Scrub server name from domainName
     domainName=${domainName/PSUNX*}
     typeFlag="-p"
     processName="PSPRCSRV"
     typeString="Scheduler"
   fi

   # generate an appenv code from domain name
   __parseAppEnv "$domainName" appEnv
   majorToolsVer="${majorToolsVer:0:1}${majorToolsVer:2:2}"
   __generateEnvFile "$appEnv" "$majorToolsVer" envFile
   source $envFile
   # make sure the tools version is only 3 chars
   util::log "DEBUG" "${domainName}: Env File: $envFile"
   if [[ "$domainType" == "APP" ]]; then
     export ULOGPFX=$PS_CFG_HOME/appserv/$domainName/LOGS/TUXLOG
   else  # Scheduler
     export ULOGPFX=$PS_CFG_HOME/appserv/prcs/$domainName/LOGS/TUXLOG
   fi

   # check if domain is running
   domainStatus=$(ps -ef | grep "$processName" | grep "$domainName/")
   if [ -n "$domainStatus" ]; then

     # Pause IB Node if stopping master IB
     if [[ "$domainName" == *ib* ]]; then
       __pauseIBNode "$domainName"
     fi

     # Clear any stuck tux/tm commands
     __cleanStuckTUXCommands "$domainName"

     # all clear to initiate domain shutdown
     if [[ $forceStop -eq 1 ]]; then
       # force the domain down interrupting any inprocess requests
       util::log "DEBUG" "${domainName}: Running psadmin $typeFlag kill -d $domainName ..."
       shutdownResult=$(timeout --signal=SIGKILL 240s bash -c "source $envFile && psadmin $typeFlag kill -d $domainName 2>&1")
       shutdownExit=$?
       util::log "DEBUG" "${domainName}: Completed psadmin $typeFlag kill -d $domainName, ExitCode: $shutdownExit, Results: $shutdownResult"
     else
       # gracefull shutdown, wait for requests to complete
       util::log "DEBUG" "${domainName}: Running psadmin $typeFlag stop -d $domainName ..."
       shutdownResult=$(timeout --signal=SIGKILL 240s bash -c "source $envFile && psadmin $typeFlag stop -d $domainName 2>&1")
       shutdownExit=$?
       util::log "DEBUG" "${domainName}: Completed psadmin $typeFlag stop -d $domainName, ExitCode: $shutdownExit, Results: $shutdownResult"

       # if timed out, use forced shutdown.  timeout will return 124 if it times out
       if [[ $shutdownExit -eq 124 || $shutdownExit -eq 137 ]]; then
         util::log "WARNING" "${domainName}: Domain did not shutdown in time, timout occurred.  Attempting forced shutdown..."
         util::log "DEBUG" "${domainName}: Running psadmin $typeFlag kill -d $domainName ..."
         shutdownResult=$(timeout --signal=SIGKILL 360s bash -c "source $envFile && psadmin $typeFlag kill -d $domainName 2>&1")
         shutdownExit=$?
         util::log "DEBUG" "${domainName}: Completed psadmin $typeFlag kill -d $domainName, ExitCode: $shutdownExit, Results: $shutdownResult"
       fi
     fi
   fi
   # success shutdown(0) or already shutdown (40)/ BBL down
   # Code 137 - an odd error code, when all process shutdown properly but psadmin
   #            does not display the final message "All domain processes have stopped."
   #            will treat error code as success
   if [[ $shutdownExit -eq 0 || $shutdownExit -eq 40 || $shutdownExit -eq 137 || -z "$domainStatus" || $shutdownExit -eq 255 ]]; then
     if [ -z "$domainStatus" ]; then
       util::log "WARNING" "${domainName}: Domain BBL already stopped, running post cleanup of domain"
     fi

     sleep 2
     # make sure there are no residual processes still running
     __checkTUXProcesses "$domainName"
     checkResult=$?
     util::log "DEBUG" "${domainName}: Check TUX process results: $checkResult"

     ipcResult=$(timeout --signal=SIGKILL 120s bash -c "source $envFile && psadmin $typeFlag cleanipc -d $domainName 2>&1")
     ipcCode=$?
     util::log "DEBUG" "${domainName}: Running psadmin $typeFlag cleanipc -d $domainName, ExitCode: $ipcCode, Results: $ipcResult"
     sleep 1
     # if IPC did do clear up fix them
     __fixIPC "$domainName" "$envFile" "$ipcResult"

     # clean up any lingering/stuck shutdown commands
     __cleanStuckTUXCommands "$domainName"

     # stop RMI server
     __stopRMIServer "$domainName"
     # IF any unhappy paths occurred, do a re-configure to clean up bad state.
     # checkResult will return 2, if it had to kill tux processes, need to run config to cleanup state
     # 3/1/18 - added result of failed with exit code 0, BBL is not actually stopping, need re-configure.
     if [[ $shutdownExit -eq 255 || $ipcCode -ne 0 || $checkResult -eq 2 || ( "$shutdownResult" == *failed* && $shutdownExit -eq 0 ) ]]; then
       # is is a message that the config state of peopletools.properties was changed
       # will run config while domain is down
       configResults=$(timeout --signal=SIGKILL 40s bash -c "source $envFile && psadmin $typeFlag configure -d $domainName 2>&1")
       util::log "DEBUG" "${domainName}: Running config for error code 255: $configResults"
       util::log "WARNING" "${domainName}: Discovered config state change or unclean shutdown, auto-reconfiguring domain"
     fi
     sleep 1
     # observed cases where the BBL was still running in limbo, one last cleanup
     __checkTUXProcesses "$domainName"
     if [[ $? -eq 2 ]]; then
       util::log "WARNING" "${domainName}: Tuxedo processes still running, cleaning up any processes and re-configuring domain."
       configResults=$(timeout --signal=SIGKILL 40s bash -c "source $envFile && psadmin $typeFlag configure -d $domainName 2>&1")
       util::log "DEBUG" "${domainName}: Issues after stopping, re-configure psadmin $typeFlag configure -d $domainName, ExitCode: $?, Results: $configResults"
     fi

     util::log "INFO" "${domainName}: $typeString domain stopped successfully."

     # clear cache if requested
     if [[ "$domainType" == "APP" ]]; then
       if [[ $clearCache -eq 1 ]]; then
         __clearAppCache "$domainName"
       fi
     else
       __clearSchedCache "$domainName"
     fi
     return 0
   else
     util::log "ERROR" "${domainName}: Failed psadmin shutdown, ExitCode: $shutdownExit, Results: $shutdownResult"
     return 1
   fi
}

####
####

function domain::startAppDomain() #domainName, majorToolsVer, clearCache, serialBoot, forceBoot, enc_pass,debugFlag,maintLogFile, threadseq
{
   util::log "DEBUG" "${domainName}: Initiating StartAppDomain Function, thread $9"

   __startTuxDomain "APP" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8"
   # Restart lsyncd after domain start to ensure it's running
   sudo systemctl restart lsyncd.service

}

function domain::stopAppDomain() # domainName, majorToolsVer, clearCache, forceStop, enc_pass, debugFlag, maintLogFile
{

   util::log "DEBUG" "${domainName}: Initiating StopAppDomain Function, thread $8"

   __stopTuxDomain "APP" "$1" "$2" "$3" "$4" "$5" "$6" "$7"

}

function domain::startSchedDomain() # domainName, majorToolsVer, forceBoot, enc_vault_pass, debugFlag, maintLogFile, threadseq
{
   util::log "DEBUG" "${domainName}: Initiating startSchedDomain Function, thread $7"

   # Always clear cache and scheduler does not have boot option
   __startTuxDomain "SCHED" "$1" "$2" 1 1 "$3" "$4" "$5" "$6"
   # Restart lsyncd after domain start to ensure it's running
}

function domain::stopSchedDomain() # domainName, majorToolsVer, enc_pass, debugFlag, maintLogFile
{

   util::log "DEBUG" "${domainName}: Initiating stopSchedDomain Function, thread $6"
   # always clear cache, and wait for process to stop
   __stopTuxDomain "SCHED" "$1" "$2" 1 0 "$3" "$4" "$5"

}

export -f domain::startWebDomain
export -f domain::startAppDomain
export -f domain::startSchedDomain
export -f domain::stopWebDomain
export -f domain::stopAppDomain
export -f domain::stopSchedDomain
