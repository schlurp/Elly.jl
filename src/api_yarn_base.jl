@doc doc"""
YarnClientProtocol: Hadoop RPC client for application client to Yarn resource manager protocol.
""" ->
typealias YarnClientProtocol HadoopRpcProtocol{ApplicationClientProtocolServiceBlockingStub}

for fn in (:getClusterMetrics, :getClusterNodes, :getNewApplication, :submitApplication, :forceKillApplication, :getApplicationReport, :getApplicationAttempts)
    @eval begin
       (hadoop.yarn.$fn)(p::YarnClientProtocol, inp) = (hadoop.yarn.$fn)(p.stub, p.controller, inp)
    end
end

@doc doc"""
YarnAMRMProtocol: Hadoop RPC client for Yarn application master to resource manager protocol.
""" ->
typealias YarnAMRMProtocol HadoopRpcProtocol{ApplicationMasterProtocolServiceBlockingStub}

for fn in (:registerApplicationMaster, :finishApplicationMaster, :allocate)
    @eval begin
        (hadoop.yarn.$fn)(p::YarnAMRMProtocol, inp) = (hadoop.yarn.$fn)(p.stub, p.controller, inp)
    end
end

@doc doc"""
YarnAMNMProtocol: Hadoop RPC client for Yarn application master to node manager protocol.
""" ->
typealias YarnAMNMProtocol HadoopRpcProtocol{ContainerManagementProtocolServiceBlockingStub}

for fn in (:startContainers, :stopContainers, :getContainerStatuses)
    @eval begin
        (hadoop.yarn.$fn)(p::YarnAMNMProtocol, inp) = (hadoop.yarn.$fn)(p.stub, p.controller, inp)
    end
end 



@doc doc"""
# YarnException
Thrown by Yarn APIs.
""" ->
type YarnException <: Exception
    message::AbstractString
end

function show(io::IO, serex::SerializedExceptionProto)
    print(io, "Exception: ")
    isfilled(serex, :class_name) && print(io, serex.class_name, ": ")
    isfilled(serex, :message) && print(io, serex.message)
    isfilled(serex, :trace) && print(io, '\n', serex.trace, '\n')

    if isfilled(serex, :cause)
        println(io, "Caused by:")
        show(io, serex.cause)
    end
    nothing
end

function YarnException(cex::ContainerExceptionMapProto)
    cont_id = cex.ccontainer_id
    app_id = cont_id.app_id
    atmpt_id = cont_id.app_attempt_id
    iob = IOBuffer()
    println(iob, "Error in container $(cont_id.id) of app $(app_id.id) attempt $(atmpt_id.attemptId):")
    show(iob, cex.exception)
    YarnException(takebuf_string(iob))
end



@doc doc"""
YarnNode represents a node manager in the yarn cluster and its
communication address, resource state and run state.
""" ->
type YarnNode
    host::AbstractString
    port::Int32
    rack::AbstractString
    ncontainers::Int32
    mem::Int32
    cores::Int32
    memused::Int32
    coresused::Int32
    state::Int32
    isrunning::Bool
    report::NodeReportProto

    function YarnNode(node::NodeReportProto)
        host = node.nodeId.host
        port = node.nodeId.port
        rack = node.rackName
        ncontainers = node.numContainers

        state = node.node_state
        isrunning = (state == NodeStateProto.NS_RUNNING)

        if isrunning
            mem = node.capability.memory
            cores = node.capability.virtual_cores

            memused = node.used.memory
            coresused = node.used.virtual_cores
        else
            mem = cores = memused = coresused = 0
        end

        new(host, port, rack, ncontainers, mem, cores, memused, coresused, state, isrunning, node)
    end
end

@doc doc"""
NODE_STATES: enum value to state map. Used for converting state for display.
""" ->
const NODE_STATES = [:new, :running, :unhealthy, :decommissioned, :lost, :rebooted]

function show(io::IO, node::YarnNode)
    print(io, "YarnNode: $(node.rack)/$(node.host):$(node.port) $(NODE_STATES[node.state])")
    println(io, node.isrunning ? ", Used mem: $(node.memused)/$(node.mem), cores: $(node.coresused)/$(node.cores)" : "")
    nothing
end



