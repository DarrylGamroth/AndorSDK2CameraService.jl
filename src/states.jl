# store the buffer, message decoder instance and a cached decoded value from the decoder, which is just a reineterpretation of the buffer
# this would then be decode, get view, copy, decode again, store

Hsm.current(sm::ControlStateMachine) = sm.current
Hsm.current!(sm::ControlStateMachine, s::Symbol) = sm.current = s
Hsm.source(sm::ControlStateMachine) = sm.source
Hsm.source!(sm::ControlStateMachine, s::Symbol) = sm.source = s

# Define all states
const Top = Hsm.Root
const Ready = :Ready
const Processing = :Processing
const Paused = :Paused
const Playing = :Playing
const Stopped = :Stopped
const Error = :Error
const Exit = :Exit

# Implement the AbstractHsm ancestor interface for each state
Hsm.ancestor(::ControlStateMachine, ::Val{Ready}) = Top
Hsm.ancestor(::ControlStateMachine, ::Val{Stopped}) = Ready
Hsm.ancestor(::ControlStateMachine, ::Val{Processing}) = Ready
Hsm.ancestor(::ControlStateMachine, ::Val{Paused}) = Processing
Hsm.ancestor(::ControlStateMachine, ::Val{Playing}) = Processing
Hsm.ancestor(::ControlStateMachine, ::Val{Error}) = Top
Hsm.ancestor(::ControlStateMachine, ::Val{Exit}) = Top

########################
using StringViews
Base.convert(::Type{<:AbstractString}, s::Symbol) = StringView(convert(UnsafeArray{UInt8}, s))
Base.convert(::Type{<:AbstractString}, ::Val{T}) where {T} = StringView(convert(UnsafeArray{UInt8}, T))

function send_event_response(sm::ControlStateMachine, message::Event.EventMessage, value)
    timestamp = clock_gettime(uv_clock_id.REALTIME)

    response = Event.EventMessageEncoder(sm.buf, sm.sbe_position_ptr, Event.MessageHeader(sm.buf))
    header = Event.header(response)

    Event.timestampNs!(header, timestamp)
    Event.correlationId!(header, message |> Event.header |> Event.correlationId)
    Event.tag!(header, Agent.name(sm))

    response(Event.key(String, message), value)
    Aeron.offer(sm.status_stream, convert(AbstractArray{UInt8}, response))
end

########################

Hsm.on_initial!(sm::ControlStateMachine, ::Val{Top}) = Hsm.transition!(sm, Ready)

Hsm.on_event!(sm::ControlStateMachine, state::Val{Top}, event::Val{:Reset}, arg) =
    Hsm.transition!(sm, Top) do
    end

function Hsm.on_event!(sm::ControlStateMachine, state::Val{Top}, event::Val{:State}, message)
    send_event_response(sm, message, Hsm.current(sm))
    return Hsm.EventHandled
end

function Hsm.on_event!(sm::ControlStateMachine, state::Val{Top}, event::Val{:GC}, arg)
    GC.gc()
    return Hsm.EventHandled
end

function Hsm.on_event!(sm::ControlStateMachine, state::Val{Top}, event::Val{:GC_enable_logging}, message)
    (_, value) = message(Bool)
    GC.enable_logging(value)
    return Hsm.EventHandled
end

Hsm.on_event!(sm::ControlStateMachine, state::Val{Top}, event::Val{:Exit}, arg) = Hsm.transition!(sm, Exit)

function Hsm.on_event!(sm::ControlStateMachine, state::Val{Top}, event::Val{:Table}, arg)
    # A request was made to read all the variables
    # Post all read events to the control stream which will trigger the reads

    return Hsm.EventHandled
end

########################

Hsm.on_initial!(sm::ControlStateMachine, ::Val{Ready}) = Hsm.transition!(sm, Stopped)

function Hsm.on_entry!(sm::ControlStateMachine, ::Val{Ready})
    output_stream_uri = ENV["PUB_DATA_URI_1"]
    output_stream_id = parse(Int, ENV["PUB_DATA_STREAM_1"])

    sm.output_stream = Aeron.add_publication(sm.client, output_stream_uri, output_stream_id)

    AndorSDK2.initialize()
    AndorSDK2.read_mode!(AndorSDK2.ReadMode.IMAGE)
    AndorSDK2.image!(1, 1, 1, 128, 1, 128)
    AndorSDK2.frame_transfer_mode!(true)
    AndorSDK2.acquisition_mode!(AndorSDK2.AcquisitionMode.RUN_TILL_ABORT)
    AndorSDK2.trigger_mode!(AndorSDK2.TriggerMode.INTERNAL)
    AndorSDK2.exposure_time!(0.3)
    AndorSDK2.kinetic_cycle_time!(0)
end

function Hsm.on_exit!(sm::ControlStateMachine, ::Val{Ready})
    close(sm.output_stream)
end

########################

function Hsm.on_entry!(sm::ControlStateMachine, state::Val{Stopped})
end

function Hsm.on_exit!(sm::ControlStateMachine, state::Val{Stopped})
end

