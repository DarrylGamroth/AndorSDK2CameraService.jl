# store the buffer, message decoder instance and a cached decoded value from the decoder, which is just a reineterpretation of the buffer
# this would then be decode, get view, copy, decode again, store

val(x::Val{T}) where {T} = T

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

Hsm.on_event!(sm::ControlStateMachine, ::Val{Top}, ::Val{:Reset}, arg) = Hsm.transition!(sm, Top)

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

Hsm.on_event!(sm::ControlStateMachine, ::Val{Top}, ::Val{:Exit}, arg) = Hsm.transition!(sm, Exit)

function Hsm.on_event!(sm::ControlStateMachine, state::Val{Top}, event::Val{:Table}, arg)
    # A request was made to read all the variables
    # Post all read events to the control stream which will trigger the reads

    return Hsm.EventHandled
end

########################

Hsm.on_initial!(sm::ControlStateMachine, ::Val{Ready}) = Hsm.transition!(sm, Stopped)

function Hsm.on_entry!(sm::ControlStateMachine, ::Val{Ready})

    output_stream_uri = get(ENV, "PUB_DATA_URI_1") do
        error("Environment variable PUB_DATA_URI_1 not found")
    end

    output_stream_id = parse(Int, get(ENV, "PUB_DATA_STREAM_1") do
        error("Environment variable PUB_DATA_STREAM_1 not found")
    end)

    sm.output_stream = Aeron.add_publication(sm.client, output_stream_uri, output_stream_id)
end

function Hsm.on_event!(sm::ControlStateMachine, ::Val{Ready}, ::Val{:IDLE}, arg)
    sm.properties.DeviceTemperature, _ = AndorSDK2.temperature()
end

function Hsm.on_event!(sm::ControlStateMachine, ::Val{Ready}, ::Val{:TEMPCYCLE}, arg)
    sm.properties.DeviceTemperature, _ = AndorSDK2.temperature()
end

function Hsm.on_exit!(sm::ControlStateMachine, ::Val{Ready})
    close(sm.output_stream)
end

########################

function Hsm.on_entry!(sm::ControlStateMachine, state::Val{Stopped})
end

function Hsm.on_exit!(sm::ControlStateMachine, state::Val{Stopped})
end

# Default Handler for all events that aren't handled
@valsplit function Hsm.on_event!(sm::ControlStateMachine, state::Val{Top}, Val(event::Symbol), message)
    if event in propertynames(sm.properties)
        @warn "Default on_event!($(val(state)), $event). Handler may allocate."
        prop = getfield(sm.properties, event)
        if Event.format(message) == Event.Format.NOTHING
            send_event_response(sm, message, prop)
        end
    end
    return Hsm.EventNotHandled
end

# Default handler for all events in Stopped state, will defer to the specific handler if it exists
# This will always allocate as the event is not known at compile time
# @valsplit function Hsm.on_event!(sm::ControlStateMachine, state::Val{Stopped}, Val(event::Symbol), message)
#     @warn "Default on_event!($(val(state)), $event). Handler may allocate."
#     prop = getfield(sm.properties, event)
#     if Event.format(message) == Event.Format.NOTHING
#         send_event_response(sm, message, prop)
#     else
#         _, value = message(typeof(prop))
#         setfield!(sm.properties, event, value)
#     end
#     return Hsm.EventNotHandled
# end

# A specific handler is allocation free
# function Hsm.on_event!(sm::ControlStateMachine, state::Val{Stopped}, event::Val{:EMCCDGain}, message)
#     @info "on_event!($(val(state)), $(val(event)))"
#     sym = val(event)
#     prop = getfield(sm.properties, sym)
#     if Event.format(message) == Event.Format.NOTHING
#         send_event_response(sm, message, prop)
#     else
#         _, value = message(typeof(prop))
#         setfield!(sm.properties, sym, value)
#     end
#     return Hsm.EventHandled
# end

function Hsm.on_event!(sm::ControlStateMachine, state::Val{Stopped}, event::Val{:Play}, arg)
    if all_properties_set(sm)
        return Hsm.transition!(sm, Playing)
    else
        # For now don't transition
        Hsm.transition(sm, Error)
        return Hsm.EventHandled
    end