@doc doc"""
YarnNodes holds node information as visible to the application master.
It also caches connection to node masters. Connection are reused if they are required before a set keepalivesecs time.
""" ->
type YarnNodes
    count::Int32
    status::Dict{NodeIdProto,YarnNode}
    conn::Dict{NodeIdProto,Tuple}
    ugi::UserGroupInformation
    keepalivesecs::UInt64

    function YarnNodes(ugi::UserGroupInformation)
        new(0, Dict{NodeIdProto,YarnNode}(), Dict{NodeIdProto,Tuple}(), ugi, YARN_NM_CONN_KEEPALIVE_SECS)
    end
end

function show(io::IO, nodes::YarnNodes)
    println(io, "YarnNodes: $(nodes.count) (connected to $(length(nodes.conn)))")
    for n in values(nodes.status)
        show(io, n)
    end
    nothing
end

function update(nodes::YarnNodes, arp::AllocateResponseProto)
    isfilled(arp, :num_cluster_nodes) && (nodes.count = arp.num_cluster_nodes)
    if isfilled(arp, :updated_nodes)
        for nrep in arp.updated_nodes
            nodes.status[nrep.nodeId] = YarnNode(nrep)
        end
    end
    nothing
end

function update(nodes::YarnNodes, gcnrp::GetClusterNodesResponseProto)
    isfilled(gcnrp, :nodeReports) || return

    nlist = gcnrp.nodeReports
    nodes.count = length(nlist)
    for nrep in nlist
        nodes.status[nrep.nodeId] = YarnNode(nrep)
    end 
    nothing
end

function get_connection(nodes::YarnNodes, nodeid::NodeIdProto)
    (nodeid in keys(nodes.status)) || throw(YarnException("Unknown Yarn node: $(nodeid.host):$(nodeid.port)"))
    node = nodes.status[nodeid]
    node.isrunning || throw(YarnException("Yarn node $(nodeid.host):$(nodeid.port) is not running"))

    t = time()
    if nodeid in nodes.conn
        (conn,lastusetime) = nodes.conn[nodeid]
        (t < (lastusetime + nodes.keepalivesecs)) && (return conn)
        try
            disconnect(conn.channel)
        finally
            delete!(nodes.conn, nodeid)
        end
    end
        
    conn = YarnAMNMProtocol(nodeid.host, nodeid.port, nodes.ugi)
    nodes.conn[nodeid] = (conn, t)
    conn
end

function release_connection(nodes::YarnNodes, nodeid::NodeIdProto, conn::YarnAMNMProtocol, reuse::Bool)
    if reuse
        nodes.conn[nodeid] = (conn, time())
    else
        try
            disconnect(conn.channel)
        finally
            delete!(nodes.conn, nodeid)
        end
    end
    nothing
end


@doc doc"""
RequestPipeline holds entities while they are requested for from yarn resource manager.
Application master thread extracts pending items and requests them from RM, whereupon they are moved on to the requested state.
""" ->
type RequestPipeline{T}
    pending::Vector{T}
    requested::Vector{T}

    function RequestPipeline()
        new(T[], T[])
    end
end

pending{T}(pipe::RequestPipeline{T}, item::T) = push!(pipe.pending, item)
function torequest{T}(pipe::RequestPipeline{T})
    ret = pipe.pending
    if !isempty(ret)
        append!(pipe.requested, ret)
        pipe.pending = T[]
    end
    ret
end
haverequests(pipe::RequestPipeline) = !isempty(pipe.pending)


@doc doc"""
YarnContainers holds all containers related to the application.
It also holds the allocation and release pipelines that are used by application master for requesting actions from resource manager.
Also schedules callbacks as tasks when containers are allocated or terminated.
""" ->
type YarnContainers
    containers::Dict{ContainerIdProto,ContainerProto}
    status::Dict{ContainerIdProto,ContainerStatusProto}
    active::Set{ContainerIdProto}
    busy::Set{ContainerIdProto}

    alloc_pipeline::RequestPipeline{ResourceRequestProto}
    release_pipeline::RequestPipeline{ContainerIdProto}
    ndesired::Int

    on_container_alloc::Nullable{Function}
    on_container_finish::Nullable{Function}

    function YarnContainers()
        new(Dict{ContainerIdProto,ContainerProto}(), Dict{ContainerIdProto,ContainerStatusProto}(), Set{ContainerIdProto}(), Set{ContainerIdProto}(),
            RequestPipeline{ResourceRequestProto}(), RequestPipeline{ContainerIdProto}(), 0,
            Nullable{Function}(), Nullable{Function}())
    end
