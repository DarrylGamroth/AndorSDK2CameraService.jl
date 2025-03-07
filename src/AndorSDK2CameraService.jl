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

const DEFAULT_FRAGMENT_COUNT_LIMIT = 10

include("controlagent.jl")
include("states.jl")

function main(ARGS)
    # md = Aeron.MediaDriver.launch()

    try
        # Initialize Aeron
        client = Aeron.Client()

        # Initialize the agent
        agent = ControlStateMachine(client, ENV["BLOCK_NAME"])

        # Start the agent
        runner = AgentRunner(BackoffIdleStrategy(), agent)
        Agent.start_on_thread(runner)

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
