#!/bin/bash

function key_reminder() {
    echo ""
    echo "###########################################"
    echo "##   Encryption & Signing keys           ##"

    # Adjust messaging for version of server
    if [ ! "$SERVER4" = "true" ];
    then
        echo "##   must be uploaded to kots.             ##"
    else
        echo "##   must be updated in your values.yaml.  ##"
        echo "##   Then perform a helm upgrade.          ##"
    fi

    echo "###########################################"
    echo ""
    echo "You may find your keys here:  $(pwd)/${KEY_BU}"

    # shellcheck disable=SC2010
    ls -lh "$KEY_BU" | grep -v ^total
}