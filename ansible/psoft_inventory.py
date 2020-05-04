#!/bin/env python
# Psoft Dynamic Inventory script.
# Converts config/domains/domain.list into a JSON string to support ansible.
# Creates 3 types of groups to represent the hosts.
#
# Group 1:   app-env  (ie:  csdev - list of all hosts that run cs app for dev env )
# Group 2:   env      (ie:  dev - list of all hosts that run dev envs )
# Group 3:   app      (ie:  cs  - list of all hosts that run cs envs )a
# Group 4:   type-env (ie:  web-dev - list of host that run a specific domain type and env)
# *ALL   :   built-in representing all hosts.
#
# Each host will have a domains Dictionary[] var defined representing all domains running
#   the host.  This dictionary holds these values:
#     domain.
#         app   (name of app this domain runs)
#         env   (name of env this domain runs)
#         type  (type of domains "web","app","prc")
#         apptype (sub-type of domain "PIA","IB","REN")
#         rpt   ("Y", "N" specifying if domains is a Reporting domain)
#         purpose ("main", "ib", "ren")
#         tools_ver (version of tools the domain is running on)
#         weblogic_ver (version of weblogic the web domain is running on)
#  Usage:  domain['csdev1'].env  would return "dev"
#

import argparse
import ConfigParser
import os
import re
from time import time
import subprocess

try:
    import json
except ImportError:
    import simplejson as json

class PsoftInventory(object):

    def __init__(self):
        self.inventory = {}
        self.read_cli_args()

        # Called with `--list`.
        if self.args.list:
            self.inventory = self.psoft_domain_inventory()
        # Called with `--host [hostname]`.
        elif self.args.host:
            # Not implemented, since we return _meta info `--list`.
            self.inventory = self.empty_inventory()
        # If no groups or vars are present, return empty inventory.
        else:
            self.inventory = self.empty_inventory()

    def psoft_domain_inventory(self):

      # Setup groups
      input_file = open(os.environ['INVENTORY_FILE'], 'r')
      input_file.readline()

      # Loop through all domains to build groups
      for line in input_file:
         (name, type, app, env, rpt, purpose, serverName, host, tools_ver, weblogic_ver) = line.split(' ')
         # init the group if it does not already exist
         if rpt == "Y" and env == "qat":
            env = "qrpt"
         if rpt == "Y" and env == "prd":
            env = "rpt"
         if not app + env in self.inventory:
            self.inventory[app + env] = { 'hosts': [] }
         if not app in self.inventory:
            self.inventory[app] = { 'hosts': [] }
         if not env in self.inventory:
            self.inventory[env] = { 'hosts': [] }
         if not type + env in self.inventory:
            self.inventory[type + env] = { 'hosts': [] }

         if not host in self.inventory[app + env]['hosts']:
            self.inventory[app + env]['hosts'].append(host)
         if not host in self.inventory[app]['hosts']:
            self.inventory[app]['hosts'].append(host)
         if not host in self.inventory[env]['hosts']:
            self.inventory[env]['hosts'].append(host)
         if not host in self.inventory[type + env]['hosts']:
            self.inventory[type + env]['hosts'].append(host)

      # next loop through domains agina to build meta - host variables
      self.inventory['_meta'] = { 'hostvars': {} }
      input_file.seek(0, 0)
      input_file.readline()
      for line in input_file:
         (name, type, app, env, rpt, purpose, serverName, host, tools_ver, weblogic_ver) = line.split(' ')
         if not host in  self.inventory['_meta']['hostvars']:
            self.inventory['_meta']['hostvars'][host] = { 'domains': [] }
            self.inventory['_meta']['hostvars'][host]['ansible_python_interpreter'] = 'python3'

         # now add domains to domains host vars
         # remote last character (Return) from weblogic_ver
         self.inventory['_meta']['hostvars'][host]['domains'].append( { 'name': name, 'type': type, 'app': app, 'env': env, 'rpt': rpt, 'purpose': purpose, 'server_name': serverName, 'tools_ver': tools_ver, 'weblogic_ver': weblogic_ver[:-1] } )

      input_file.close()

      ansible_formatted = json.dumps(self.inventory, sort_keys=True, indent=2)

      print ansible_formatted

    # Empty inventory for testing.
    def empty_inventory(self):
        return {'_meta': {'hostvars': {}}}

    # Read the command line args passed to the script.
    def read_cli_args(self):
        parser = argparse.ArgumentParser()
        parser.add_argument('--list', action = 'store_true')
        parser.add_argument('--host', action = 'store')
        self.args = parser.parse_args()

# Get the inventory.
PsoftInventory()
