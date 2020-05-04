#!/bin/env bash
#  Master Environment Setup script for 8.56
#  Consolidates PS scripts to one.
#  Created: 1/28/2016
#  Called by specific env script
#
# Update: 6/4/15 - Added support for use of /psoft/alldomains on monitor servers.
# Update: 8/3/18 - Check-in for tools 8.56
# Update: 11/2/19 - Added 8.57
############

# Reset linux base env vars - must be called,
#   allows script to be rerunnable, unlike delivered scripts
#. $PS_BASE/sripts/admin/scripts/linux_env.sh

#  Base folders all homes
PS_TOOLS_BASE="$PS_BASE/tools"
PS_CONFIG_BASE="$PS_BASE/domains"
PS_WEB_BASE="$PS_BASE/weblogic"
PS_APP_BASE="$PS_BASE/apps"
PS_TUX_BASE="$PS_BASE/tuxedo"
PS_COBOL_BASE="$PS_BASE/cobol"
ORACLE_BASE="$PS_BASE/dbclient"
PS_CUST_BASE="$PS_BASE/appscust"

# Special Constants
# PS_TUX_SUBFOLDER="tuxedo11gR1"

# sample dynamic input vars from callee (xxxx.env)
#PS_TOOLS_VER="8.52.08"
#PS_TUX_VER="10.3.0.81"
#PS_WEB_VER="10.3.4.4"
## Do not set these for web server
#PS_APP_VER="HR89DEV"
#PS_CUST_VER="HR92DEV"
#PS_ORA_CLIENT_VER="11.2.0.1"
#PS_ORA_DB="HR89DEV"
#PS_COBOL_VER="5.1wp4"

# Set baseline path var, defined in linux_env.sh
#PATH=$BASE_PATH

######### MAIN HOME VARS - Merge base to versions
# For Web Servers, skip App home
if [[ -n $PS_APP_VER ]]; then
  PS_HOME="$PS_TOOLS_BASE/$PS_TOOLS_VER"; export PS_HOME
  PS_APP_HOME="$PS_APP_BASE/$PS_APP_VER"; export PS_APP_HOME
  # Config home driven by main tools version, drop the patch version
  # App/Scheduler also separate by app, use first 2/3 letters of home
  PS_CFG_HOME=$PS_CONFIG_BASE/${PS_TOOLS_VER:0:4}/${PS_APP_VER:0:2}; export PS_CFG_HOME
  PATH=$PS_CFG_HOME:$PATH; export PATH
else
  # Setup for web servers (no app home)
  PS_HOME="$PS_TOOLS_BASE/$PS_TOOLS_VER"; export PS_HOME
  PS_CFG_HOME=$PS_CONFIG_BASE/${PS_TOOLS_VER:0:4}; export PS_CFG_HOME
fi

# 8.53 Customization home path, but same app ver - prototype
if [[ -n $PS_CUST_VER ]]; then
   PS_CUST_HOME="$PS_CUST_BASE/$PS_CUST_VER"; export PS_CUST_HOME
fi

# Remaining core homes
# PIA will be in config/domains folder
PIA_HOME="$PS_CFG_HOME"; export PIA_HOME
# DB Client core setup - includes client folder like /client_3
ORACLE_HOME="$ORACLE_BASE/product/$PS_ORA_CLIENT_VER"; export ORACLE_HOME

# New Batch Home Env Variable for PS Apps
PS_BATCH_HOME=$PS_BASE/batch/$PS_APP_VER; export PS_BATCH_HOME
# NEw Attachment Home Env Variable for PS Apps
PS_ATTACH_HOME=$PS_BASE/attachments/$PS_APP_VER; export PS_ATTACH_HOME

# Log home for log viewer
PS_LOG_HOME=$PS_BASE/logs/$PS_APP_VER; export PS_LOG_HOME

######### Verify home directories
if [ ! -d "$PS_HOME" ]
  then
  echo "PS_HOME Directory $PS_HOME does not exist, I cannot set this up"
  exit 1
