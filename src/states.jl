# store the buffer, message decoder instance and a cached decoded value from the decoder, which is just a reineterpretation of the buffer
# this would then be decode, get view, copy, decode again, store

val(x::Val{T}) where {T} = T

Hsm.current(sm::ControlStateMachine) = sm.current
Hsm.current!(sm::ControlStateMachine, s::Symbol) = sm.current = s
Hsm.source(sm::ControlStateMachine) = sm.source
Hsm.source!(sm::ControlStateMachine, s::Symbol) = sm.source = s

# Implement the AbstractHsm ancestor interface for each state
Hsm.ancestor(::ControlStateMachine, ::Val{:Top}) = Hsm.Root
Hsm.ancestor(::ControlStateMachine, ::Val{:Ready}) = :Top
Hsm.ancestor(::ControlStateMachine, ::Val{:Stopped}) = :Ready
Hsm.ancestor(::ControlStateMachine, ::Val{:Processing}) = :Ready
Hsm.ancestor(::ControlStateMachine, ::Val{:Paused}) = :Processing
Hsm.ancestor(::ControlStateMachine, ::Val{:Playing}) = :Processing
Hsm.ancestor(::ControlStateMachine, ::Val{:Error}) = :Top
Hsm.ancestor(::ControlStateMachine, ::Val{:Exit}) = :Top

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

Hsm.on_initial!(sm::ControlStateMachine, ::Val{Hsm.Root}) = Hsm.transition!(sm, :Top)

########################

Hsm.on_initial!(sm::ControlStateMachine, ::Val{:Top}) = Hsm.transition!(sm, :Playing)

Hsm.on_event!(sm::ControlStateMachine, ::Val{:Top}, ::Val{:Reset}, _) = Hsm.transition!(sm, :Top)

function Hsm.on_event!(sm::ControlStateMachine, ::Val{:Top}, event::Val{:State}, message)
    send_event_response(sm, message, Hsm.current(sm))
    return Hsm.EventHandled
end

function Hsm.on_event!(sm::ControlStateMachine, ::Val{:Top}, event::Val{:GC}, _)
    GC.gc()
    return Hsm.EventHandled
end

function Hsm.on_event!(sm::ControlStateMachine, ::Val{:Top}, ::Val{:GC_enable_logging}, message)
    _, value = message(Bool)
    GC.enable_logging(value)
    return Hsm.EventHandled
end

Hsm.on_event!(sm::ControlStateMachine, ::Val{:Top}, ::Val{:Exit}, _) = Hsm.transition!(sm, :Exit)

function Hsm.on_event!(sm::ControlStateMachine, ::Val{:Top}, ::Val{:Properties}, message)
    # FIXME Post read events to the event queue for each property to be processed by the state machine
    if Event.format(message) == Event.Format.NOTHING
        for name in propertynames(sm.properties)
            timestamp = clock_gettime(uv_clock_id.REALTIME)

            value = getfield(sm.properties, name)
            response = Event.EventMessageEncoder(sm.buf, sm.sbe_position_ptr, Event.MessageHeader(sm.buf))
            header = Event.header(response)

            Event.timestampNs!(header, timestamp)
            Event.correlationId!(header, message |> Event.header |> Event.correlationId)
            Event.tag!(header, Agent.name(sm))

            response(convert(String, name), value)
            Aeron.offer(sm.status_stream, convert(AbstractArray{UInt8}, response))
        end
        return Hsm.EventHandled
    else
        return Hsm.transition!(sm, :Error)
    end
end

# Default Handler for all events that aren't handled
@valsplit function Hsm.on_event!(sm::ControlStateMachine, state::Val{:Top}, Val(event::Symbol), message)

    # Check if the event is a property
    if event in propertynames(sm.properties)
        @warn "Default on_event!($(val(state)), $event). Handler may allocate."

        if Event.format(message) == Event.Format.NOTHING
            # If the message has no value, then it is a request for the current value
            value = getfield(sm.properties, event)
            send_event_response(sm, message, value)
        else
            # Otherwise it's a write request
            _, value = message(property_type(sm, event))
            setfield!(sm.properties, event, value)
            # send_event_response(sm, message, prop)
        end
        return Hsm.EventHandled
    end

    # Defer to the specific handler if it exists
    return Hsm.EventNotHandled
end

########################

Hsm.on_initial!(sm::ControlStateMachine, ::Val{:Ready}) = Hsm.transition!(sm, :Stopped)

