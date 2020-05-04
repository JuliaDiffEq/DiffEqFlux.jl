abstract type NeuralDELayer <: Function end
basic_tgrad(u,p,t) = zero(u)

"""
Constructs a neural ODE with the gradients computed using the adjoint
method[1]. At a high level this corresponds to solving the forward
differential equation, using a second differential equation that propagates
the derivatives of the loss  backwards in time.
This first solves the continuous time problem, and then discretizes following
the rules specified by the numerical ODE solver.
On the other hand, the 'neural_ode_rd' first disretizes the solution and then
computes the adjoint using automatic differentiation.

Ref
[1]L. S. Pontryagin, Mathematical Theory of Optimal Processes. CRC Press, 1987.

Arguments
≡≡≡≡≡≡≡≡
model::Chain defines the ̇x
x<:AbstractArray initial value x(t₀)
args arguments passed to ODESolve
kwargs key word arguments passed to ODESolve; accepts an additional key
    :callback_adj in addition to :callback. The Callback :callback_adj
    passes a separate callback to the adjoint solver.

"""
struct NeuralODE{M,P,RE,T,S,A,K} <: NeuralDELayer
    model::M
    p::P
    re::RE
    tspan::T
    solver::S
    args::A
    kwargs::K

    function NeuralODE(model,tspan,solver=nothing,args...;kwargs...)
        p,re = Flux.destructure(model)
        new{typeof(model),typeof(p),typeof(re),
            typeof(tspan),typeof(solver),typeof(args),typeof(kwargs)}(
            model,p,re,tspan,solver,args,kwargs)
    end

    function NeuralODE(model::FastChain,tspan,solver=nothing,args...;kwargs...)
        p = initial_params(model)
        re = nothing
        new{typeof(model),typeof(p),typeof(re),
            typeof(tspan),typeof(solver),typeof(args),typeof(kwargs)}(
            model,p,re,tspan,solver,args,kwargs)
    end
end

Flux.@functor NeuralODE

function (n::NeuralODE)(x,p=n.p)
    dudt_(u,p,t) = n.re(p)(u)
    ff = ODEFunction{false}(dudt_,tgrad=basic_tgrad)
    prob = ODEProblem{false}(ff,x,n.tspan,p)
    concrete_solve(prob,n.solver,x,p,n.args...;n.kwargs...)
end

function (n::NeuralODE{M})(x,p=n.p) where {M<:FastChain}
    dudt_(u,p,t) = n.model(u,p)
    ff = ODEFunction{false}(dudt_,tgrad=basic_tgrad)
    prob = ODEProblem{false}(ff,x,n.tspan,p)
    concrete_solve(prob,n.solver,x,p,n.args...;
                                sensealg=InterpolatingAdjoint(
                                autojacvec=DiffEqSensitivity.ReverseDiffVJP(true)),
                                n.kwargs...)
end

struct NeuralDSDE{M,P,RE,M2,RE2,T,S,A,K} <: NeuralDELayer
    p::P
    len::Int
    model1::M
    re1::RE
    model2::M2
    re2::RE2
    tspan::T
    solver::S
    args::A
    kwargs::K
    function NeuralDSDE(model1,model2,tspan,solver=nothing,args...;kwargs...)
        p1,re1 = Flux.destructure(model1)
        p2,re2 = Flux.destructure(model2)
        p = [p1;p2]
        new{typeof(model1),typeof(p),typeof(re1),typeof(model2),typeof(re2),
            typeof(tspan),typeof(solver),typeof(args),typeof(kwargs)}(p,
            length(p1),model1,re1,model2,re2,tspan,solver,args,kwargs)
    end

    function NeuralDSDE(model1::FastChain,model2::FastChain,tspan,solver=nothing,args...;kwargs...)
        p1 = initial_params(model1)
        p2 = initial_params(model2)
        re1 = nothing
        re2 = nothing
        p = [p1;p2]
        new{typeof(model1),typeof(p),typeof(re1),typeof(model2),typeof(re2),
            typeof(tspan),typeof(solver),typeof(args),typeof(kwargs)}(p,
            length(p1),model1,re1,model2,re2,tspan,solver,args,kwargs)
    end
end

Flux.@functor NeuralDSDE

function (n::NeuralDSDE)(x,p=n.p)
    dudt_(u,p,t) = n.re1(p[1:n.len])(u)
    g(u,p,t) = n.re2(p[(n.len+1):end])(u)
    ff = SDEFunction{false}(dudt_,g,tgrad=basic_tgrad)
    prob = SDEProblem{false}(ff,g,x,n.tspan,p)
    concrete_solve(prob,n.solver,x,p,n.args...;sensealg=TrackerAdjoint(),n.kwargs...)
