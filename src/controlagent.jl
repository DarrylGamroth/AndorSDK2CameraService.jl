mutable struct ControlStateMachine <: Hsm.AbstractHsmStateMachine
    client::Aeron.Client
    name::String

    id_gen::SnowflakeId.SnowflakeIdGenerator

    # SBE fields
    sbe_position_ptr::Base.RefValue{Int64}
    buf::Vector{UInt8}

    # Aeron streams
    status_stream::Aeron.Publication
    control_stream::Aeron.Subscription
    input_streams::Vector{Aeron.Subscription}
    output_stream::Aeron.Publication

    # Fragment handlers
    control_fragment_handler::Aeron.FragmentAssembler
    input_fragment_handler::Aeron.FragmentAssembler

    # State machine interface fields
    current::Symbol
    source::Symbol

    # Camera
    frame_buffer::Vector{UInt16}

    start::UInt64
    count::UInt64

    message::Event.EventMessage

    ControlStateMachine(client, name) = new(client, name)
end

Agent.name(sm::ControlStateMachine) = sm.name

function Agent.on_start(sm::ControlStateMachine)
    @info "Starting agent $(Agent.name(sm))"
    try
        Hsm.initialize!(sm)

        sm.count = 0

        sm.sbe_position_ptr = Ref(0)
        sm.buf = zeros(UInt8, 1024)
        sm.frame_buffer = UInt16[]

        node_id = parse(Int, get(ENV, "NODE_ID") do
            error("Environment variable NODE_ID not found")
        end)

        sm.id_gen = SnowflakeId.SnowflakeIdGenerator(node_id)

        # Get configuration from environment variables
        status_uri = get(ENV, "STATUS_URI") do
            error("Environment variable STATUS_URI not found")
        end

        status_stream_id = parse(Int, get(ENV, "STATUS_STREAM_ID") do
            error("Environment variable STATUS_STREAM_ID not found")
        end)

        # Publication for status messages
        sm.status_stream = Aeron.add_publication(sm.client, status_uri, status_stream_id)

        control_uri = get(ENV, "CONTROL_URI") do
            error("Environment variable CONTROL_URI not found")
        end

        control_stream_id = parse(Int, get(ENV, "CONTROL_STREAM_ID") do
            error("Environment variable CONTROL_STREAM_ID not found")
        end)

        sm.control_stream = Aeron.add_subscription(sm.client, control_uri, control_stream_id)

        fragment_handler = Aeron.FragmentHandler(control_handler, sm)

        if haskey(ENV, "CONTROL_STREAM_FILTER")
            message_filter = SpidersEventTagFragmentFilter(fragment_handler, ENV["CONTROL_STREAM_FILTER"])
            sm.control_fragment_handler = Aeron.FragmentAssembler(message_filter)
        else
            sm.control_fragment_handler = Aeron.FragmentAssembler(fragment_handler)
        end

        sm.input_fragment_handler = Aeron.FragmentAssembler(Aeron.FragmentHandler(data_handler, sm))

        # # Subscribe to all data streams
        i = 1
        sm.input_streams = Vector{Aeron.Subscription}(undef, 0)
        while haskey(ENV, "SUB_DATA_URI_$i")
            uri = ENV["SUB_DATA_URI_$i"]
            stream_id = parse(Int, get(ENV, "SUB_DATA_STREAM_$i") do
                error("Environment variable SUB_DATA_STREAM_$i not found")
            end)
            subscription = Aeron.add_subscription(sm.client, uri, stream_id)
            push!(sm.input_streams, subscription)
            i += 1
        end
    catch e
        @error "Error starting agent $(Agent.name(sm)). Exception caught:" exception = (e, catch_backtrace())
    end
end

function Agent.on_close(sm::ControlStateMachine)
    @info "Closing agent $(Agent.name(sm))"
    close(sm.status_stream)
    close(sm.control_stream)
    for (subscription, _) in sm.input_streams
        close(subscription)
    end
end

function Agent.on_error(sm::ControlStateMachine, error)
    timestamp = clock_gettime(uv_clock_id.REALTIME)

    message = Event.EventMessageEncoder(agent.buf, agent.sbe_position_ptr, Event.MessageHeader(agent.buf))
    header = Event.header(message)

    Event.timestampNs!(header, timestamp)
    Event.correlationId!(header, next_id(sm.id_gen))
    Event.tag!(header, Agent.name(agent))
    message("Error", "$error")

    Aeron.offer(agent.status_stream, convert(AbstractArray{UInt8}, message))

    @error "Error in agent $(Agent.name(sm)): $error" exception = (error, catch_backtrace())

    throw(error)
end