fi
if [ ! -d "$PS_CFG_HOME" ]
  then
  echo "PS_CFG_HOME Directory $PS_CFG_HOME does not exist, I cannot set this up"
  exit 1
fi
if [[ -n $PS_APP_VER && ! -d "$PS_APP_HOME" ]]
  then
  echo "PS_APP_HOME Directory $PS_APP_HOME does not exist, I cannot set this up"
  exit 1
fi
if [[ -n $PS_CUST_VER && ! -d "$PS_CUST_HOME" ]]
  then
  echo "PS_CUST_HOME Directory $PS_CUST_HOME does not exist, I cannot set this up"
  exit 1
fi
if [[ -n $PS_APP_VER && ! -d "$ORACLE_HOME" ]]
  then
  echo "ORACLE_HOME Directory $ORACLE_HOME does not exist, I cannot set this up"
  exit 1
fi
if [ ! -d "$PIA_HOME" ]
  then
  echo "PIA_HOME Directory $PIA_HOME does not exist, I cannot set this up"
  exit 1
fi

######### Capture JAVA home based on version needed for PeopleTools
# With 8.53 using single shared TOOLs, the JRE will be used from the tools folder
PS_JRE="$PS_HOME/jre"; export PS_JRE
JAVA_HOME=$PS_JRE; export JAVA_HOME
CLASSPATH="$PS_CUST_HOME/appserv/classes:$PS_APP_HOME/appserv/classes:$PS_HOME/appserv/classes"; export CLASSPATH
PSJLIBPATH="$PS_JRE/lib/amd64/native_threads:$PS_JRE/lib/amd64/server:$PS_JRE/lib/amd64"; export PSJLIBPATH
JVMLIBS="$JAVA_HOME/lib/amd64/server:$JAVA_HOME/bin"; export JVMLIBS
JAVA_FONTS="/usr/share/fonts/ko/TrueType${JAVA_FONTS+:$JAVA_FONTS}"
JAVA_FONTS="/usr/share/fonts/zh_TW/TrueType:$JAVA_FONTS"
JAVA_FONTS="/usr/share/fonts/zh_CN/TrueType:$JAVA_FONTS"
JAVA_FONTS="/usr/share/fonts/ja/TrueType:$JAVA_FONTS"
JAVA_FONTS="/usr/share/fonts/default/TrueType:$JAVA_FONTS"
# add fonts and custom fonts in PS_HOME (PeopleTools)
JAVA_FONTS="$PS_HOME/jre/lib/fonts:$JAVA_FONTS"; export JAVA_FONTS
PATH=$JAVA_HOME/bin:$PATH; export PATH
JAVA_VERSION=`$JAVA_HOME/bin/java -version 2>&1 | grep version | awk '{ print $3 }'`

########### Weblogic Setup - informational only overridden with domain config
WL_HOME=$PS_WEB_BASE/$PS_WEB_VER

######### TUXEDO Vars
TUXDIR="$PS_TUX_BASE/$PS_TUX_VER/tuxedo12.2.2.0.0"; export TUXDIR
if [[ -n $PS_APP_VER && ! -d "$TUXDIR/bin" ]]; then
  echo "TUXDIR Directory $TUXDIR does not exist, I cannot set this up"
  exit 1
fi
# java home declared above
SHLIB_PATH=$TUXDIR/lib:$JVMLIBS; export SHLIB_PATH
LIBPATH=$TUXDIR/lib:$JVMLIBS; export LIBPATH
LD_LIBRARY_PATH=$LD_LIBRARY_PATH:$TUXDIR/lib:$JVMLIBS; export LD_LIBRARY_PATH
WEBJAVADIR=$TUXDIR/udataobj/webgui/java; export WEBJAVADIR
# Tuxedo contains a defect with regard to process generation
# that requires this environment variable to be set.
TM_GP_AUTOSPAWNEXIT_FIX="yes"; export TM_GP_AUTOSPAWNEXIT_FIX
# The Tuxedo log file will be world writable without this
# environment variable set.
UMASKULOGPERM="yes"; export UMASKULOGPERM
PATH="$TUXDIR/bin:$PATH"; export PATH
# Fix annoying message in log by diabling message
export LLE_DEPRECATION_WARN_LEVEL=NONE

