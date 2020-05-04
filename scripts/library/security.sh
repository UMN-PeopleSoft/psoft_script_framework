# Library: sec
# Script: security.sh
# Purpose: Security manager to control password access.  Uses a mapping to abstract
#     the conversion from a simple code to a variable in Ansible Vault.
#
# Note: Actual passwords are stored in the ansible vault that is password secured
#   When running a script that needs a password, user will be prompted
#     for a password to the vault.  Only Rundeck will be allowed to
#     automatically provide the vault password, allowing scripts to be scheduled.
#
# CB: Nate Werner
# Created: 11/22/2017
#
#### Functions
#
#  Security typeCodes for (Gen)eral services:
#       "f5","connect","rundeck","ps","vault"
#
#  Security typeCodes for DB services:
#       fsprd,csprd,hrprd,ihprd, fsnonprd,csnonprd,hrnonprd,ihnonprd
#
#  getandStoreVaultAccess()
#     Retrieves the vault password for ruther uses on local or remote VMs
#     and stores in a encrypted variable to prevent re-prompting for passwords
#
#  getGenSecurity(typeCode, out typePassword)
#     Retrieves the passwords for non DB Services
#
#  getAppEnvDBSecurity(app, env, out typePassword)
#     Retrieves the password for DB related users
#     can pass in app/env, and typeCode will be dynamically generated.
#
#  isValidUser()
#     Determins if current user is in a restricted PSSA group
#
#  getCurrentUser()
#     Returns the real user that logged in to server from a su/sudo.
###########################

#includes
if [ -z "$BOOTSTRAP_LOADED" ]; then
  currentPath="$( cd "$(dirname "$0")" && pwd )"
  source ${currentPath%${currentPath#*scripts*/}}library/bootstrap.sh
fi

# Passwords are stored in the ansible vault and secured with a password.
#  Check password for vault in Password Safe

# Password Type Codes passed into functions
PASS_OEM_SUPER_CODE="oem"
PASS_F5_CODE="f5"
PASS_RUNDECK_CODE="rundeck"
PASS_PS_UMSUPER_CODE="ps"
PASS_CONNECT_CODE="connect"
PASS_VAULT_CODE="vault"
PASS_WEBLOGIC_CODE="weblogic"
PASS_MONITORDB_CODE="monitordb"

# Keys to match variable name in Ansible vault
PASS_OEM_SUPER_KEY="oem_super_pass"
PASS_F5_KEY="f5_admin_pass"
PASS_RUNDECK_KEY="rundeck_api_pass"
PASS_PS_UMSUPER_KEY="psoft_pass.appumsuper.pt857.pass"
PASS_CONNECT_KEY="appserver_connect_pass"
PASS_VAULT_KEY="ansible_vault_pass"
PASS_WEBLOGIC_KEY="psoft_pass.webadmin.pt857.pass"
PASS_MONITORDB_KEY="monitoring_db_user_pass"

function __mapCodetoKey() # typeCode, returns keystring
{
  local typeCode=$1
  local keyString=""

  case "$typeCode" in
    "$PASS_OEM_SUPER_CODE")
       keyString=$PASS_OEM_SUPER_KEY
       ;;
    "$PASS_F5_CODE")
       keyString=$PASS_F5_KEY
       ;;
    "$PASS_RUNDECK_CODE")
       keyString=$PASS_RUNDECK_KEY
       ;;
    "$PASS_PS_UMSUPER_CODE")
       keyString=$PASS_PS_UMSUPER_KEY
       ;;
    "$PASS_CONNECT_CODE")
       keyString=$PASS_CONNECT_KEY
       ;;
    "$PASS_VAULT_CODE")
       keyString=$PASS_VAULT_KEY
       ;;
    "$PASS_WEBLOGIC_CODE")
       keyString=$PASS_WEBLOGIC_KEY
       ;;
    "$PASS_MONITORDB_CODE")
       keyString=$PASS_MONITORDB_KEY
       ;;
  esac
  if [ -z "${keyString}" ]; then
    echo "Invalid Password type provided: $typeCode"
    return 1
  else
    echo "${keyString}"
    return 0
  fi
}