end

function Hsm.on_event!(sm::ControlStateMachine, state::Val{Stopped}, event::Val{:ExposureTime}, message)
    key = val(event)
    prop = getfield(sm.properties, key)
    if Event.format(message) == Event.Format.NOTHING
        value, _, _ = AndorSDK2.acquisition_timings()
        setfield!(sm.properties, key, value)
        send_event_response(sm, message, value)
    else
        _, value = message(typeof(prop))
        AndorSDK2.exposure_time!(value)
        setfield!(sm.properties, key, value)
    end

    return Hsm.EventHandled
end

function Hsm.on_event!(sm::ControlStateMachine, state::Val{Stopped}, event::Val{:AcquisitionFrameRate}, message)
    key = val(event)
    prop = getfield(sm.properties, key)
    if Event.format(message) == Event.Format.NOTHING
        _, _, value = AndorSDK2.acquisition_timings()
        setfield!(sm.properties, key, value)
        send_event_response(sm, message, value)
    else
        _, value = message(typeof(prop))
        AndorSDK2.kinetic_cycle_time!(value)
        setfield!(sm.properties, key, value)
    end

    return Hsm.EventHandled
end

function Hsm.on_event!(sm::ControlStateMachine, state::Val{Stopped}, event::Val{:EMCCDGain}, message)
    key = val(event)
    prop = getfield(sm.properties, key)
    if Event.format(message) == Event.Format.NOTHING
        value = AndorSDK2.emccd_gain()
        setfield!(sm.properties, key, value)
        send_event_response(sm, message, value)
    else
        _, value = message(typeof(prop))
        AndorSDK2.emccd_gain!(value)
        setfield!(sm.properties, key, value)
    end
    return Hsm.EventHandled
end

function Hsm.on_event!(sm::ControlStateMachine, ::Val{Stopped}, event::Val{:Gain}, message)
    key = val(event)
    prop = getfield(sm.properties, key)
    if Event.format(message) == Event.Format.NOTHING
        value = AndorSDK2.emccd_gain()
        setfield!(sm.properties, key, value)
        send_event_response(sm, message, value)
    else
        _, value = message(typeof(prop))
        AndorSDK2.emccd_gain!(value)
        setfield!(sm.properties, key, value)
    end
    return Hsm.EventHandled
end

function Hsm.on_event!(sm::ControlStateMachine, ::Val{Stopped}, event::Val{:DeviceTemperature}, message)
    key = val(event)
    prop = getfield(sm.properties, key)
    if Event.format(message) == Event.Format.NOTHING
        value, _ = AndorSDK2.temperature()
        setfield!(sm.properties, key, value)
        send_event_response(sm, message, value)
    else
        Hsm.transition!(sm, Error)
    end

    return Hsm.EventHandled
end

function Hsm.on_event!(sm::ControlStateMachine, ::Val{Stopped}, event::Val{:DeviceFanMode}, message)
    key = val(event)
    prop = getfield(sm.properties, key)
    if Event.format(message) == Event.Format.NOTHING
        value = getfield(sm.properties, key)
        send_event_response(sm, message, value)
    else
        _, value = message(typeof(prop))
        AndorSDK2.fan_mode!(value)
        setfield!(sm.properties, key, value)
    end

    return Hsm.EventHandled
end

function Hsm.on_event!(sm::ControlStateMachine, ::Val{Stopped}, event::Val{:DeviceCoolingEnabled}, message)
    key = val(event)
    prop = getfield(sm.properties, key)
    if Event.format(message) == Event.Format.NOTHING
        value = AndorSDK2.is_cooler_on()
        setfield!(sm.properties, key, value)
        send_event_response(sm, message, value)
    else
        _, value = message(typeof(prop))
        value ? AndorSDK2.cooler_on!() : AndorSDK2.cooler_off!()
        setfield!(sm.properties, key, value)
    end

    return Hsm.EventHandled
end

