#! /usr/bin/env julia
module AndorSDK2CameraService

# include("../../Hsm.jl/src/Hsm.jl")
# include("../../Aeron.jl/src/Aeron.jl")

if Sys.islinux()
    include("../../AndorSDK2Mock.jl/src/AndorSDK2.jl")
    using .AndorSDK2
else
    using AndorSDK2
end

using Aeron
using Agent
using Clocks
using EnumX
using Hsm
using SnowflakeId
using SpidersFragmentFilters
using SpidersMessageCodecs
using StaticArrays
using SymbolConverters
using UnsafeArrays
using ValSplit

include("controlagent.jl")

ENV["STATUS_URI"] = "aeron:udp?endpoint=localhost:40123"
ENV["STATUS_STREAM_ID"] = "1"

ENV["CONTROL_URI"] = "aeron:udp?endpoint=0.0.0.0:40123"
ENV["CONTROL_STREAM_ID"] = "2"
ENV["CONTROL_STREAM_FILTER"] = "Camera"

ENV["PUB_DATA_URI_1"] = "aeron:udp?endpoint=132.246.192.209:40123"
ENV["PUB_DATA_STREAM_1"] = "3"

ENV["BLOCK_NAME"] = "Camera"

ENV["BLOCK_ID"] = "367"

ENV["CAMERA_INDEX"] = "1"

ENV["EXPOSURE_TIME"] = "0.0039"

Base.exit_on_sigint(false)

function main(ARGS)
    # md = Aeron.MediaDriver.launch()

    try
        # Initialize Aeron
        client = Aeron.Client()

        # Initialize the agent
        agent = ControlStateMachine(client, ENV["BLOCK_NAME"])

        # Start the agent
        runner = AgentRunner(BackoffIdleStrategy(), agent)
        Agent.start_on_thread(runner, 2)

        wait(runner)
    catch e
        if e isa TaskFailedException || e isa InterruptException
            @info "Shutting down..." exception = (e, catch_backtrace())
        else
            println("Error: ", e)
            @error "Exception caught:" exception = (e, catch_backtrace())
        end
    finally
        # close(md)
    end

    return 0
end

function offer(p, buf, max_attempts=10)
    attempts = max_attempts
    while attempts > 0
        result = Aeron.offer(p, buf)
        if result > 0
            return
        elseif result in (Aeron.PUBLICATION_BACK_PRESSURED, Aeron.PUBLICATION_ADMIN_ACTION)
            continue
        elseif result == Aeron.PUBLICATION_ERROR
            Aeron.throwerror()
        end
        attempts -= 1
    end
end

function try_claim(p, length, max_attempts=10)
    attempts = max_attempts
    while attempts > 0
        claim, result = Aeron.try_claim(p, length)
        if result > 0
            return claim
        elseif result in (Aeron.PUBLICATION_BACK_PRESSURED, Aeron.PUBLICATION_ADMIN_ACTION)
            continue
        elseif result == Aeron.PUBLICATION_ERROR
            Aeron.throwerror()
        end
        attempts -= 1
    end
end
end # module AndorSDK2CameraService

using .AndorSDK2CameraService
const main = AndorSDK2CameraService.main

@isdefined(var"@main") ? (@main) : exit(main(ARGS))

# end # module AndorSDK2CameraService