###### SQR and Libraries
SQR_HOME="$PS_HOME/bin/sqr/ORA"; export SQR_HOME
SQRDIR="$SQR_HOME/bin"; export SQRDIR
# LD_LIBRARY_PATH/SHLIB_PATH/LIBPATH environment variables
PS_LIBPATH="$PS_HOME/bin"; export PS_LIBPATH
LD_LIBRARY_PATH="$PSJLIBPATH${LD_LIBRARY_PATH+:$LD_LIBRARY_PATH}"
LD_LIBRARY_PATH="$LD_LIBRARY_PATH:$PS_HOME/bin:$PS_HOME/bin/interfacedrivers"
LD_LIBRARY_PATH="$LD_LIBRARY_PATH:$PS_HOME/bin/sqr/ORA/bin:$PS_HOME/optbin"
PATH="$PS_HOME/bin:$PS_HOME/python:$PS_HOME/bin/sqr/ORA/bin:$PATH"; export PATH

######### DB ADMIN and Client Vars
ADMIN="$ORACLE_BASE/admin"; export ADMIN
DBAHOME="$ADMIN/dba"; export DBAHOME
PS_DB=ORA;export PS_DB
PS_DBVER=12.2.x;export PS_DBVER
# skip oracle setup for web servers
if [[ -n $PS_APP_VER ]]; then
   ORACLE_SID="$PS_ORA_DB"; export ORACLE_SID
   NLS_LANG=AMERICAN_AMERICA.UTF8;export NLS_LANG
   LD_LIBRARY_PATH=$LD_LIBRARY_PATH:$ORACLE_HOME/lib; export LD_LIBRARY_PATH
   PATH="$ORACLE_HOME/bin:$DBAHOME:$PATH"; export PATH

   # Special TNS Names setup,  based on specific scenarios alternate TNS Names will be used
   # Base line TNS using full pool of Exadata nodes for a DB
   TNS_ADMIN="$ADMIN/tnsadmin";
   # Setup Scheduler to target distinct DB nodes for each scheduler
   # Each tnsnames is setup to point CS/FS/HR to specific Exadata nodes for controlled cluster distribution
   # This will allow us to patch Exadata by specific node and scheduler, allowing a rolling patch
   # with Scheduler server suspensions.
   THIS_HOST=`hostname -s`
   if [[ $THIS_HOST == *"prc"* ]]; then
     # check sequence number in host
     case "$THIS_HOST" in
       *1*)
          TNS_ADMIN="$ADMIN/tnsadmin/vm1"
          ;;
       *2*)
          TNS_ADMIN="$ADMIN/tnsadmin/vm2"
          ;;
       *3*)
          TNS_ADMIN="$ADMIN/tnsadmin/vm3"
          ;;
       *4*)
          TNS_ADMIN="$ADMIN/tnsadmin/vm4"
          ;;
     esac
   fi
   export TNS_ADMIN
fi

######### PSOFT General Vars - supporting vars in psconfig.sh
#IS_PS_PLT="Y"; export IS_PS_PLT
PS_HOSTTYPE="redhat-7-x86_64"; export PS_HOSTTYPE
# manually set for detault process file output
# determine path by server name, looking for process schedulers
# SERV_TYPE=`hostname | grep prc`
PRC_DOM=`echo $ORACLE_SID | tr '[:upper:]' '[:lower:]'`
if [ -d $PS_CFG_HOME/prcserv/$PRC_DOM ]; then
   PS_FILEDIR=$PS_CFG_HOME/prcserv/$PRC_DOM/files;export PS_FILEDIR
fi

