#!/bin/env bash
# Name:  psoft_profile.sh
# Updated: 11/30/2012
# Created by: Nate
# Called by: .bash_profile
#
# main profile interactions for psoft user
# implements the interactive aspects to psoft login
# not ran for sub shells, scp, sftp, cron, etc
###################

### Anything further is only for user interactive login
# skipped for scp, cron, or ssh with command parameters
if [[ $- != *i* ]] ; then
  # Shell is non-interactive.  Be done now!
   return
fi

# Setup ls/directory colors based on terminal type
if [ "$TERM" == "putty-256color" ]; then
  eval "$(dircolors ~/.dir_colors.putty-256color)"
else
  if [ "$TERM" == "puttydark-256color" ]; then
    eval "$(dircolors ~/.dir_colors.puttydark-256color)"
  else
    eval "$(dircolors ~/.dir_colors)"
  fi
fi

#### interactive psoft sudo login
# provide system info and currently installed domains and admin options
. $SCRIPT_HOME/admin/domainStatus

##### setup prompt to include current PS_HOME
PS1='\[\033[01;34m\][\u@\h \[\033[01;36m\]$PS_APP_VER\[\033[01;34m\]]\[\033[01;34m\] \W \[\033[00m\]\$ '

###### setup auto-complete (tab) with ssh and PS VM servers

if [ -f /usr/local/share/bash-completion/bash_completion ]; then
  . /usr/local/share/bash-completion/bash_completion
fi

function _sshcomplete() {

    # parse all defined hosts from .ssh/config
    if [ -r $HOME/.ssh/config ]; then
        COMPREPLY=($(compgen -W "$(grep ^Host $HOME/.ssh/config | awk '{print $2}' )" -- ${COMP_WORDS[COMP_CWORD]}))
    fi

    # parse all hosts found in .ssh/known_hosts
    if [ -r $HOME/.ssh/known_hosts ]; then
        if grep -v -q -e '^ ssh-rsa' $HOME/.ssh/known_hosts ; then
        COMPREPLY=( ${COMPREPLY[@]} $(compgen -W "$( awk '{print $1}' $HOME/.ssh/known_hosts | cut -d, -f 1 | sed -e 's/\[//g' | sed -e 's/\]//g' | cut -d: -f1 | grep -v ssh-rsa)" -- ${COMP_WORDS[COMP_CWORD]} ))
        fi
    fi

    return 0
}

complete -o default -o nospace -F _sshcomplete ssh