end

function (n::NeuralDSDE{M})(x,p=n.p) where {M<:FastChain}
    dudt_(u,p,t) = n.model1(u,p[1:n.len])
    g(u,p,t) = n.model2(u,p[(n.len+1):end])
    ff = SDEFunction{false}(dudt_,g,tgrad=basic_tgrad)
    prob = SDEProblem{false}(ff,g,x,n.tspan,p)
    concrete_solve(prob,n.solver,x,p,n.args...;sensealg=TrackerAdjoint(),n.kwargs...)
end

struct NeuralSDE{P,M,RE,M2,RE2,T,S,A,K} <: NeuralDELayer
    p::P
    len::Int
    model1::M
    re1::RE
    model2::M2
    re2::RE2
    tspan::T
    nbrown::Int
    solver::S
    args::A
    kwargs::K
    function NeuralSDE(model1,model2,tspan,nbrown,solver=nothing,args...;kwargs...)
        p1,re1 = Flux.destructure(model1)
        p2,re2 = Flux.destructure(model2)
        p = [p1;p2]
        new{typeof(p),typeof(model1),typeof(re1),typeof(model2),typeof(re2),
            typeof(tspan),typeof(solver),typeof(args),typeof(kwargs)}(
            p,length(p1),model1,re1,model2,re2,tspan,nbrown,solver,args,kwargs)
    end

    function NeuralSDE(model1::FastChain,model2::FastChain,tspan,nbrown,solver=nothing,args...;kwargs...)
        p1 = initial_params(model1)
        p2 = initial_params(model2)
        re1 = nothing
        re2 = nothing
        p = [p1;p2]
        new{typeof(p),typeof(model1),typeof(re1),typeof(model2),typeof(re2),
            typeof(tspan),typeof(solver),typeof(args),typeof(kwargs)}(
            p,length(p1),model1,re1,model2,re2,tspan,nbrown,solver,args,kwargs)
    end
end


Flux.@functor NeuralSDE

function (n::NeuralSDE)(x,p=n.p)
    dudt_(u,p,t) = n.re1(p[1:n.len])(u)
    g(u,p,t) = n.re2(p[(n.len+1):end])(u)
    ff = SDEFunction{false}(dudt_,g,tgrad=basic_tgrad)
    prob = SDEProblem{false}(ff,g,x,n.tspan,p,noise_rate_prototype=zeros(Float32,length(x),n.nbrown))
    concrete_solve(prob,n.solver,x,p,n.args...;sensealg=TrackerAdjoint(),n.kwargs...)
end

function (n::NeuralSDE{P,M})(x,p=n.p) where {P,M<:FastChain}
    dudt_(u,p,t) = n.model1(u,p[1:n.len])
    g(u,p,t) = n.model2(u,p[(n.len+1):end])
    ff = SDEFunction{false}(dudt_,g,tgrad=basic_tgrad)
    prob = SDEProblem{false}(ff,g,x,n.tspan,p,noise_rate_prototype=zeros(Float32,length(x),n.nbrown))
    concrete_solve(prob,n.solver,x,p,n.args...;sensealg=TrackerAdjoint(),n.kwargs...)
end

struct NeuralCDDE{P,M,RE,H,L,T,S,A,K} <: NeuralDELayer
    p::P
    model::M
    re::RE
    hist::H
    lags::L
    tspan::T
    solver::S
    args::A
    kwargs::K
end

function NeuralCDDE(model,tspan,hist,lags,solver=nothing,args...;kwargs...)
    p,re = Flux.destructure(model)
    NeuralCDDE(p,model,re,hist,lags,tspan,solver,args,kwargs)
end

function NeuralCDDE(model::FastChain,tspan,hist,lags,solver=nothing,args...;kwargs...)
    p = initial_params(model)
    re = nothing
    NeuralCDDE(p,model,re,hist,lags,tspan,solver,args,kwargs)
end

Flux.@functor NeuralCDDE

function (n::NeuralCDDE)(x,p=n.p)
    function dudt_(u,h,p,t)
        _u = vcat(u,(h(p,t-lag) for lag in n.lags)...)
        n.re(p)(_u)
    end
    ff = DDEFunction{false}(dudt_,tgrad=basic_tgrad)
    prob = DDEProblem{false}(ff,x,n.hist,n.tspan,p,constant_lags = n.lags)
    concrete_solve(prob,n.solver,x,p,n.args...;sensealg=TrackerAdjoint(),n.kwargs...)
