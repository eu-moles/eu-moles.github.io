#!/bin/bash

./update_data.sh

cd src
hugo build --minify --gc
