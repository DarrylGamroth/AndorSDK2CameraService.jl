#! /usr/bin/env julia
using Revise

module AndorSDK2CameraService
using DispatchDoctor
using AllocCheck

# include("../../Hsm.jl/src/Hsm.jl")
# include("../../Aeron.jl/src/Aeron.jl")

include("../../AndorSDK2Mock.jl/src/AndorSDK2.jl")
using .AndorSDK2

using Aeron
using Agent
using BenchmarkTools
using EnumX
using Hsm
using SnowflakeId
using SpidersFragmentFilters
using SpidersMessageCodecs
using StaticArrays
using ThreadPinning
using UnsafeArrays
using ValSplit

include("uvclockgetttime.jl")
include("controlagent.jl")

ENV["STATUS_URI"] = "aeron:udp?endpoint=localhost:40123"
ENV["STATUS_STREAM_ID"] = "1"

ENV["CONTROL_URI"] = "aeron:udp?endpoint=localhost:40123"
ENV["CONTROL_STREAM_ID"] = "2"
ENV["CONTROL_STREAM_FILTER"] = "Camera"

ENV["PUB_DATA_URI_1"] = "aeron:udp?endpoint=localhost:40123"
ENV["PUB_DATA_STREAM_1"] = "3"

ENV["BLOCK_NAME"] = "Camera"

ENV["BLOCK_ID"] = "367"

ENV["CAMERA_INDEX"] = "1"

Base.exit_on_sigint(false)

function main(ARGS)
    # Initialize Aeron
    try
        client = Aeron.Client()

        # Initialize the agent
        agent = ControlStateMachine(client, ENV["BLOCK_NAME"])

        # Start the agent
        runner = AgentRunner(BusySpinIdleStrategy(), agent)
        Agent.start_on_thread(runner, 2)

        wait(runner)
    catch e
        if e isa TaskFailedException || e isa InterruptException
            @info "Shutting down..."
        else
            println("Error: ", e)
            @error "Exception caught:" exception = (e, catch_backtrace())
        end
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