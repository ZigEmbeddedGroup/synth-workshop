#!/bin/sh

BIN_DIR=$(realpath $(dirname $0))
SCRIPTS_DIR=$(realpath ${BIN_DIR}/../share/openocd/scripts)

$BIN_DIR/openocd -s $SCRIPTS_DIR -f interface/cmsis-dap.cfg -f target/rp2040.cfg -c "adapter speed 5000"