function Hsm.on_entry!(sm::ControlStateMachine, ::Val{:Ready})

    output_stream_uri = get(ENV, "PUB_DATA_URI_1") do
        error("Environment variable PUB_DATA_URI_1 not found")
    end

    output_stream_id = parse(Int, get(ENV, "PUB_DATA_STREAM_1") do
        error("Environment variable PUB_DATA_STREAM_1 not found")
    end)

    sm.output_stream = Aeron.add_publication(sm.client, output_stream_uri, output_stream_id)
end

function Hsm.on_event!(sm::ControlStateMachine, ::Val{:Ready}, ::Val{:IDLE}, _)
    sm.properties.DeviceTemperature, _ = AndorSDK2.temperature()
end

function Hsm.on_event!(sm::ControlStateMachine, ::Val{:Ready}, ::Val{:TEMPCYCLE}, _)
    sm.properties.DeviceTemperature, _ = AndorSDK2.temperature()
end

function Hsm.on_exit!(sm::ControlStateMachine, ::Val{:Ready})
    close(sm.output_stream)
end

########################

# Default handler for all events in Stopped state, will defer to the specific handler if it exists
# This will always allocate as the event is not known at compile time
# @valsplit function Hsm.on_event!(sm::ControlStateMachine, state::Val{:Stopped}, Val(event::Symbol), message)
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
# function Hsm.on_event!(sm::ControlStateMachine, state::Val{:Stopped}, event::Val{:EMCCDGain}, message)
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

function Hsm.on_event!(sm::ControlStateMachine, ::Val{:Stopped}, ::Val{:Play}, _)
    # Only transition if all properties are set
    if all_properties_set(sm)
        Hsm.transition!(sm, :Playing)
    else
        # For now don't transition
        # Hsm.transition!(sm, :Error)
    end
end

function Hsm.on_event!(sm::ControlStateMachine, ::Val{:Stopped}, event::Val{:DeviceFanMode}, message)
    if Event.format(message) == Event.Format.NOTHING
        return Hsm.EventNotHandled
    else
        key = val(event)
        _, value = message(property_type(sm, key))
        AndorSDK2.fan_mode!(value)
        setfield!(sm.properties, key, value)
    end

    return Hsm.EventHandled
end

function Hsm.on_event!(sm::ControlStateMachine, ::Val{:Stopped}, event::Val{:DeviceCoolingEnable}, message)
    key = val(event)
    if Event.format(message) == Event.Format.NOTHING
        value = AndorSDK2.is_cooler_on()
        setfield!(sm.properties, key, value)
        send_event_response(sm, message, value)
    else
        _, value = message(property_type(sm, key))
        value ? AndorSDK2.cooler_on!() : AndorSDK2.cooler_off!()
        setfield!(sm.properties, key, value)
    end

    return Hsm.EventHandled
end

function Hsm.on_event!(sm::ControlStateMachine, ::Val{:Stopped}, event::Val{:DeviceCoolingSetpoint}, message)
    if Event.format(message) == Event.Format.NOTHING
        return Hsm.EventNotHandled
    else
        key = val(event)
        _, value = message(property_type(sm, key))
        AndorSDK2.temperature!(value)
        setfield!(sm.properties, key, value)
    end

    return Hsm.EventHandled
end

########################

Hsm.on_initial!(sm::ControlStateMachine, ::Val{:Processing}) = Hsm.transition!(sm, :Paused)

