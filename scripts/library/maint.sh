# Library: maint
# Script: maint.sh
# Purpose: support functions to operate a domain (stop/start/cycle)
#   The methods are designed to be called from a parallel command
# CB: Nate Werner
# Created: 11/15/2017
#
# Functions (public for threading):
#   startDomain(domainName-serverName, majorToolsVer, skipF5, clearCache, serialBoot, forceBoot)
#      Wrapper function to support common start domain actions, supports parallel call
#   stopDomain(domainName-serverName, majorToolsVer, clearCache, stopCoherence, forceStop)
#      Wrapper function to support common stop domain actions, supports parallel call
#   cycleDomain(domainName-serverName, majorToolsVer, skipF5, clearCache, serialBoot, stopCoherence, forceStop)
#      Wrapper function to support common cycle domain actions, supports parallel call
#
####################

###############
# These functions are called externally and need to reload libraries
function maint::startDomain() # domainName+SN, majorToolsVer, skipF5, clearCache, serialBoot, forceBoot, debugFlag,maintLogFile
{
  # exported PS_SCRIPT_BASE from main script
  source $PS_SCRIPT_BASE/library/bootstrap.sh

  # load needed libraries
  source $LIB_HOME/inventory.sh
  source $LIB_HOME/f5.sh
  source $LIB_HOME/domain.sh
  source $LIB_HOME/utilities.sh

  # need to pass all parms to external process
  local domainName="$1"
  local majorToolsVer="$2"
  local skipF5=$3
  local clearCache=$4
  local serialBoot=$5
  local forceBoot=$6
  debugFlag=$7
  maintLogFile="$8"
  declare -Ag domAttribs
  local domainParameters=""
  local resultCode=0

  util::setLogFile "$maintLogFile"

  if [[ -n "${PARALLEL_SEQ}" ]]; then
    util::log "DEBUG" "Parallel: startDomain for thread ${PARALLEL_SEQ}"
  fi
  # if tools version was not provided, get most current
  if [[ -z "$majorToolsVer" ]]; then
    majorToolsVer=$( inventory::getCurrentTools "$domainName")
  fi

  # retrieve domain details into var domAttribs
  util::log "DEBUG" "Running inventory::getDomainInfo $domainName 0 $majorToolsVer"
  inventory::getDomainInfo "$domainName" "" "$majorToolsVer" domAttribs
  if [[ "$?" -ne 0 ]]; then
    util::log "ERROR" "Domain $domainName does not exist"
    exit 1
  else
    # Check if this domain is in the exluded list
    if inventory::isInExcludeList "$domainName" "$serverName"; then
      util::log "INFO" "${domainName}: Skipping domain startup (Exclude List)"
      exit 0
    fi

    if [[ "${domAttribs[$DOM_ATTR_TYPE]}" == "web" ]]; then
      #check that F5 pool member is disabled before starting
      if [[ $skipF5 -ne 1 ]]; then
        f5::disablePoolMember "$domainName"
      fi

      util::log "DEBUG" "maint::startDomain -> domain::startWebDomain $domainName ${domAttribs[$DOM_ATTR_HOST]} $majorToolsVer $ANSIBLE_VAULT $debugFlag $maintLogFile ${PARALLEL_SEQ}"
      $SSH_CMD ${domAttribs[$DOM_ATTR_HOST]} "bash -c 'cd $LIB_HOME; source domain.sh; domain::startWebDomain \"$domainName\" \"$majorToolsVer\" \"$ANSIBLE_VAULT\" \"$debugFlag\" \"$maintLogFile\" \"${PARALLEL_SEQ}\"'"
      resultCode=$?
      if [[ $resultCode -ne 0 ]]; then
        util::log "ERROR" "${domainName}: maint::startDomain: Failed to start domain, Error Code: $resultCode"
        exit 1
      fi
      if [[ $skipF5 -ne 1 ]]; then
        f5::enablePoolMember "$domainName"
      fi
    elif [[ "${domAttribs[$DOM_ATTR_TYPE]}" == "app" ]]; then

      util::log "DEBUG" "maint::startDomain -> domain::startAppDomain $domainName ${domAttribs[$DOM_ATTR_HOST]} $majorToolsVer $clearCache $serialBoot"

      # REN servers are routed from F5
      if [[ $skipF5 -ne 1 && "${domAttribs[$DOM_ATTR_PURPOSE]}" == "ren" ]]; then
        #check that F5 pool member is disabled before starting
        f5::disablePoolMember "$domainName"
      fi

      $SSH_CMD ${domAttribs[$DOM_ATTR_HOST]} "bash -c 'cd $LIB_HOME; source domain.sh; domain::startAppDomain \"$domainName\" \"$majorToolsVer\" \"$clearCache\" \"$serialBoot\" \"$forceBoot\" \"$ANSIBLE_VAULT\" \"$debugFlag\" \"$maintLogFile\" \"${PARALLEL_SEQ}\"'"
      resultCode=$?
      if [[ $resultCode -ne 0 ]]; then
        util::log "ERROR" "${domainName}: maint::startDomain: Failed to start domain, Error Code: $resultCode"
        exit 1
      fi
      if [[ $skipF5 -ne 1 && "${domAttribs[$DOM_ATTR_PURPOSE]}" == "ren" ]]; then
        #check that F5 pool member is disabled before starting
        f5::enablePoolMember "$domainName"
      fi

    else # scheduler
      util::log "DEBUG" "Calling domain::startSchedDomain $domainName ${domAttribs[$DOM_ATTR_HOST]} $majorToolsVer"
      $SSH_CMD ${domAttribs[$DOM_ATTR_HOST]} "bash -c 'cd $LIB_HOME; source domain.sh; domain::startSchedDomain \"$domainName\" \"$majorToolsVer\" \"$forceBoot\" \"$ANSIBLE_VAULT\" \"$debugFlag\" \"$maintLogFile\" \"${PARALLEL_SEQ}\"'"
      resultCode=$?
      if [[ $resultCode -ne 0 ]]; then
        util::log "ERROR" "${domainName}: maint::startDomain: Failed to start domain, Error Code: $resultCode"
        exit 1
      fi
    fi
  fi
}