function Hsm.on_event!(sm::ControlStateMachine, ::Val{Stopped}, event::Val{:DeviceCoolingSetpoint}, message)
    key = val(event)
    prop = getfield(sm.properties, key)
    if Event.format(message) == Event.Format.NOTHING
        value = getfield(sm.properties, key)
        send_event_response(sm, message, prop)
    else
        _, value = message(Int)
        AndorSDK2.temperature!(value)
        setfield!(sm.properties, key, value)
    end

    return Hsm.EventHandled
end

########################

Hsm.on_event!(sm::ControlStateMachine, state::Val{Processing}, event::Val{:Stop}, arg) = Hsm.transition!(sm, Stopped)

########################

function Hsm.on_entry!(sm::ControlStateMachine, ::Val{Playing})
    # TODO move this to PROCESSING
    resize!(sm.frame_buffer, sm.properties.Width * sm.properties.Height)
    AndorSDK2.image!(sm.properties.BinningHorizontal,
        sm.properties.BinningVertical,
        sm.properties.OffsetX + 1,
        sm.properties.OffsetX + sm.properties.Width,
        sm.properties.OffsetY + 1,
        sm.properties.OffsetY + sm.properties.Height)
    AndorSDK2.baseline_clamp!(true)
    AndorSDK2.frame_transfer_mode!(sm.properties.FrameTransferMode)
    AndorSDK2.exposure_time!(sm.properties.ExposureTime)
    AndorSDK2.kinetic_cycle_time!(sm.properties.AcquisitionFrameRate)
    AndorSDK2.hss_speed!(0, 0)
    AndorSDK2.em_advanced!(false)
    AndorSDK2.em_gain_mode!(AndorSDK2.EMGainMode.REAL)
    AndorSDK2.emccd_gain!(sm.properties.EMCCDGain)
    sm.properties.DeviceExposureTime, _, sm.properties.DeviceAcquisitionFrameRate = AndorSDK2.acquisition_timings()
    sm.properties.Shutter = Integer(AndorSDK2.ShutterMode.OPEN)
    AndorSDK2.shutter!(AndorSDK2.ShutterSignalType.ACTIVE_HIGH, AndorSDK2.ShutterMode.OPEN, 50, 50)
    # But keep this
    AndorSDK2.start_acquisition()
end

function Hsm.on_exit!(sm::ControlStateMachine, ::Val{Playing})
    AndorSDK2.abort_acquisition()
    AndorSDK2.shutter!(AndorSDK2.ShutterSignalType.ACTIVE_HIGH, AndorSDK2.ShutterMode.CLOSED, 50, 50)
    sm.properties.Shutter = Integer(AndorSDK2.ShutterMode.CLOSED)
end

function Hsm.on_event!(sm::ControlStateMachine, state::Val{Playing}, event::Val{:ACQUIRING}, arg)
    # Read the image from the camera
    if AndorSDK2.most_recent_image(sm.frame_buffer)
        timestamp = clock_gettime(uv_clock_id.REALTIME)
        resize!(sm.buf, 128 + sizeof(sm.frame_buffer))
        message = Tensor.TensorMessageEncoder(sm.buf, Tensor.MessageHeader(sm.buf))
        header = Tensor.header(message)
        Tensor.timestampNs!(header, timestamp)
        Tensor.correlationId!(header, next_id(sm.id_gen))
        Tensor.tag!(String, header, Agent.name(sm))
        message(reshape(sm.frame_buffer, (sm.properties.Width, sm.properties.Height)))
        offer(sm.output_stream, convert(AbstractArray{UInt8}, message))
    end
    return Hsm.EventHandled
end

function Hsm.on_event!(sm::ControlStateMachine, state::Val{Playing}, event::Val{:IDLE}, arg)
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

Hsm.on_event!(sm::ControlStateMachine, state::Val{Playing}, event::Val{:Pause}, arg) = Hsm.transition(sm, Paused)

########################

function Hsm.on_entry!(sm::ControlStateMachine, state::Val{Exit})
    @info "Exiting..."
    AndorSDK2.shutdown()
    # Signal the AgentRunner to stop
    throw(AgentTerminationException())
end

########################

function Hsm.on_entry!(sm::ControlStateMachine, state::Val{Error})
    @info "Error"
end

