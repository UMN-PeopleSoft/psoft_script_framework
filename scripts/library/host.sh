# Library: host
# Script: host.sh
# Purpose: support functions to gather and display host information
#
# CB: Nate Werner
# Created: 9/13/2019
#
# Functions :
#   host::getServerStats()
#     Load data on server info and applications that are running
#   host::displayServerStats()
#     Render server info in a dashboard
#
####################
# TODO:  Clean up and split out Linux specific items to sparate functions.

# capture current server stats
function host::getServerStats()
{
#   ARR_APP_DOM_STATUS=()
#   ARR_PRCS_DOM_STATUS=()
#   ARR_WEB_DOM_STATUS=()
#   ARR_COH_CACHE_STATUS=()
   # normal=`tput sgr0`
   OS_RELEASE=$(cat /etc/oracle-release /etc/redhat-release 2>/dev/null | head -1)
   # only get server stats if library used on Linux server
   # Linux server use this function for the login status screen too.
     USED_MEM=`free -m | grep buffers/cache | awk '{print $3 MB}'`
     if [ -z "$USED_MEM" ]; then
        #RH7
       USED_MEM=`free -m | grep Mem: | awk '{ print $3 }'`
       CPU_LOAD=`top -bn 2 -d 0.01 | grep '^%Cpu.s.' | tail -n 1 | gawk '{print $2+$4+$6}'`
     else
       #OEL6
       CPU_LOAD=`top -bn 2 -d 0.01 | grep '^Cpu.s.' | tail -n 1 | gawk '{print $2+$4+$6}'`
     fi

     TOTAL_MEM=`free -m | grep Mem | awk '{print $2 MB}'`
     #echo "$USED_MEM"
     #echo "$TOTAL_MEM"
     USED_MEMG=`echo "scale=1; ($USED_MEM / 1024 )" | bc`
     # Include the tmpfs app/prcs server cache folder in memory used
     if [[ "$host_name" == *"app"* || "$host_name" == *"prc"* ]]; then
       CACHE_SIZE=$( df -BM | grep pscache | awk '{ print $3 }' | tr -d 'M' )
       TOTAL_CACHE_SIZE=$( df -BM | grep pscache | awk '{ print $2 }' | tr -d 'M' )
       CACHE_FREE=$(echo "scale=1; (($TOTAL_CACHE_SIZE - $CACHE_SIZE)/ 1024 )" | bc )
       USED_MEMG=$( echo "scale=1; ($CACHE_SIZE / 1024 ) + $USED_MEMG" | bc )
     fi
     TOTAL_MEMG=`echo "scale=1; ($TOTAL_MEM / 1024 )" | bc`
     PERCENT_USED=`echo "scale=3; (($USED_MEM / $TOTAL_MEM)  * 100 )" | bc`
     PERCENT_USED=`printf "%.1f" $PERCENT_USED`
     # echo "Memory Used:       $PERCENT_USED %"
     UP_TIME=`uptime | awk '{ print $3 $4 }'`
     UP_TIME=${UP_TIME%,}
     CPU_AVG=`cat /proc/loadavg | awk '{ print $1 }'`

     CPU_AVG=${CPU_AVG:0:4}
     CPU_COUNT=`cat /proc/cpuinfo | grep processor | wc -l`
     CPU_AVG=`echo "scale=1; ($CPU_AVG / $CPU_COUNT * 100)" | bc`
     CPU_LOAD="${CPU_LOAD}% ${normal}(${CPU_AVG}%)"

     EXT_IP_ADDR=`ip addr | grep '12.34.56' | cut -d/ -f1 | awk '{ print $2}'`
     INT_IP_ADDR=`ip addr | grep '78.90.12' | cut -d/ -f1 | awk '{ print $2}' | head -1`
     if [ -z "$INT_IP_ADDR" ]; then
       INT_IP_ADDR=`ip addr | grep '12.34.56' | cut -d/ -f1 | awk '{ print $2}'`
     fi

     PSOFT_DIR_USED=`df -Pl | grep -e " /psoft$" | awk '{ print $5 }'`
     if [[ "$host_name" == *app* || "$host_name" == *prc* ]]; then
       CACHE_DIR_USED=$( df -Pl | grep -e " /psoft/cache$" | awk '{ print $5 }' )
     fi

     ARR_APP_DOM=(`find -L /psoft/domains/8.5*/*/appserv -maxdepth 2 -name "PSTUXCFG" 2> /dev/null | sort -u | awk -F'/' '{ print $7"("$4")" }'`)
     ARR_PRCS_DOM=(`find -L /psoft/domains/8.5*/*/prcserv -maxdepth 2 -name "PSTUXCFG" 2> /dev/null | sort -u | awk -F'/' '{ print $7"("$4")" }'`)

     PS_HOST_NAME=`hostname`
     ARR_WEB_DOM=(`find -P /psoft/domains/8.5*/webserv/* -maxdepth 0 -type d 2>/dev/null | egrep "fs|cs|hr|he|pm|ih|hub" | awk -F'/' '{ print $6"("$4")" }'`)
     ARR_COH_CACHE=(`find -P /psoft/domains/8.5*/webserv/* -maxdepth 0 -type d 2>/dev/null | egrep "fs|cs|hr|he|pm|ih|hub" | awk -F'/' '{ print $6"("$4")" }'`)

   SERVER_NAME=`hostname`
   for ix in ${!ARR_APP_DOM[*]}
   do
     if [ -n ${ARR_APP_DOM[$ix]} ]; then
       APP_VER=$(echo "${ARR_APP_DOM[$ix]}" | cut -d'(' -f 2 | cut -d')' -f 1 )
       DOMAIN_NAME=$( echo "${ARR_APP_DOM[$ix]}" | cut -d'(' -f 1 )
       PS_RESULT=`ps -eo start_time,cmd | grep BBL | grep "/${DOMAIN_NAME}" | cut -d'(' -f 1 | grep "${APP_VER%%)}" | grep -v "grep" | grep -v "OEM" | awk '{ print $1 }'`
       if [ -z "${PS_RESULT}" ]; then
         ARR_APP_DOM_STATUS[$ix]="Inactive"
       else
         ARR_APP_DOM_STATUS[$ix]="Active ${normal}($PS_RESULT)"
       fi
     fi
   done

   for ix in ${!ARR_PRCS_DOM[*]}
   do
     if [ -n ${ARR_PRCS_DOM[$ix]} ]; then
       PRC_VER=$(echo "${ARR_PRCS_DOM[$ix]}" | cut -d'(' -f 2 | cut -d')' -f 1 )
       DOMAIN_NAME=$( echo "${ARR_PRCS_DOM[$ix]}" | cut -d'(' -f 1 )
       PS_RESULT=`ps -ef | grep BBL | grep "/${DOMAIN_NAME}" | cut -d'(' -f 1 | grep "${PRC_VER%%)}" | grep -v "grep" | awk '{ print $5 }'`
       if [ -z "${PS_RESULT}" ]
         then
         ARR_PRCS_DOM_STATUS[$ix]="Inactive"
       else
         ARR_PRCS_DOM_STATUS[$ix]="Active ${normal}($PS_RESULT)"
       fi
     fi
   done

   for ix in ${!ARR_WEB_DOM[*]}
   do
     if [ -n ${ARR_WEB_DOM[$ix]} ]; then
       WEB_VER="$( echo "${ARR_WEB_DOM[$ix]}" | cut -d'(' -f 2 | cut -d')' -f 1 )"
       DOMAIN_NAME=$( echo "${ARR_WEB_DOM[$ix]}" | cut -d'(' -f 1 )
       PS_RESULT=`ps -ef | grep "java" | grep "/${DOMAIN_NAME}" | grep "${WEB_VER%%)}" | grep -v "grep" | grep -v "DefaultCacheServer" | grep -v "EMIntegrationServer" | awk '{ print $5 }'`
       if [ -z "${PS_RESULT}" ]
         then
         ARR_WEB_DOM_STATUS[$ix]="Inactive"
       else
         ARR_WEB_DOM_STATUS[$ix]="Active ${normal}($PS_RESULT)"
       fi
     fi
   done
   for ix in ${!ARR_COH_CACHE[*]}
   do
     if [ -n ${ARR_COH_CACHE[$ix]} ]; then
       TOOLS_VER="$( echo "${ARR_COH_CACHE[$ix]}" | cut -d'(' -f 2 | cut -d')' -f 1 )"
       DOMAIN_NAME=$( echo "${ARR_COH_CACHE[$ix]}" | cut -d'(' -f 1 )
       if ls /psoft/domains/${TOOLS_VER%%)}/webserv/${DOMAIN_NAME}/config/*cache.xml &> /dev/null; then
         COH_VER="$(echo "${ARR_COH_CACHE[$ix]}" | cut -d'(' -f 2 | cut -d')' -f 1)"
         PS_RESULT=`ps -ef | grep "java" | grep "/${DOMAIN_NAME}" | grep "${COH_VER%%)}" | grep -v "grep" | grep "DefaultCacheServer" | awk '{ print $5 }'`
         if [ -z "${PS_RESULT}" ]
           then
           ARR_COH_CACHE_STATUS[$ix]="Inactive"
         else
           ARR_COH_CACHE_STATUS[$ix]="Active ${normal}($PS_RESULT)"
         fi
       else
         unset  ${!ARR_COH_CACHE[$ix]}
       fi
     fi
   done

   PSHOST=`hostname -s`
   # Monitor servers
   if [[ "${PSHOST}" == *"mgmt"* ]]; then
     IB_RESULT=`ps -ef | grep "java" | grep -v "grep" | grep "IBMonitorService" | awk '{ print $5 }'`
     AV_RESULT=`ps -ef | grep -v grep | grep -m 1 "SYMCScan" | awk '{ print $5 }'`
     RD_RESULT=`ps -ef | grep -v grep | grep -m 1 "rundeck" | awk '{ print $5 }'`
     INT_HTTP_RESULT=`ps -ef | grep -v grep | grep -m 1 "UMNHTTPServer" | awk '{ print $5 }'`
   fi

   ARR_ELS_DOM=(`find -P /psoft/domains/8.5*/webserv/* -maxdepth 0 -type d 2>/dev/null | egrep "fs|cs|hr|he|pm|ih|hub" | awk -F'/' '{
 print $6"("$4")" }'`)

}

# diplay login UI using TPUT tool
function host::displayLoginInfo()
{
   tput clear
   tput cup 1 14
   tput setaf 1
   tput bold

   host_name=$( hostname -s )
   if [[ "$host_name" = *apppum* ]]; then
     case "$host_name" in
       *1)
        PUM_ENV="IH"
        ;;
       *2)
        PUM_ENV="CS"
        ;;
       *3)
        PUM_ENV="FS"
        ;;
       *4)
        PUM_ENV="HR"
        ;;
     esac
     echo "PSSA Server Login (PUM: $PUM_ENV)"
     PUM_ENV=$(echo "$PUM_ENV" | awk '{print tolower($0)}')
     IMAGE_VERSION=$(ls /psoft/pum/${PUM_ENV}/*image* | grep -o "image[[:digit:]]*")
     PUM_ENV="$PUM_ENV $IMAGE_VERSION"
   else
     echo "PSSA Server Login"
   fi

   tput sgr0
   tput cup 2 3
   echo "$SERVER_NAME - $INT_IP_ADDR (uptime: $UP_TIME)"
   echo "  $OS_RELEASE"
   tput cup 4 6
   tput setaf 2
   tput bold
   echo "            Server Status"
   tput sgr0
   tput cup 6 3
   echo "Memory Used:  "
   tput bold
   tput cup 6 19
   echo "$USED_MEMG of ${TOTAL_MEMG}GB"
   tput sgr0
   tput cup 6 36
   echo "CPU %: "
   tput bold
   tput cup 6 44
   echo "$CPU_LOAD"

   tput sgr0
   tput cup 7 3
   echo "Memory %:  "
   tput bold
   tput cup 7 19
   echo "${PERCENT_USED}%"
   tput sgr0
   tput cup 7 36
   echo "/psoft used: "
   tput bold
   tput cup 7 49
   echo "$PSOFT_DIR_USED"

   if [[ "$host_name" == *"app"* || "$host_name" == *"prc"* ]]; then
     tput sgr0
     tput cup 8 3
     echo "App Cache used: "
     tput bold
     tput cup 8 19
     echo "$CACHE_DIR_USED"
     tput sgr0
     tput cup 9 3
     echo "App Cache free: "
     tput bold
     tput cup 9 19
     echo "${CACHE_FREE} GB"
   fi

   if [ -n "$PUM_ENV" ]; then
     tput sgr0
     tput cup 8 3
     echo "PUM App:  "
     tput bold
     tput cup 8 13
     echo "$PUM_ENV"
   fi

   tput sgr0
   tput cup 11 6
   tput setaf 2
   tput bold

   DOM_COUNT=0
   if [[ "$host_name" == *"els"* ]]; then
     echo ""
     tput setaf 6
     tput cuf 3
     echo "Elasticsearch          (since)"
     tput sgr0

     for ix in ${!ARR_ELS_DOM[*]}
     do
        tput cuf 3
        let DOM_COUNT=DOM_COUNT+1
        echo "$DOM_COUNT) ${ARR_ELS_DOM[$ix]}:"
        tput cuu1
        tput cuf 21
        tput bold
        echo "${ARR_ELS_DOM_STATUS[$ix]}"
        tput sgr0
     done

     tput sgr0

   elif [[ "$host_name" == *"mgmt"* ]]; then
     echo ""
     tput setaf 6
     tput cuf 3
     echo "3rd Party Apps          (since)"
     tput sgr0
     tput cuf 3
     echo "IB Monitor Service"
     tput cuu1
     tput cuf 27
     tput bold
     if [[ -n "$IB_RESULT" ]]; then
        echo "$IB_RESULT"
     else
        echo "Inactive"
     fi
     tput sgr0

     tput cuf 3
     echo "Symantec Antivirus"
     tput cuu1
     tput cuf 27
     tput bold
     if [[ -n "$AV_RESULT" ]]; then
        echo "$AV_RESULT"
     else
        echo "Inactive"
     fi
     tput sgr0

     tput cuf 3
     echo "RunDeck"
     tput cuu1
     tput cuf 27
     tput bold

     if [[ -n "$RD_RESULT" ]]; then
        echo "$RD_RESULT"
     else
        echo "Inactive"
     fi
     tput sgr0

     tput cuf 3
     echo "PSSA Web Srvr (Python)"
     tput cuu1
     tput cuf 27
     tput bold
     if [[ -n "$INT_HTTP_RESULT" ]]; then
        echo "$INT_HTTP_RESULT"
     else
        echo "Inactive"
     fi
     tput sgr0

   else  # PSOFT

     echo "           Domain Status"
     tput sgr0
     tput cup 13 3
     tput setaf 6
     echo "App Servers               (since)       Process Sched"
     tput sgr0

     ARR_DOM_LIST=()
     MAX_APP=${#ARR_APP_DOM[@]}
     MAX_PRCS=${#ARR_PRCS_DOM[@]}
     if [[ $MAX_PRCS -gt $MAX_APP ]]; then
       MAX_APP=$MAX_PRCS
     fi

     DOM_COUNT=0

     for (( ix=0; ix <= $MAX_APP; ix++))
     do
        tput cuf 3
        if [[ -n ${ARR_APP_DOM[$ix]} ]]; then
          let DOM_COUNT=DOM_COUNT+1
          echo "$DOM_COUNT) ${ARR_APP_DOM[$ix]}:"
          if [[ "${ARR_APP_DOM[$ix]}" = *8.54* ]]; then
            ARR_DOM_LIST[$DOM_COUNT]="${ARR_APP_DOM[$ix]%%(*}854"
          else
            ARR_DOM_LIST[$DOM_COUNT]="${ARR_APP_DOM[$ix]%%(*}"
          fi
        else
          echo " "
        fi
        tput cuu1
        tput cuf 22
        tput bold
        echo "${ARR_APP_DOM_STATUS[$ix]}"
        tput sgr0
        # schedulers
        if [ "${#ARR_PRCS_DOM[$ix]}" -gt "1" ]; then
          tput cuu1
          tput cuf 38
          let DOM_COUNT=DOM_COUNT+1
          echo "$DOM_COUNT) ${ARR_PRCS_DOM[$ix]}:"
          if [[ "${ARR_PRCS_DOM[$ix]}" = *8.54* ]]; then
            ARR_DOM_LIST[$DOM_COUNT]="${ARR_PRCS_DOM[$ix]%%(*}854"
          else
            ARR_DOM_LIST[$DOM_COUNT]="${ARR_PRCS_DOM[$ix]%%(*}"
          fi

          tput cuu1
          tput cuf 54
          tput bold
          echo "${ARR_PRCS_DOM_STATUS[$ix]}"
          tput sgr0
        fi
     done

     tput sgr0
     echo ""
     tput setaf 6
     tput cuf 3
     echo "Web Servers             (since)    Coherence Cache   (since)"
     tput sgr0
     for ix in ${!ARR_WEB_DOM[*]}
     do
        tput cuf 3
        let DOM_COUNT=DOM_COUNT+1
        echo "$DOM_COUNT) ${ARR_WEB_DOM[$ix]}:"

        if [[ "${ARR_WEB_DOM[$ix]}" = *8.54* ]]; then
          ARR_DOM_LIST[$DOM_COUNT]="${ARR_WEB_DOM[$ix]%%(*}854"
        else
          ARR_DOM_LIST[$DOM_COUNT]="${ARR_WEB_DOM[$ix]%%(*}"
        fi

        tput cuu1
        tput cuf 21
        tput bold
        echo "${ARR_WEB_DOM_STATUS[$ix]}"
        tput sgr0
        if [[ -n ${ARR_COH_CACHE_STATUS[$ix]} ]]; then
          # Coherence servers
          tput cuu1
          tput cuf 37
          let DOM_COUNT=DOM_COUNT+1
          echo "$DOM_COUNT) ${ARR_WEB_DOM[$ix]}:"
          if [[ "${ARR_APP_DOM[$ix]}" = *8.54* ]]; then
            ARR_DOM_LIST[$DOM_COUNT]="${ARR_WEB_DOM[$ix]%%(*}854"
          else
            ARR_DOM_LIST[$DOM_COUNT]="${ARR_WEB_DOM[$ix]%%(*}"
          fi

          tput cuu1
          tput cuf 54
          tput bold
          echo "${ARR_COH_CACHE_STATUS[$ix]}"
          tput sgr0
        fi

     done

     tput sgr0

   fi

   echo ""
   export ARR_DOM_LIST

}

# call appropriate env script based on domain id
function host::runDomainEnv() {

  SEL_DOMAIN=${ARR_DOM_LIST[$SEL_OPTION]}
  # parse out app, version, environment
  if [ "${SEL_DOMAIN:0:1}" == "a" ]; then
    # drop the A and number at end
    SEL_DOMAIN=${SEL_DOMAIN:1}
  fi
  if [[ "$SEL_DOMAIN" = *855* ]]; then
    SEL_DOMAIN="${SEL_DOMAIN%%855}"
    DTEST=`echo "$SEL_DOMAIN" | grep '[$[:digit:]]'`
    if [  -z "$DTEST" ]; then
      SEL_DOMAIN="${SEL_DOMAIN}855"
    else
      SEL_DOMAIN="${SEL_DOMAIN%${SEL_DOMAIN:(-1)}}854"
    fi
  else
    DTEST=`echo "$SEL_DOMAIN" | grep '[$[:digit:]]'`
    if [ -z "$DTEST" ]; then
      SEL_DOMAIN="${SEL_DOMAIN}"
    else
      SEL_DOMAIN="${SEL_DOMAIN%${SEL_DOMAIN:(-1)}}"
    fi
  fi

  # call correct home
  HOSTNM=`hostname`
  FINDWEB=`echo $HOSTNM | grep "web"`
  if [ -n "$FINDWEB" ]; then
    if [[ "$SEL_DOMAIN" = *856* ]]; then
      source $PS_BASE/domains/tools856.env
    else
      source $PS_BASE/domains/tools855.env
    fi
  else
    source $PS_BASE/domains/$SEL_DOMAIN.env
  fi

}
