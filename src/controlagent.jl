@enumx T = X PropertyAccessMode begin
    ReadOnly
    ReadWrite
    WriteOnly
end

@kwdef mutable struct Property{T<:Union{AbstractArray,AbstractString,Real,Symbol}}
    value::Union{Nothing,T} = nothing
    isset::Bool = false
    const access::PropertyAccessMode.X = PropertyAccessMode.ReadWrite
    const min_value = T <: Number ? typemin(T) : nothing
    const max_value = T <: Number ? typemax(T) : nothing
end

function Base.setproperty!(p::Property, value)
    if p.access == PropertyAccessMode.ReadOnly
        throw(ArgumentError("Property is read-only"))
    end

    if p.min_value !== nothing && value < p.min_value
        throw(ArgumentError("Value $value is less than minimum value $(p.min_value)"))
    end

    if p.max_value !== nothing && value > p.max_value
        throw(ArgumentError("Value $value is greater than maximum value $(p.max_value)"))
    end

    setfield!(p, :value, value)
    setfield!(p, :isset, true)
    nothing
end

# Refactor using Property
# Just set the values here for now
@kwdef mutable struct Properties
    Name::String
    SensorWidth::Union{Nothing,Int64} = nothing
    SensorHeight::Union{Nothing,Int64} = nothing
    BinningHorizontal::Int64 = parse(Int64, get(ENV, "BINNING_HORIZONTAL", "1"))
    BinningVertical::Int64 = parse(Int64, get(ENV, "BINNING_VERTICAL", "1"))
    OffsetX::Int64 = parse(Int64, get(ENV, "OFFSET_X", "0"))
    OffsetY::Int64 = parse(Int64, get(ENV, "OFFSET_Y", "0"))
    Width::Union{Nothing,Int64} = parse(Int64, get(ENV, "WIDTH", "128"))
    Height::Union{Nothing,Int64} = parse(Int64, get(ENV, "HEIGHT", "128"))
    ExposureTime::Union{Nothing,Float64} = parse(Float64, get(ENV, "EXPOSURE_TIME", "0.01"))
    AcquisitionFrameRate::Union{Nothing,Float64} = 0.0

    TriggerSource::Int64 = Integer(AndorSDK2.TriggerMode.EXTERNAL)
    Shutter::Int64 = Integer(AndorSDK2.ShutterMode.OPEN)

    DeviceAcquisitionFrameRate::Float64 = 0.0
    DeviceCoolingEnable::Bool = false
    DeviceCoolingSetpoint::Float64 = -45.0
    DeviceCoolingStatus::Int64 = 0
    DeviceExposureTime::Float64 = 0.0
    DeviceFanMode::Int64 = 2
    DeviceModelName::Union{Nothing,AbstractString} = nothing
    DeviceSerialNumber::Union{Nothing,AbstractString} = nothing
    DeviceTemperature::Int64 = 0

    EMCCDGain::Union{Nothing,Float64} = 1.0
    EMAdvanced::Bool = false
    FastExternalTrigger::Bool = false
    FrameTransferMode::Bool = true
    HorizontalShiftSpeed::Float64 = 0.0
    VerticalShiftSpeed::Float64 = 0.0

    PreAmpGainIndex::Int64 = 0
    VerticalShiftSpeedIndex::Int64 = 0
    VerticalShiftAmplitudeIndex::Int64 = 0
end

mutable struct ControlStateMachine <: Hsm.AbstractHsmStateMachine
    client::Aeron.Client
    properties::Properties
    clock::EpochClock
    id_gen::SnowflakeIdGenerator

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

    # Camera
    frame_buffer::Vector{UInt16}

    # State variables
    current::Hsm.StateType
    source::Hsm.StateType

    ControlStateMachine(client, name) = new(client, Properties(; Name=name), EpochClock())
end

function all_properties_set(sm::ControlStateMachine)
    return all(!isnothing(getfield(sm.properties, field)) for field in fieldnames(Properties))
end

property_type(sm::ControlStateMachine, name) = typeof(getfield(sm.properties, name))
property_type(sm::ControlStateMachine, ::Val{T}) where {T} = typeof(getfield(sm.properties, T))


Agent.name(sm::ControlStateMachine) = sm.properties.Name

function Agent.on_start(sm::ControlStateMachine)
    @info "Starting agent $(Agent.name(sm))"

    sm.sbe_position_ptr = Ref(0)
    sm.buf = zeros(UInt8, 1024)
    sm.frame_buffer = UInt16[]

    node_id = parse(Int, get(ENV, "BLOCK_ID") do
        error("Environment variable BLOCK_ID not found")
    end)

    sm.id_gen = SnowflakeIdGenerator(node_id)

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

    # Initialize the camera

    # Default to the first camera
    camera_index = parse(Int, get(ENV, "CAMERA_INDEX", "1"))
    initialize_camera(sm, camera_index)

    Hsm.initialize!(sm)
end

