#!/bin/bash

# -a enables advanced mode, which prompts for additional configuration
# variables (encryption keys, internal database passwords, etc.) that are
# otherwise hidden and automatically generated.
CONFIG_ADVANCED=false

while getopts "a" ARG; do
  case $ARG in
    a)
      CONFIG_ADVANCED=true
      ;;
    \?)
      echo "Usage: $0 [-a]"
      echo "  -a  Advanced mode: prompt for all configuration variables"
      exit 1
      ;;
  esac
done

ANSIBLE_STDOUT_CALLBACK=minimum_text ansible-playbook -i 'localhost,' -e "CONFIG_ADVANCED=${CONFIG_ADVANCED}" playbooks/config_vars.yml
