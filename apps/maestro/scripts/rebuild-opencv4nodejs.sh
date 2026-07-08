#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

export OPENCV4NODEJS_DISABLE_AUTOBUILD=1

npm rebuild @u4/opencv4nodejs --foreground-scripts --build-from-source
