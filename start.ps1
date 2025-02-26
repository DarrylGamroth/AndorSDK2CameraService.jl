# Set the environment variables
$env:JULIA_NUM_THREADS = auto
$env:JULIA_PROJECT = "@."
$env:STATUS_URI = "aeron:udp?endpoint=localhost:40123"
$env:STATUS_STREAM_ID = 1
$env:CONTROL_URI = "aeron:udp?endpoint=0.0.0.0:40123"
$env:CONTROL_STREAM_ID = 2
$env:CONTROL_STREAM_FILTER = "Camera"
$env:PUB_DATA_URI_1 = "aeron:udp?endpoint=132.246.192.209:40123"
$env:PUB_DATA_STREAM_1 = 3
$env:BLOCK_NAME = "Camera"
$env:BLOCK_ID = 367
$env:CAMERA_INDEX = 1
$env:WIDTH = 128
$env:HEIGHT = 128
$env:OFFSET_X = 0
$env:OFFSET_Y = 0
$env:BINNING_HORIZONTAL = 2
$env:BINNING_VERTICAL = 2
$env:EXPOSURE_TIME = 0.0039

# Run the Julia script
& "julia" -e "using AndorSDK2CameraService; AndorSDK2CameraService.main(ARGS)" $args