#Main function called in sub-process via parallel for each domain
#Since the function is called in separate process, so libaries need
#  to be re-sourced.
function maint::stopDomain() #domainName+SN, majorToolsVer, clearCache, stopCoherence, forceStop,debugFlag,maintLogFile
{
  # exported PS_SCRIPT_BASE from main script
  source $PS_SCRIPT_BASE/library/bootstrap.sh

  # load needed libraries
  source $LIB_HOME/inventory.sh
  source $LIB_HOME/f5.sh
  source $LIB_HOME/domain.sh
  source $LIB_HOME/utilities.sh

  # need to pass all parms to external process
  local domainName="$1"
  local majorToolsVer="$2"
  local clearCache=$3
  local stopCoherence=$4
  local forceStop=$5
  debugFlag=$6
  maintLogFile="$7"
  declare -Ag domAttribs
  local domainParameters=""
  local domainList=()
  local resultCode=0

  util::setLogFile "$maintLogFile"
  if [[ -n "${PARALLEL_SEQ}" ]]; then
    util::log "DEBUG" "Parallel: stopDomain for thread ${PARALLEL_SEQ}"
  fi

  # if tools version was not provided, get most current
  if [[ -z "$majorToolsVer" ]]; then
    majorToolsVer=$( inventory::getCurrentTools "$domainName")
  fi

  # retrieve domain details into var domAttribs
  util::log "DEBUG" "Running inventory::getDomainInfo $domainName 0 $majorToolsVer"
  inventory::getDomainInfo "$domainName" "" "$majorToolsVer" domAttribs
  if [[ "$?" -ne 0 ]]; then
    util::log "ERROR" "Domain $domainName does not exist"
    exit 1
  else
    if [[ "${domAttribs[$DOM_ATTR_TYPE]}" == "web" ]]; then
      # disable F5 pool member before stopping domain
      f5::disablePoolMember "$domainName"

      util::log "DEBUG" "maint::stopDomain -> domain::stopWebDomain $domainName ${domAttribs[$DOM_ATTR_HOST]} $majorToolsVer $stopCoherence $ANSIBLE_VAULT $debugFlag $maintLogFile ${PARALLEL_SEQ}"
      $SSH_CMD ${domAttribs[$DOM_ATTR_HOST]} "bash -c 'cd $LIB_HOME; source domain.sh; domain::stopWebDomain \"$domainName\" \"$majorToolsVer\" \"$stopCoherence\" \"$ANSIBLE_VAULT\" \"$debugFlag\" \"$maintLogFile\" \"${PARALLEL_SEQ}\"'"
      resultCode=$?
      if [[ $resultCode -ne 0 ]]; then
        util::log "ERROR" "${domainName}: Failed to stop domain, Error Code: $resultCode"
        exit 1
      fi

    elif [[ "${domAttribs[$DOM_ATTR_TYPE]}" == "app" ]]; then
      util::log "DEBUG" "Calling domain::stopAppDomain $domainName ${domAttribs[$DOM_ATTR_HOST]} $majorToolsVer $clearCache $forceStop $ANSIBLE_VAULT $debugFlag $maintLogFile ${PARALLEL_SEQ}"

      if [[ "${domAttribs[$DOM_ATTR_PURPOSE]}" == "ren" ]]; then
        #check that F5 pool member is disabled before starting
        f5::disablePoolMember "$domainName"
      fi

      $SSH_CMD ${domAttribs[$DOM_ATTR_HOST]} "bash -c 'cd $LIB_HOME; source domain.sh; domain::stopAppDomain \"$domainName\" \"$majorToolsVer\" \"$clearCache\" \"$forceStop\" \"$ANSIBLE_VAULT\" \"$debugFlag\" \"$maintLogFile\" \"${PARALLEL_SEQ}\"'"
      resultCode=$?
      if [[ $resultCode -ne 0 ]]; then
        util::log "ERROR" "${domainName}: Failed to stop domain, Error Code: $resultCode"
        exit 1
      fi
    else # scheduler
      util::log "DEBUG" "Calling domain::stopSchedDomain $domainName ${domAttribs[$DOM_ATTR_HOST]} $majorToolsVer $ANSIBLE_VAULT $debugFlag $maintLogFile ${PARALLEL_SEQ}"
      $SSH_CMD ${domAttribs[$DOM_ATTR_HOST]} "bash -c 'cd $LIB_HOME; source domain.sh; domain::stopSchedDomain \"$domainName\" \"$majorToolsVer\" \"$ANSIBLE_VAULT\" \"$debugFlag\" \"$maintLogFile\" \"${PARALLEL_SEQ}\"'"
      resultCode=$?
      if [[ $resultCode -ne 0 ]]; then
        util::log "ERROR" "${domainName}: Failed to stop domain, Error Code: $resultCode"
        exit 1
      fi
    fi
  fi
}

