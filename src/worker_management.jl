# Type containing information on workers.
struct WorkerInf
    inputs::Dict{Int,RemoteChannel{Channel{Message}}}
    output::RemoteChannel{Channel{Message}}
    wait::Vector{Message}
    results::Dict{Int,Future}
end

function WorkerInf(inputs::Dict{Int,RemoteChannel{Channel{Message}}},
                   output::RemoteChannel{Channel{Message}},
                   results::Dict{Int,Future}
                   ) where T
    return WorkerInf(inputs,
                     output,
                     Vector{Message}(),
                     results)
end

function _abort(wi::WorkerInf)::Nothing
    for (wid, rc) in pairs(wi.inputs)
        put!(rc, Abort())
    end
    while isready(wi.output)
        # Ensure that workers aren't blocked
        take!(wi.output)
    end
    return
end

function _check_wait(wi::WorkerInf,
                     msg_type::Type{M}
                     )::Union{Nothing,M} where M <: Message

    retval = nothing

    for (k,msg) in enumerate(wi.wait)
        if typeof(msg) <: msg_type
            retval = msg
            deleteat!(wi.wait, k)
            break
        end
    end

    return retval
end

function _is_running(wi::WorkerInf)
    return length(wi.results) > 0
end

function _launch_workers(min_worker_size::Int,
                         min_result_size::Int,
                         )::WorkerInf

    worker_q_size = min_worker_size
    result_q_size = max(2*nworkers(), min_result_size)

    worker_results = RemoteChannel(()->Channel{Message}(result_q_size))
    worker_qs = Dict{Int,RemoteChannel{Channel{Message}}}()
    futures = Dict{Int,Future}()
    @sync for wid in workers()
        @async begin
            worker_q = RemoteChannel(()->Channel{Message}(worker_q_size), wid)
            futures[wid] = remotecall(worker_loop, wid, wid, worker_q, worker_results)
            worker_qs[wid] = worker_q
        end
    end

    wi = WorkerInf(worker_qs, worker_results, futures)
    _monitor_workers(wi)

    return wi
end

function _monitor_workers(wi::WorkerInf)::Nothing
    # println("Checking worker status...")
    for (pid, f) in pairs(wi.results)
        if isready(f)
            # Whatever the return value, this worker is done and
            # we can stop checking on it
            delete!(wi.results, pid)
            delete!(wi.inputs, pid)
            try
                # Fetch on a remote process result will throw and error here
                # whereas fetch on a task requires that it is thrown. Hence
                # the try-catch AND the type check for an exception.
                e = fetch(f)
                if typeof(e) <: Int
                    # Normal Exit -- do nothing
                elseif typeof(e) <: Exception
                    throw(e)
                else
                    error("Unexpected return code from worker: $e")
                end
            catch e
                _abort(wi)
                rethrow()
            finally
                ;
            end
        end
    end
    return
end

function _number_workers(wi::WorkerInf)
    return length(wi.results)
end

function _retrieve_message(wi::WorkerInf)::Message

    while !isready(wi.output) && _is_running(wi)
        _monitor_workers(wi)
        yield()
    end

    msg = take!(wi.output)
    
    return msg
end

function _retrieve_message_type(wi::WorkerInf,
                                msg_type::Type{M}
                                )::M where M <: Message

    # Check if we have this type of message in the wait queue
    msg = _check_wait(wi, msg_type)

    while isnothing(msg)

        # Check get messages from the remote channel
        msg = _retrieve_message(wi)

        # If it's wrong put it on the wait queue for later and keep looking
        if !(typeof(msg) <: msg_type)
            push!(wi.wait, msg)
            msg = nothing
        end

    end

    return msg

end

function _send_message(wi::WorkerInf,
                       wid::Int,
                       msg::Message,
                       )
    put!(wi.inputs[wid], msg)
    return
end

function _shutdown(wi::WorkerInf)
    @sync for rchan in values(wi.inputs)
        @async put!(rchan, ShutDown())
    end
    return
end

function _wait_for_shutdown(wi::WorkerInf)::Nothing
    while _is_running(wi)
        _monitor_workers(wi)
        yield()
    end
    return
end
