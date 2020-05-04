# Library: ansible
# Script: ansible.sh
# Purpose: support functions to run an ansible playbook for domain or env
# CB: Nate Werner
# Created: 1/22/2018
#
# Functions:
#  dynConfigPlaybook( domainType, hostList, playbookFile )
#  runPlaybook( extraVarsString, debugFlag, playbookFile )
####################

## Global
dynamicInventoryFile="psoft_inventory.py"

function ansible::dynConfigPlaybook() # domainType, hostList, playbookFile
{
  local domainType="$1"
  local hostList="$2"
  local playbookFile="$3"

  # dynamically configure the playbook based on the domain being created
  sed -i "s/- hosts:.*/- hosts: ${hostList}/" $ANSIBLE_HOME/$playbookFile
  # Clear the list of roles to run and re-add apprpriate ones
  sed -i "/roles:/q" $ANSIBLE_HOME/$playbookFile
  if [ "${domainType}" == "web" ]; then
    echo "    - weblogic_common" >> $ANSIBLE_HOME/$playbookFile
    echo "    - weblogic_pia" >> $ANSIBLE_HOME/$playbookFile
    echo "    - weblogic_ib" >> $ANSIBLE_HOME/$playbookFile
    echo "    - coherence" >> $ANSIBLE_HOME/$playbookFile
  elif [ "${domainType}" == "app" ]; then
    echo "    - appserver" >> $ANSIBLE_HOME/$playbookFile
  elif [ "${domainType}" == "prc" ]; then
    echo "    - scheduler" >> $ANSIBLE_HOME/$playbookFile
  else # all
    echo "    - appserver" >> $ANSIBLE_HOME/$playbookFile
    echo "    - scheduler" >> $ANSIBLE_HOME/$playbookFile
    echo "    - weblogic_common" >> $ANSIBLE_HOME/$playbookFile
    echo "    - weblogic_pia" >> $ANSIBLE_HOME/$playbookFile
    echo "    - weblogic_ib" >> $ANSIBLE_HOME/$playbookFile
    echo "    - coherence" >> $ANSIBLE_HOME/$playbookFile
  fi

}

function ansible::runPlaybook() # extraVarsString, debugFlag, playbookFile
{
  local extraVarsString="$1"
  local debugFlag="$2"
  local playbookFile="$3"
  local vaultPassFile="$ANSIBLE_HOME/tmp/.vp"
  local vaultPass=""

  # set the environment variable path to the "dynamic" inventory used by ansible
  #  This path will be read by psoft_inventory.py
  export INVENTORY_FILE="$DOMAIN_LIST"
  # move to ansible playbook home
  cd $ANSIBLE_HOME

  ## Setup vault access
  # use env var to get vault pass
  sec::getGenSecurity "vault" vaultPass
  # temporarilly write file for F5 access
  echo "${vaultPass}" > $vaultPassFile
  chmod 600 $vaultPassFile

  # run dynamic Playbook for specific domain
  # Display command to user
  util::log "INFO" "Ansible Command: \n  ansible-playbook -i $dynamicInventoryFile --extra-vars '$extraVarsString' $debugFlag $playbookFile\n"
  # Now kick off the ansible playbook

  ansible-playbook -i $dynamicInventoryFile --vault-password-file $vaultPassFile --extra-vars "$extraVarsString" $debugFlag $playbookFile

  rm $vaultPassFile

}
