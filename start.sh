#!/bin/bash

# Set the environment variables
export JULIA_NUM_THREADS=3
export JULIA_PROJECT=@.
export STATUS_URI="aeron:udp?endpoint=localhost:40123"
export STATUS_STREAM_ID=1
export CONTROL_URI="aeron:udp?endpoint=0.0.0.0:40123"
export CONTROL_STREAM_ID=2
export CONTROL_STREAM_FILTER="Camera"
export PUB_DATA_URI_1="aeron:udp?endpoint=132.246.192.209:40123"
export PUB_DATA_STREAM_1=3
export BLOCK_NAME="Camera"
export BLOCK_ID=367
export CAMERA_INDEX=1
export WIDTH=128
export HEIGHT=128
export OFFSET_X=0
export OFFSET_Y=0
export BINNING_HORIZONTAL=2
export BINNING_VERTICAL=2
export EXPOSURE_TIME=0.0039

# Run the Julia script
julia -e "using AndorSDK2CameraService; AndorSDK2CameraService.main(ARGS)" "$@"
