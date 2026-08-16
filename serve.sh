#!/bin/bash

./update_data.sh

cd src
hugo server -D -b http://localhost:1313/ -M