Hsm.on_event!(sm::ControlStateMachine, state::Val{Stopped}, event::Val{:Play}, arg) = Hsm.transition!(sm, Playing)

function Hsm.on_event!(sm::ControlStateMachine, state::Val{Stopped}, event::Val{:ExposureTime}, message)
    if Event.format(message) == Event.Format.NOTHING
        value, _, _ = AndorSDK2.acquisition_timings()
        send_event_response(sm, message, value)
    else
        _, value = message(Int32)
        AndorSDK2.exposure_time!(value)
    end

    return Hsm.EventHandled
end

function Hsm.on_event!(sm::ControlStateMachine, ::Val{Stopped}, event::Val{:Gain}, message)
    if Event.format(message) == Event.Format.NOTHING
        value = AndorSDK2.emccd_gain()
        send_event_response(sm, message, value)
    else
        _, value = message(Int32)
        AndorSDK2.emccd_gain!(value)
    end

    return Hsm.EventHandled
end

function Hsm.on_event!(sm::ControlStateMachine, ::Val{Stopped}, event::Val{:DeviceTemperature}, message)
    if Event.format(message) == Event.Format.NOTHING
        value, _ = AndorSDK2.temperature()
        send_event_response(sm, message, value)
    else
        _, value = message(Int32)
        AndorSDK2.temperature!(value)
    end

    return Hsm.EventHandled
end

########################

Hsm.on_event!(sm::ControlStateMachine, state::Val{Processing}, event::Val{:Stop}, arg) = Hsm.transition!(sm, Stopped)

########################

function Hsm.on_entry!(sm::ControlStateMachine, ::Val{Playing})
    AndorSDK2.shutter!(AndorSDK2.ShutterSignalType.ACTIVE_HIGH, AndorSDK2.ShutterMode.OPEN, 50, 50)
    AndorSDK2.start_acquisition()
end

function Hsm.on_exit!(sm::ControlStateMachine, ::Val{Playing})
    AndorSDK2.abort_acquisition()
    AndorSDK2.shutter!(AndorSDK2.ShutterSignalType.ACTIVE_HIGH, AndorSDK2.ShutterMode.CLOSED, 50, 50)
end

function Hsm.on_event!(sm::ControlStateMachine, state::Val{Playing}, event::Val{:IDLE}, arg)
    # Read the image from the camera
    timestamp = clock_gettime(uv_clock_id.REALTIME)
    AndorSDK2.acquired_data(sm.frame_buffer)
    resize!(sm.buf, 128 + sizeof(sm.frame_buffer))
    message = Tensor.TensorMessageEncoder(sm.buf, Tensor.MessageHeader(sm.buf))
    header = Tensor.header(message)
    Tensor.timestampNs!(header, timestamp)
    Tensor.correlationId!(header, next_id(sm.id_gen))
    Tensor.tag!(String, header, Agent.name(sm))
    message(sm.frame_buffer)
    offer(sm.output_stream, convert(AbstractArray{UInt8}, message))
    return Hsm.EventHandled
end

function Hsm.on_event!(sm::ControlStateMachine, state::Val{Playing}, event::Val{:ACQUIRING}, arg)
    return Hsm.EventHandled
end

function Hsm.on_event!(sm::ControlStateMachine, state::Val{Playing}, event::Val{:TEMPCYCLE}, arg)
    return Hsm.EventHandled
end

function Hsm.on_event!(sm::ControlStateMachine, state::Val{Playing}, event::Val{:ACCUM_TIME_NOT_MET}, arg)
    Hsm.transition!(sm, Error)
end

function Hsm.on_event!(sm::ControlStateMachine, state::Val{Playing}, event::Val{:ACCUM_TIME_NOT_MET}, arg)
    Hsm.transition!(sm, Error)
end

function Hsm.on_event!(sm::ControlStateMachine, state::Val{Playing}, event::Val{:KINETIC_TIME_NOT_MET}, arg)
    Hsm.transition!(sm, Error)
end

function Hsm.on_event!(sm::ControlStateMachine, state::Val{Playing}, event::Val{:ERROR_ACK}, arg)
    Hsm.transition!(sm, Error)
end

function Hsm.on_event!(sm::ControlStateMachine, state::Val{Playing}, event::Val{:ACQ_BUFFER}, arg)
    Hsm.transition!(sm, Error)
end

function Hsm.on_event!(sm::ControlStateMachine, state::Val{Playing}, event::Val{:ACQ_DOWNFIFO_FULL}, arg)
    Hsm.transition!(sm, Error)
end

function Hsm.on_event!(sm::ControlStateMachine, state::Val{Playing}, event::Val{:SPOOL_ERROR}, arg)
    Hsm.transition!(sm, Error)
end

########################

function Hsm.on_entry!(sm::ControlStateMachine, state::Val{Exit})
    # Signal the AgentRunner to stop
    throw(AgentTerminationException())
end

########################

function Hsm.on_entry!(sm::ControlStateMachine, state::Val{Error})
    @info "Error"
end