function Agent.on_close(sm::ControlStateMachine)
    @info "Closing agent $(Agent.name(sm))"
    AndorSDK2.shutdown()

    close(sm.status_stream)
    close(sm.control_stream)
    for (subscription, _) in sm.input_streams
        close(subscription)
    end
end

function Agent.on_error(sm::ControlStateMachine, error)
    timestamp = time_nanos(sm.clock)

    message = Event.EventMessageEncoder(agent.buf, agent.sbe_position_ptr, Event.MessageHeader(agent.buf))
    header = Event.header(message)

    Event.timestampNs!(header, timestamp)
    Event.correlationId!(header, next_id(sm.id_gen))
    Event.tag!(header, Agent.name(agent))
    message("Error", "$error")

    Aeron.offer(agent.status_stream, convert(AbstractArray{UInt8}, message))

    @error "Error in agent $(Agent.name(sm)): $error" exception = (error, catch_backtrace())
end

const DEFAULT_FRAGMENT_COUNT_LIMIT = 10
function Agent.do_work(sm::ControlStateMachine)
    work_count = 0

    # Poll for camera events
    work_count += poll_camera(sm)

    # Read input from data streams until no more fragments are available
    while true
        all_streams_empty = true
        input_fragment_handler = sm.input_fragment_handler

        for subscription in sm.input_streams
            fragments_read = Aeron.poll(subscription, input_fragment_handler, DEFAULT_FRAGMENT_COUNT_LIMIT)
            if fragments_read > 0
                all_streams_empty = false
            end
            work_count += fragments_read
        end
        if all_streams_empty
            break
        end
    end

    # Process control messages
    work_count += Aeron.poll(sm.control_stream, sm.control_fragment_handler, DEFAULT_FRAGMENT_COUNT_LIMIT)

    return work_count
end

# FIXME This might need to be rethought. Sending a empty message will perform a read
# and send a reply, this is a write event acknowledgement
function acknowledge_message(sm::ControlStateMachine, message::Event.EventMessage)
    # FIXME: try_claim could be used here but it currently doesn't work
    if Hsm.current(sm) != :Error
        offer(sm.status_stream, convert(AbstractArray{UInt8}, message))
    end
end

# These two functions will be combined once SpidersMessageCodecs is updated
function on_state_changed(sm::ControlStateMachine, message::Event.EventMessage)
    timestamp = time_nanos(sm.clock)

    state_message = Event.EventMessageEncoder(sm.buf, sm.sbe_position_ptr, Event.MessageHeader(sm.buf))
    header = Event.header(state_message)

    Event.timestampNs!(header, timestamp)
    Event.correlationId!(header, message |> Event.header |> Event.correlationId)
    Event.tag!(header, Agent.name(sm))

    state_message("StateChange", Hsm.current(sm))

    Aeron.offer(sm.status_stream, convert(AbstractArray{UInt8}, state_message))
end

function on_state_changed(sm::ControlStateMachine, message::Tensor.TensorMessage)
    timestamp = time_nanos(sm.clock)

    state_message = Event.EventMessageEncoder(sm.buf, sm.sbe_position_ptr, Event.MessageHeader(sm.buf))
    header = Event.header(state_message)

    Event.timestampNs!(header, timestamp)
    Event.correlationId!(header, message |> Tensor.header |> Tensor.correlationId)
    Event.tag!(header, Agent.name(sm))

    state_message("StateChange", Hsm.current(sm))

    Aeron.offer(sm.status_stream, convert(AbstractArray{UInt8}, state_message))
end

function control_handler(sm::ControlStateMachine, buffer, _)
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

function data_handler(sm::ControlStateMachine, buffer, _)
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

        return handled
    catch e
        if e isa AgentTerminationException
            throw(e)
        end

        @error "Error in dispatch" exception = (e, catch_backtrace())
        # FIXME The error should be saved in the state machine
        Hsm.transition!(sm, :Error)
    end
end

function poll_camera(sm::ControlStateMachine)
    status = AndorSDK2.status()
    dispatch!(sm, Symbol(status), nothing)
    # No work is done in IDLE
    return Integer(status != AndorSDK2.Status.IDLE)
end

function initialize_camera(sm::ControlStateMachine, camera_index)
    if camera_index > AndorSDK2.available_cameras()
        throw(ArgumentError("Camera index $camera_index is out of range"))
    end

    AndorSDK2.current_camera!(camera_index - 1)

    AndorSDK2.initialize()

    sm.properties.DeviceModelName = AndorSDK2.head_model()
    sm.properties.DeviceSerialNumber = string(AndorSDK2.camera_serial_number())
    sm.properties.SensorWidth, sm.properties.SensorHeight = AndorSDK2.detector()
    AndorSDK2.acquisition_mode!(AndorSDK2.AcquisitionMode.RUN_TILL_ABORT)
    AndorSDK2.read_mode!(AndorSDK2.ReadMode.IMAGE)
    AndorSDK2.dma_parameters!(1, 0.001)
end

include("states.jl")
