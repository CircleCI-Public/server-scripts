#!/bin/bash

function key_reminder() {
    echo ""
    echo "###########################################"
    echo "##   Encryption & Signing keys           ##"

    echo "##   must be updated in your values.yaml.  ##"
    echo "##   Then perform a helm upgrade.          ##"

    echo "###########################################"
    echo ""
    echo "You may find your keys here:  $(pwd)/circleci_export"
}