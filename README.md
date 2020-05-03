# psoft_script_framework

A sample Linux scripting framework using a library and central inventory.

This bash framework is built on a few key ideas:
- Simple language that admins are comfortable with: bash
- Reusable functions and library organization.
- Run "anywhere" scripts.
- Leverage parallel for multi-tasking
- Central inventory of PeopleSoft instances.
- Standard script format and usage and error handling
- Reliable execution
- Shared storage execution.
- NFS compatibile locking with fcntl_lock
- Secure solution with no exposed passwords

Sample scripts provide services to:
- Stop/start/cycle Peoplesoft Web/App/Schedulers
- Run jobs with App Engine and DMS
- Change passwords
- Sample F5 Pool changes via Ansible modules.
