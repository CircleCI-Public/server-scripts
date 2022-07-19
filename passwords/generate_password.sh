#!/bin/bash
set -e

function check_prereq(){
    if ! command -v docker --version &> /dev/null
    then
        error_exit "docker could not be found."
    elif [ "$(docker ps | grep -c 'CONTAINER ID')" == 0 ]
    then
        error_exit "docker is not running."
    fi
}

function gen_password(){
    env LC_ALL=C tr -dc 'A-Za-z0-9_' < /dev/urandom | head -c "$1"
}

function sign_enc_keys(){
    sign=$(docker run circleci/server-keysets:latest generate signing -a stdout)
    enc=$(docker run circleci/server-keysets:latest generate encryption -a stdout)
    echo """
keyset:
  encryption: '$enc'
  signing: '$sign'
"""
}

function error_exit(){
  msg="$*"
  if [ -n "$msg" ] || [ "$msg" != "" ]; then
    echo "------->> Error: $msg"
  fi
  kill $$
}

############ MAIN ############

# Checking Pre-Req
check_prereq

# Generating Passwords
sign_enc_keys
echo "apiToken: \"$(gen_password 48)\""
echo "sessionCookieKey: \"$(gen_password 16)\""
echo """
postgresql:
  auth:
    postgresPassword: \"$(gen_password 32)\"
"""
echo """
mongodb:
  auth:
    rootPassword: \"$(gen_password 32)\"
    password: \"$(gen_password 20)\"
"""
echo """
pusher:
  secret: \"$(gen_password 48)\"
"""
echo """
rabbitmq:
  auth:
    erlangCookie: \"$(gen_password 32)\"
    password: \"$(gen_password 32)\"
"""