function Hsm.on_entry!(sm::ControlStateMachine, ::Val{:Processing})
    resize!(sm.frame_buffer, sm.properties.Width * sm.properties.Height)
    AndorSDK2.image!(sm.properties.BinningHorizontal,
        sm.properties.BinningVertical,
        sm.properties.OffsetX + 1,
        sm.properties.OffsetX + sm.properties.Width,
        sm.properties.OffsetY + 1,
        sm.properties.OffsetY + sm.properties.Height)
    AndorSDK2.baseline_clamp!(true)
    AndorSDK2.frame_transfer_mode!(sm.properties.FrameTransferMode)
    AndorSDK2.fast_ext_trigger!(sm.properties.FastExternalTrigger)
    AndorSDK2.exposure_time!(sm.properties.ExposureTime)
    AndorSDK2.kinetic_cycle_time!(sm.properties.AcquisitionFrameRate)
    AndorSDK2.hss_speed!(0, 0)
    AndorSDK2.em_advanced!(sm.properties.EMAdvanced)
    AndorSDK2.em_gain_mode!(AndorSDK2.EMGainMode.REAL)
    AndorSDK2.emccd_gain!(sm.properties.EMCCDGain)
    AndorSDK2.pre_amp_gain!(sm.properties.PreAmpGainIndex)
    AndorSDK2.vss_speed!(sm.properties.VerticalShiftSpeedIndex)
    AndorSDK2.vs_amplitude!(sm.properties.VerticalShiftAmplitudeIndex)

    # Read the current values from the camera
    sm.properties.HorizontalShiftSpeed = AndorSDK2.hss_speed(0, 0, 0)
    sm.properties.VerticalShiftSpeed = AndorSDK2.vss_speed(sm.properties.VerticalShiftSpeedIndex)
    sm.properties.DeviceExposureTime, _, sm.properties.DeviceAcquisitionFrameRate = AndorSDK2.acquisition_timings()
    sm.properties.Shutter = Integer(AndorSDK2.ShutterMode.OPEN)
    sm.properties.DeviceTemperature, _ = AndorSDK2.temperature()

    AndorSDK2.shutter!(AndorSDK2.ShutterSignalType.ACTIVE_HIGH, AndorSDK2.ShutterMode.OPEN, 50, 50)
    AndorSDK2.start_acquisition()
end

function Hsm.on_exit!(sm::ControlStateMachine, ::Val{:Processing})
    AndorSDK2.abort_acquisition()
    AndorSDK2.shutter!(AndorSDK2.ShutterSignalType.ACTIVE_HIGH, AndorSDK2.ShutterMode.CLOSED, 50, 50)
    sm.properties.Shutter = Integer(AndorSDK2.ShutterMode.CLOSED)
end

Hsm.on_event!(sm::ControlStateMachine, ::Val{:Processing}, ::Val{:Stop}, _) = Hsm.transition!(sm, :Stopped)

########################

function Hsm.on_event!(sm::ControlStateMachine, ::Val{:Playing}, ::Val{:ACQUIRING}, _)
    if AndorSDK2.most_recent_image(sm.frame_buffer)
        # Read the image from the camera. The image should be written directly to the SBE message
        # or sent as a vector of buffers to offer
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

Hsm.on_event!(sm::ControlStateMachine, ::Val{:Playing}, ::Val{:Pause}, _) = Hsm.transition!(sm, :Paused)
Hsm.on_event!(sm::ControlStateMachine, ::Val{:Playing}, ::Val{:IDLE}, _) = Hsm.EventNotHandled
Hsm.on_event!(sm::ControlStateMachine, ::Val{:Playing}, ::Val{:TEMPCYCLE}, _) = Hsm.EventNotHandled
Hsm.on_event!(sm::ControlStateMachine, ::Val{:Playing}, ::Val{:ACCUM_TIME_NOT_MET}, _) = Hsm.transition!(sm, :Error)
Hsm.on_event!(sm::ControlStateMachine, ::Val{:Playing}, ::Val{:KINETIC_TIME_NOT_MET}, _) = Hsm.transition!(sm, :Error)
Hsm.on_event!(sm::ControlStateMachine, ::Val{:Playing}, ::Val{:ERROR_ACK}, _) = Hsm.transition!(sm, :Error)
Hsm.on_event!(sm::ControlStateMachine, ::Val{:Playing}, ::Val{:ACQ_BUFFER}, _) = Hsm.transition!(sm, :Error)
Hsm.on_event!(sm::ControlStateMachine, ::Val{:Playing}, ::Val{:ACQ_DOWNFIFO_FULL}, _) = Hsm.transition!(sm, :Error)
Hsm.on_event!(sm::ControlStateMachine, ::Val{:Playing}, ::Val{:SPOOL_ERROR}, _) = Hsm.transition!(sm, :Error)

########################

function Hsm.on_event!(sm::ControlStateMachine, ::Val{:Paused}, ::Val{:ACQUIRING}, _)
    # Just consume the image
    AndorSDK2.most_recent_image(sm.frame_buffer)
    return Hsm.EventHandled
end

Hsm.on_event!(sm::ControlStateMachine, ::Val{:Paused}, ::Val{:Play}, _) = Hsm.transition!(sm, :Playing)

########################

function Hsm.on_entry!(sm::ControlStateMachine, ::Val{:Exit})
    @info "Exiting..."
    # Signal the AgentRunner to stop
    throw(AgentTerminationException())
end

########################

function Hsm.on_entry!(sm::ControlStateMachine, ::Val{:Error})
    @info "Error"
end

