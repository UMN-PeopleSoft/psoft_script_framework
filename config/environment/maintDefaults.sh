#!/bin/env bash
####
# Script: maintScriptDefaults.sh
# Purpsose: Global defaults for maintenance/admin scripts
#
########

# default blackout duration when stopping a domain, in minutes
export MAINT_DEF_BLACKOUT_DUR=10

# common/default log file for all maint commands
export MAINT_LOG_FILE="$PS_SCRIPT_BASE/logs/maint/maint.log"

# Location of current inventory of domains/instances psoft
export DOMAIN_LIST="$CONFIG_HOME/inventory/domain.list"

# Lock file to control single access to the domain list
export INVENTORY_LOCK="$CONFIG_HOME/inventory/domain.lock"

# Blackout inventory list
export BLACKOUT_LIST="$CONFIG_HOME/inventory/blackout.list"
export BLACKOUT_HISTORY="$CONFIG_HOME/inventory/blackout.history"

# Exclude list, domains not touched by operational scripts (stop/start)
export EXCLUDE_LIST="$CONFIG_HOME/inventory/domain.exclude"

# List of pssa email notification list
export EMAIL_NOTIFICATION="email@company.com"

# List of pssa pager notification list
export PAGER_NOTIFICATION="psoft@.pagerduty.com"

# Oracle credential used for PSSA MONITORING scripts
export DB_MONITOR_USER="psoftmon"

# standard SSH options
SSH_CMD="ssh -o StrictHostKeyChecking=no"

# F5 global setup for F5 admin and pool member maint ops
export F5_PARTITION="ENTS"
export F5_SERVER="ps.f5.company.com"
export F5_VALIDATE_CERTS=no
export F5_SERVER_PORT=443

# associative array field names for domainInfo, use these instead of 1, 2, 3, etc
#   for example:   ${domainInfo[$DOM_ATTR_HOST]} will return the host name
DOM_ATTR_NAME="domainName"    # (domain ID appended with serverName for schedulers)
DOM_ATTR_TYPE="type"          # (web, app, prc, els)
DOM_ATTR_APP="app"            # (2 char code for apps)
DOM_ATTR_ENV="env"            # (3 char code for envs)
DOM_ATTR_REPORT="reporting"   # (Y/N for Reporting env)
DOM_ATTR_PURPOSE="purpose"
DOM_ATTR_SRVNAME="serverName"   # (for schedulers, ie: PSUNX)
DOM_ATTR_HOST="host"
DOM_ATTR_TOOLSVER="toolsVersion"
DOM_ATTR_WEBVER="weblogicVersion"

### Standard Domain attribute values
ATTR_ENV_LIST=",dev,tst,qat,prd,per,fix,upg,trn,cls,dmo,dmn,umn,tec,rpt,qrpt"
ATTR_APP_LIST=",fs,cs,hr,ih,"
ATTR_TYPE_LIST=",app,web,prc,"
ATTR_PURPOSE_LIST=",main,ib,ren,trace,"
ATTR_REPORTING_LIST="Y/N"
# lookup currently installed tools/weblogic versions
ATTR_TOOLS_VERSION_LIST=$( find /psoft/tools/8.* -maxdepth 0 -printf ','%f -type d 2>&1)
ATTR_TOOLS_VERSION_LIST="${ATTR_TOOLS_VERSION_LIST},"
ATTR_WEBLOGIC_VERISON_LIST=$( find /psoft/weblogic/1* -maxdepth 0 -printf ','%f -type d 2>&1)
ATTR_WEBLOGIC_VERISON_LIST="${ATTR_WEBLOGIC_VERISON_LIST},"

# Current Monitored Env list
#MON_ENV_LIST=("qat" "dev" "fix" "prd" "trn" "cls" "rpt" "qrpt")
#MON_ENV_LIST=("upg" "per" "tst" "qat" "prd")
MON_ENV_LIST=("prd" "tst" "qat" "dev" "fix" "trn" "cls" "rpt")
MON_APP_LIST=("cs" "fs" "hr" "ih")
CRITICALENVS="prd|rpt|trn|cls|fix"