end

function (n::NeuralCDDE{P,M})(x,p=n.p) where {P,M<:FastChain}
    function dudt_(u,h,p,t)
        _u = vcat(u,(h(p,t-lag) for lag in n.lags)...)
        n.model(_u,p)
    end
    ff = DDEFunction{false}(dudt_,tgrad=basic_tgrad)
    prob = DDEProblem{false}(ff,x,n.hist,n.tspan,p,constant_lags = n.lags)
    concrete_solve(prob,n.solver,x,p,n.args...;sensealg=TrackerAdjoint(),n.kwargs...)
end

struct NeuralDAE{P,M,M2,D,RE,T,S,DV,A,K} <: NeuralDELayer
    model::M
    constraints_model::M2
    p::P
    du0::D
    re::RE
    tspan::T
    solver::S
    differential_vars::DV
    args::A
    kwargs::K

    function NeuralDAE(model,constraints_model,tspan,solver=nothing,du0=nothing,args...;differential_vars=nothing,kwargs...)
        p,re = Flux.destructure(model)
        new{typeof(p),typeof(model),typeof(constraints_model),typeof(du0),typeof(re),
            typeof(tspan),typeof(solver),typeof(differential_vars),typeof(args),typeof(kwargs)}(
            model,constraints_model,p,du0,re,tspan,solver,differential_vars,args,kwargs)
    end
end

Flux.@functor NeuralDAE

function (n::NeuralDAE)(x,du0=n.du0,p=n.p)
    function f(du,u,p,t)
        nn_out = n.re(p)(u)
        alg_out = n.constraints_model(u,p,t)
        v_out = []
        for (j,i) in enumerate(n.differential_vars)
            if i
                push!(v_out,nn_out[j])
            else
                push!(v_out,alg_out[j])
            end
        end
        return v_out
    end
    dudt_(du,u,p,t) = f
    prob = DAEProblem(dudt_,du0,x,n.tspan,p,differential_vars=n.differential_vars)
    concrete_solve(prob,n.solver,x,p,n.args...;sensalg=TrackerAdjoint(),n.kwargs...)
end

struct NeuralODEMM{M,M2,P,RE,T,S,MM,A,K} <: NeuralDELayer
    model::M
    constraints_model::M2
    p::P
    re::RE
    tspan::T
    solver::S
    mass_matrix::MM
    args::A
    kwargs::K

    function NeuralODEMM(model,constraints_model,tspan,mass_matrix,solver=nothing,args...;kwargs...)
        p,re = Flux.destructure(model)
        new{typeof(model),typeof(constraints_model),typeof(p),typeof(re),
            typeof(tspan),typeof(solver),typeof(mass_matrix),typeof(args),typeof(kwargs)}(
            model,constraints_model,p,re,tspan,solver,mass_matrix,args,kwargs)
    end

    function NeuralODEMM(model::FastChain,constraints_model,tspan,mass_matrix,solver=nothing,args...;kwargs...)
        p = initial_params(model)
        re = nothing
        new{typeof(model),typeof(constraints_model),typeof(p),typeof(re),
            typeof(tspan),typeof(solver),typeof(mass_matrix),typeof(args),typeof(kwargs)}(
            model,constraints_model,p,re,tspan,solver,mass_matrix,args,kwargs)
    end
end

Flux.@functor NeuralODEMM

function (n::NeuralODEMM)(x,p=n.p)
    function f(u,p,t)
        nn_out = n.re(p)(u)
        alg_out = n.constraints_model(u,p,t)
        vcat(nn_out,alg_out)
    end
    dudt_= ODEFunction{false}(f,mass_matrix=n.mass_matrix)
    prob = ODEProblem{false}(dudt_,x,n.tspan,p)
    concrete_solve(prob,n.solver,x,p,n.args...;n.kwargs...)
end

function (n::NeuralODEMM{M})(x,p=n.p) where {M<:FastChain}
    function f(u,p,t)
        nn_out = n.model(u,p)
        alg_out = n.constraints_model(u,p,t)
        vcat(nn_out,alg_out)
    end
    dudt_= ODEFunction{false}(f;mass_matrix=n.mass_matrix)
    prob = ODEProblem{false}(dudt_,x,n.tspan,p)
    concrete_solve(prob,n.solver,x,p,n.args...;
                   sensealg=InterpolatingAdjoint(
                            autojacvec=DiffEqSensitivity.ReverseDiffVJP(true)),
                            n.kwargs...)
end