######### COBOL - support separate homes (order:cust,app,tools)
## Note all compiled cobol runs from cust home
# skip cobol for web servers
if [[ -n $PS_APP_VER ]]; then
  if [[ -n $PS_CUST_HOME ]]; then
    COBPATH="$PS_CUST_HOME/cblbin"; export COBPATH
  fi
  if [[ $PS_APP_HOME != $PS_HOME ]]; then
    COBPATH="$COBPATH:$PS_APP_HOME/cblbin"; export COBPATH
  fi
  COBPATH="$COBPATH:$PS_HOME/cblbin"; export COBPATH
  # autosys
  CBLBIN=$COBPATH; export CBLBIN
  COBDIR=$PS_COBOL_BASE/$PS_COBOL_VER; export COBDIR
  COBCPY=$TUXDIR/cobinclude; export COBCPY
  COBOPT="-C ANS85 -C ALIGN=8 -C NOIBMCOMP -C TRUNC=ANSI -C OSEXT=cbl"; export COBOPT
  LD_LIBRARY_PATH=$LD_LIBRARY_PATH:$COBDIR/lib; export LD_LIBRARY_PATH
  PATH=$PATH:$COBDIR/bin;export PATH
fi

######## DMS
DM_HOME="$PS_BASE/dms"; export DM_HOME
PS_DM_DATA_IN="$PS_APP_HOME/data"; export PS_DM_DATA_IN
PS_DM_DATA_OUT="$PS_APP_HOME/data"; export PS_DM_DATA_OUT
#PS_DM_DATA_OUT="$DM_HOME/data"; export PS_DM_DATA_OUT
PS_DM_LOG="$DM_HOME/log"; export PS_DM_LOG
# Overridden via psadmin with PS_SERVDIR=PS_CFG_HOME/appserv/domain
# PS_FILE_DIR set above = PS_SERVDIR/files
PS_SERVDIR="$DM_HOME/PS_CACHE"; export PS_SERVDIR
PS_SERVER_CFG="$DM_HOME/psdmtx.cfg"; export PS_SERVER_CFG
PS_DM_SCRIPT="$PS_APP_HOME/scripts"; export PS_DM_SCRIPT

##### PSSA Tools

##### 3rd Parts apps/binaries
# TDAccess - SAIG - Financial Aid
PATH="$PATH:$PS_CUST_HOME/tdaccess"; export PATH
# ADDS Client - AVOW Transcripts
PATH="$PATH:$PS_CUST_HOME/addsclient/bin"; export PATH

##### Others - from psconfig.sh
  #
  # Save environment variables.
  # The PeopleSoft EM plugin depends on these saved values.
  #

  PS_LOGINVARS_HOME="$PS_BASE/psft"
  PS_LOGINVARS_FILE="$PS_LOGINVARS_HOME/ps_login_vars.sh"
  if [ ! -s "$PS_LOGINVARS_FILE" ]; then
    mkdir -p "$PS_LOGINVARS_HOME" > /dev/null 2>&1
    if [ -w "$PS_LOGINVARS_HOME" ]; then
      LOGINVARS="USER HOME MAIL SHELL"
      for var in $LOGINVARS; do
        if env | grep "^$var=" > /dev/null; then
          env | grep "^$var=" | sed -e "s/$/\"; export $var/" -e "s/^$var=/$var=\"/" >> "$PS_LOGINVARS_FILE.$$"
        fi
      done

      mv -f "$PS_LOGINVARS_FILE.$$" "$PS_LOGINVARS_FILE"

      unset LOGINVARS
    fi
  fi
  unset PS_LOGINVARS_FILE
  unset PS_LOGINVARS_HOME

####### clean up no longer needed env vars
unset PS_ORA_CLIENT_VER
unset PS_ORA_DB
unset PS_TOOLS_VER
unset PS_TUX_VER
unset PS_VERITY_VER
unset PS_WEB_VER
unset PS_TOOLS_BASE
unset PS_CONFIG_BASE
unset PS_WEB_BASE
unset PS_APP_BASE
unset PS_TUX_BASE
unset PS_VERITY_BASE
unset PS_COBOL_BASE
# Clear app or web specific vars
if [[ ! -n $PS_APP_VER ]]; then
  unset ORACLE_HOME
  unset ORACLE_SID
  unset COBDIR
  unset COBPATH
else
  unset WL_HOME
fi
