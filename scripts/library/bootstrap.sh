#!/usr/bin/env bash
#
# Script: bootstrap.sh
# Descr: Support a "base" path where script git repository is located
#     :   allows a portable location of scripts/config/ansible based
#     :   on where the script that sources this file.
#     : Supports a known "scripts" or "scripts_prod" path
#     : If under "scripts_prod", config and ansible is assumed under
#         to be "*_prod" folder to support a consistent "Production" git branchs.
#     : Also allows to support any base patch in a user's work path
#
# Will determine any sub path to the scripts, examples:
#
# To source this bootstrap file use this method:
#   # load bootstrap dynamic path assuming 'script' is in the path
#   currentPath="$( cd "$(dirname "$0")" && pwd )"
#   source ${currentPath%${currentPath#*scripts*/}}library/bootstrap.sh
#
############################

# PSSA/user base folder for scripts
# dynamically discover path to support any path to "scripts*"
# All scripts using libraries must use PS_SCRIPT_BASE
# Will prevent resetting PS_SCRIPT_BASE if already set,
#    as this will not work if called in a parallel command
if [[ -z "$PS_SCRIPT_BASE" ]]; then
  currentPath="$( cd "$(dirname "$0")" && pwd )"
  PS_SOURCE_BASE="${currentPath%scripts*}"
  PS_SCRIPT_BASE="${currentPath%${currentPath#*scripts*/}}"
  # export so spawned subprocesses can use it
  export PS_SOURCE_BASE
  export PS_SCRIPT_BASE
fi

## Setup the main supporting paths from script base
export LIB_HOME="${PS_SCRIPT_BASE}library"
export MAINT_HOME="${PS_SCRIPT_BASE}maint"
export SCRIPT_HOME="${PS_SCRIPT_BASE}"
## Special case, if in prod git branch/path, use prod ansible/config
if [[ "$SCRIPT_HOME" == *prod* ]]; then
  export ANSIBLE_HOME="${PS_SOURCE_BASE}ansible_prod"
  export CONFIG_HOME="${PS_SOURCE_BASE}config_prod"
else
  # for non prod path and any user development git path
  export ANSIBLE_HOME="${PS_SOURCE_BASE}ansible"
  export CONFIG_HOME="${PS_SOURCE_BASE}config"
fi

# Carry these to path
PATH="$MAINT_HOME:$PS_SCRIPT_BASE:$PATH"; export PATH

##### Core OS Env setup to support peoplesoft, F5, oem, and exalogic
source $CONFIG_HOME/environment/osEnvDefaults.sh

##### Load defaults from config repository
# maint defaults
source $CONFIG_HOME/environment/maintDefaults.sh

## used to prevent re-running this bootstrap script in same session
export BOOTSTRAP_LOADED=yes