end

function show(io::IO, containers::YarnContainers)
    println(io, "Containers: $(length(containers.active))/$(length(containers.containers)) active, $(length(containers.busy)) in use")
    nothing
end

function callback(containers::YarnContainers, on_container_alloc::Nullable{Function}, on_container_finish::Nullable{Function})
    containers.on_container_alloc = on_container_alloc
    containers.on_container_finish = on_container_finish
    nothing
end

function update(containers::YarnContainers, arp::AllocateResponseProto)
    active = containers.active
    busy = containers.busy
    status = containers.status
    contlist = containers.containers
    cballoc = containers.on_container_alloc
    cbfinish = containers.on_container_finish

    if isfilled(arp, :allocated_containers)
        for cont in arp.allocated_containers
            id = cont.id
            contlist[id] = cont
            push!(active, id)
            #logmsg("calling callback for alloc")
            isnull(cballoc) || @async(get(cballoc)(id))
            #isnull(cballoc) || get(cballoc)(id)
        end
    end
    if isfilled(arp, :completed_container_statuses)
        #logmsg("have completed containers")
        for contst in arp.completed_container_statuses
            id = contst.container_id
            #logmsg("container $id is finished")
            status[id] = contst
            #logmsg("id in active: $(id in active)")
            (id in active) && pop!(active, id)
            (id in busy) && pop!(busy, id)
            #logmsg("calling callback for finish")
            isnull(cbfinish) || @async(get(cbfinish)(id))
            #isnull(cbfinish) || get(cbfinish)(id)
        end
    end
    nothing
end

function request_alloc(containers::YarnContainers, numcontainers::Int; 
                    mem::Integer=YARN_CONTAINER_MEM_DEFAULT, cpu::Integer=YARN_CONTAINER_CPU_DEFAULT, 
                    loc::AbstractString=YARN_CONTAINER_LOCATION_DEFAULT, priority::Integer=YARN_CONTAINER_PRIORITY_DEFAULT)
    prio = protobuild(PriorityProto, @compat Dict(:priority => priority))
    capability = protobuild(ResourceProto, @compat Dict(:memory => mem, :virtual_cores => cpu))
    req = protobuild(ResourceRequestProto, @compat Dict(:priority => prio,
            :resource_name => loc,
            :num_containers => numcontainers,
            :capability => capability))
    pending(containers.alloc_pipeline, req)
    containers.ndesired += numcontainers
    nothing
end

function request_release(containers::YarnContainers, cids::ContainerIdProto...)
    for cid in cids
        pending(containers.release_pipeline, cid)
    end
    containers.ndesired -= length(cids)
    nothing
end

function set_busy(containers::YarnContainers, cids::ContainerIdProto...)
    busy = containers.busy
    for cid in cids
        push!(busy, cid)
    end
    nothing
end

function set_free(containers::YarnContainers, cids::ContainerIdProto...)
    busy = containers.busy
    for cid in cids
        pop!(busy, cid)
    end
    nothing
end

torequest(containers::YarnContainers) = (torequest(containers.alloc_pipeline), torequest(containers.release_pipeline))
haverequests(containers::YarnContainers) = containers.ndesired != length(containers.active)


# TODO: support local resources
# TODO: support tokens
function launchcontext(;cmd::AbstractString="", env::Dict=Dict(), service_data::Dict=Dict())
    clc = ContainerLaunchContextProto()
    if !isempty(cmd)
        set_field!(clc, :command, AbstractString[cmd])
    end
    if !isempty(env)
        envproto = StringStringMapProto[]
        for (n,v) in env
            (isa(n, AbstractString) && isa(v, AbstractString)) || throw(ArgumentError("non string environment variable specified: $(typeof(n)) => $(typeof(v))"))
            push!(envproto, protobuild(StringStringMapProto, @compat Dict(:key => n, :value => v)))
        end
        set_field!(clc, :environment, envproto)
    end
    if !isempty(service_data)
        svcdataproto = StringBytesMapProto[]
        for (n,v) in service_data
            (isa(n, AbstractString) && isa(v, Vector{UInt8})) || throw(ArgumentError("incompatible service data type specified: $(typeof(n)) => $(typeof(v))"))
            push!(svcdataproto, protobuild(StringBytesMapProto, @compat Dict(:key => n, :value => v)))
        end
        set_field!(clc, :service_data, servicedataproto)
    end
    clc
end
