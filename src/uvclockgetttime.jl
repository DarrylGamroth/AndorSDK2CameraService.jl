using LibUV_jll

struct uv_timespec
    tv_sec::Int64
    tv_nsec::Int32
end

@enumx uv_clock_id::Int32 begin
    MONOTONIC
    REALTIME
end

function clock_gettime(clockid::uv_clock_id.T)
    ts = Ref{uv_timespec}()
    err = @ccall uv_clock_gettime(Cint(clockid)::Cint, ts::Ref{uv_timespec})::Cint
    err != 0 && error(unsafe_string(@ccall uv_strerror(err::Cint)::Ptr{Cchar}))
    return ts[].tv_sec * 1_000_000_000 + ts[].tv_nsec
end

# For linux there are more clock optons like reading the PTP clock. See man clock_gettime