const DEFAULT_FRAGMENT_COUNT_LIMIT = 10
function Agent.do_work(sm::ControlStateMachine)
    sm.start = time_ns()
    work_done = 0

    # Read input from data streams until no more fragments are available
    while true
        all_streams_empty = true
        input_fragment_handler = sm.input_fragment_handler

        for subscription in sm.input_streams
            fragments_read = Aeron.poll(subscription, input_fragment_handler, DEFAULT_FRAGMENT_COUNT_LIMIT)
            work_done += fragments_read
            if fragments_read > 0
                all_streams_empty = false
            end
        end
        if all_streams_empty
            break
        end
    end

    # Process control messages
    work_done += Aeron.poll(sm.control_stream, sm.control_fragment_handler, DEFAULT_FRAGMENT_COUNT_LIMIT)

    return work_done
end

function acknowledge_message(sm::ControlStateMachine, message::Event.EventMessage)
    # This should be able to use try_claim but it allocates
    if Hsm.current(sm) != Error
        offer(sm.status_stream, convert(AbstractArray{UInt8}, message))
    end
end

function on_state_changed(sm::ControlStateMachine, message::Event.EventMessage)
    timestamp = clock_gettime(uv_clock_id.REALTIME)

    state_message = Event.EventMessageEncoder(sm.buf, sm.sbe_position_ptr, Event.MessageHeader(sm.buf))
    header = Event.header(state_message)

    Event.timestampNs!(header, timestamp)
    Event.correlationId!(header, message |> Event.header |> Event.correlationId)
    Event.tag!(header, Agent.name(sm))

    state_message("StateChange", Hsm.current(sm))

    Aeron.offer(sm.status_stream, convert(AbstractArray{UInt8}, state_message))
end

function on_state_changed(sm::ControlStateMachine, message::Tensor.TensorMessage)
    timestamp = clock_gettime(uv_clock_id.REALTIME)

    state_message = Event.EventMessageEncoder(sm.buf, sm.sbe_position_ptr, Event.MessageHeader(sm.buf))
    header = Event.header(state_message)

    Event.timestampNs!(header, timestamp)
    Event.correlationId!(header, message |> Tensor.header |> Tensor.correlationId)
    Event.tag!(header, Agent.name(sm))

    state_message("StateChange", Hsm.current(sm))

    Aeron.offer(sm.status_stream, convert(AbstractArray{UInt8}, state_message))
end

function control_handler(sm::ControlStateMachine, buffer, header)
    # A single buffer may contain several Event messages. Decode each one at a time and dispatch
    offset = 0
    while offset < length(buffer)
        sbe_header = Event.MessageHeader(buffer, offset)
        message = Event.EventMessageDecoder(buffer, offset, sm.sbe_position_ptr, sbe_header)
        event = Event.key(Symbol, message)

        if dispatch!(sm, event, message) == Hsm.EventHandled
            acknowledge_message(sm, message)
        end

        offset += Event.sbe_decoded_length(message) + Event.sbe_encoded_length(sbe_header)
    end

    nothing
end

function data_handler(sm::ControlStateMachine, buffer, header)
    message = Tensor.TensorMessageDecoder(buffer, sm.sbe_position_ptr, Tensor.MessageHeader(buffer))
    tag = Symbol(Tensor.tag(String, Tensor.header(message)))

    dispatch!(sm, tag, message)

    nothing
end

function dispatch!(sm::ControlStateMachine, event::Hsm.EventType, message)
    try
        prev = Hsm.current(sm)

        handled = Hsm.dispatch!(sm, event, message)

        if prev != Hsm.current(sm)
            on_state_changed(sm, message)
        end

        stop = time_ns() - sm.start
        @info "Dispatched event $(event) in $(Int64(stop)) ns"

        return handled
    catch e
        if e isa AgentTerminationException
            throw(e)
        end

        @error "Error in dispatch" exception = (e, catch_backtrace())
        Hsm.transition!(sm, Error)
    end
end

function Base.convert(::Type{Symbol}, status::AndorSDK2.Status.T)
    status == AndorSDK2.Status.IDLE ? :IDLE :
    status == AndorSDK2.Status.TEMPCYCLE ? :TEMPCYCLE :
    status == AndorSDK2.Status.ACQUIRING ? :ACQUIRING :
    status == AndorSDK2.Status.ACCUM_TIME_NOT_MET ? :ACCUM_TIME_NOT_MET :
    status == AndorSDK2.Status.KINETIC_TIME_NOT_MET ? :KINETIC_TIME_NOT_MET :
    status == AndorSDK2.Status.ERROR_ACK ? :ERROR_ACK :
    status == AndorSDK2.Status.ACQ_BUFFER ? :ACQ_BUFFER :
    status == AndorSDK2.Status.ACQ_DOWNFIFO_FULL ? :ACQ_DOWNFIFO_FULL :
    status == AndorSDK2.Status.SPOOL_ERROR ? :SPOOL_ERROR :
    throw(ArgumentError("Unexpected status"))
end

function poll_camera(sm::ControlStateMachine)
    if Hsm.current(sm) == Playing
        status = AndorSDK2.get_status()
        event = convert(Symbol, status)
        dispatch!(sm, event, nothing)
    end
    nothing
end

include("states.jl")