#Main function called in sub-process via parallel for each domain
#Since the function is called in separate process, so libaries need
#  to be re-sourced.
function maint::cycleDomain() # domainName+SN, majorToolsVer, skipF5, clearCache, serialBoot, stopCoherence, forceStop, forceStart, debugFlag, maintLogFile
{
  # need to pass all parms to external process
  local domainName="$1"
  local majorToolsVer="$2"
  local skipF5="$3"
  local clearCache="$4"
  local serialBoot="$5"
  local stopCoherence="$6"
  local forceStop="$7"
  local forceStart="$8"
  local debugFlag="$9"
  local maintLogFile="${10}"
  maint::stopDomain "$domainName" "$majorToolsVer" "$clearCache" "$stopCoherence" "$forceStop" "$debugFlag" "$maintLogFile"
  if [[ $? -ne 0 ]]; then
    exit 1
  fi
  # will clear cache on the stop, so we can skip here
  maint::startDomain "$domainName" "$majorToolsVer" "$skipF5" "0" "$serialBoot" "$forceStart" "$debugFlag" "$maintLogFile"
  if [[ $? -ne 0 ]]; then
    exit 1
  fi
}

#export functions so they can be called from parallel command
export -f maint::stopDomain
export -f maint::startDomain
export -f maint::cycleDomain
