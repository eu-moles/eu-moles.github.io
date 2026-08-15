#!/bin/bash

cd src

if [[ ! -f data/meps.xml ]] || (( $(date +%s) - $(stat -c %Y data/meps.xml) > $((24 * 60 * 60)) )); then
  wget -qO data/meps.xml https://www.europarl.europa.eu/meps/en/full-list/xml
fi

hugo build --minify --gc