# Use this function to get a password for a service that is not app/env specific
#   Applies to services like f5, rundeck, connect, common psoft users etc
function sec::getGenSecurity() #typeCode, out typePassword
{
   local typeCode="$1"
   local varPass=$2
   local currentDate=""
   local VaultPass_File=""
   local passwdKey=""
   local reqPasword=""
   local vaultResult=0

   # Only allow PSSA user access to function
   if sec::isValidUser; then

     # Lookup key from type provided
     if [[ "${typeCode:0:2}" == "DB" ]]; then
       # extract the app/env string in the type ie: 'DB:cstst'
       #  and build the variable like 'psoft_pass.db.cstst.pass', stored in group_vars/all/var file.
       passwdKey="psoft_pass.db.${typeCode:3}.pass"
     else
       passwdKey=$( __mapCodetoKey $typeCode )
     fi
     if [ $? -eq 0 ]; then
       util::log "DEBUG" "sec::getGenSecurity: Mapped code to Key $passwdKey"
       # got a valid key, lookup password
       # run ansible to read password from vault

       # Check if Vault password was provided by env var
       if [ -n "$ANSIBLE_VAULT" ]; then
         # create a unique temporary vault password file
         currentDate="$(date +%y%m%d%H%M%S%N )"
         VaultPass_File="$ANSIBLE_HOME/tmp/ggsv_${PARALLEL_SEQ}_$currentDate"
         # use function getvaultaccess to encrypt the ANSIBLE_VAULT variable
         echo "$ANSIBLE_VAULT" | openssl enc -aes-128-cbc -a -d -salt -pass env:USER > $VaultPass_File
         chmod 600 $VaultPass_File
         util::log "DEBUG" "sec::getGenSecurity: Running ansible localhost --vault-password-file $VaultPass_File -m debug -a \"var=${passwdKey}\""
         reqPasword=$( cd $ANSIBLE_HOME && ANSIBLE_LOG_PATH=/dev/null ansible localhost --vault-password-file $VaultPass_File -m debug -a "var=${passwdKey}" | grep "${passwdKey}" | awk -F'"' '{ print $4}' )
       else
         # no password provide, will be prompted
         util::log "DEBUG" "sec::getGenSecurity: Running ansible localhost --ask-vault-pass -m debug -a \"var=${passwdKey}\""
         reqPasword=$( cd $ANSIBLE_HOME && ANSIBLE_LOG_PATH=/dev/null ansible localhost --ask-vault-pass -m debug -a "var=${passwdKey}" | grep "${passwdKey}" | awk -F'"' '{ print $4 }' | sed 's/\$/\\$/' )
       fi
       vaultResult=$?
       if [ -n "$ANSIBLE_VAULT" ]; then
         rm $VaultPass_File > /dev/null 2>&1
       fi

       if [[ -z "${reqPasword}" || $vaultResult -ne 0 ]]; then
         util::log "ERROR" "Unable to retrive password from vault!"
         return 1
       else
         eval "$varPass"'="${reqPasword}"'
         return 0
       fi
     else
       # invalid typeCode
       util::log "ERROR" "Invalid type code provided, check options"
       return 1
     fi
   else
     util::log "ERROR" "You are not authorized to access psoft security"
     return 1
   fi
}

# Prompts for vault password and stores in encrypted variable
# used my maint library to store vault pass before using for
# other passwords, prevents user needing to be reprompted
# in same session of a maint function.  Works for remote
# function calls by parameter
function sec::getandStoreVaultAccess()
{
   local vaultPass
   local encryptPass=""

   # Bypass if running from RunDeck
   if sec::setRDVaultAccess; then
     util::log "DEBUG" "sec::getandStoreVaultAccess - Read Rundeck provided password"
     return 0
   else
     # Only allow PSSA user access to function
     if sec::isValidUser; then
       util::log "DEBUG" "sec::getandStoreVaultAccess: Valid user retreiving password for vault"

       if [ -z "$ANSIBLE_VAULT" ]; then
         # Call the security access function for the vault pass
         sec::getGenSecurity "vault" vaultPass
         if [[ $? -ne 0 ]]; then
           return 1
         fi
         encryptPass=$( echo "$vaultPass" | openssl enc -aes-128-cbc -a -salt -pass env:USER )
         util::log "DEBUG" "sec::getandStoreVaultAccess - Store vault pass $encryptPass"
         export ANSIBLE_VAULT="${encryptPass}"
         return 0
       fi
     else
       util::log "ERROR" "You are not authorized to access psoft security"
       return 1
     fi
   fi
}

# Use for when it is passed by env variable (Rundeck)
function sec::setRDVaultAccess()
{
   if [ -n "$RD_OPTION_VAULTPASS" ]; then
     encryptPass=$( echo "$RD_OPTION_VAULTPASS" | openssl enc -aes-128-cbc -a -salt -pass env:USER )
     util::log "DEBUG" "sec::getandStoreVaultAccess - Store vault pass $encryptPass"
     export ANSIBLE_VAULT="${encryptPass}"
     return 0
   else
     return 1
   fi
}

# Use this function to get a password for a service this is unique to an app/env
#   Specifically applies to DB schema owners for PSoft envs.
function sec::getAppEnvDBSecurity() #app, env, out typePassword
{
   local app="$1"
   local env="$2"
   local varPass=$3
   # prefix with 'DB:' to identify a DB pasword for specific app/env
   local typeCode="DB:$app$env"
   local dbPass
   local secResult=0

   util::log "DEBUG" "sec::getAppEnvDBSecurity Accessing pass for $typeCode"
   sec::getGenSecurity "${typeCode}" dbPass
   secResult=$?
   eval "$varPass"'="${dbPass}"'
   return $secResult
}

# Sample Basic mechanism to restrict an action to only certain members, aka root could be restricted
function sec::isValidUser()
{
   #local currUser=$( sec::getCurrentUser )
   #if [[ "$VALID_USER_LIST" == *$currUser* ]]; then
   #   util::log "DEBUG" "sec::isValidUser: Current user $currUser has requested access"
      return 0
   #else
   #   util::log "ERROR" "sec::isValidUser: Current user $currUser is not allowed"
   #   return 1
   #fi
}

# determines who is really logged into host
# Reads a process tree to determine the user that initiated the ssh call to the server
function sec::getCurrentUser()
{
   local sessID=$( ps -o sess| tail -1 )
   local userId=$( ps ao pid,tid,sess,ruser | grep "$sessID $sessID $sessID" | awk '{ print $4 '} | tail -1)
   echo "$userId"
}
