abstract type NeuralDELayer <: Function end
basic_tgrad(u,p,t) = zero(u)

struct NeuralODE{P,RE,T,S,M,A,K} <: NeuralDELayer
    p::P
    re::RE
    tspan::T
    solver::S
    model::M
    args::A
    kwargs::K
end

"""
    Constructs a continuous-time recurrant neural network, also known as a neural
    ordinary differential equation (neural ODE), with a fast gradient calculation
    via adjoints [1]. At a high level this corresponds to solving the forward
    differential equation, using a second differential equation that propagates the
    derivatives of the loss backwards in time.

```julia
NeuralODE(model::Chain,tspan,alg=nothing,args...;kwargs...)
NeuralODE(model::FastChain,tspan,alg=nothing,args...;
          sensealg=InterpolatingAdjoint(autojacvec=DiffEqSensitivity.ReverseDiffVJP(true)),
          kwargs...)
```

Arguments:

- `model`: A Chain or FastChain neural network that defines the ̇x.
- `tspan`: The timespan to be solved on.
- `alg`: The algorithm used to solve the ODE. Defaults to `nothing`, i.e. the
  default algorithm from DifferentialEquations.jl.
- `sensealg`: The choice of differentiation algorthm used in the backpropogation.
  Defaults to an adjoint method, and with `FastChain` it defaults to utilizing
  a tape-compiled ReverseDiff vector-Jacobian product for extra efficiency. Seee
  the [Local Sensitivity Analysis](https://docs.sciml.ai/dev/analysis/sensitivity/)
  documentation for more details.
- `kwargs`: Additional arguments splatted to the ODE solver. See the
  [Common Solver Arguments](https://docs.sciml.ai/dev/basics/common_solver_opts/)
  documentation for more details.

Ref
[1]L. S. Pontryagin, Mathematical Theory of Optimal Processes. CRC Press, 1987.
"""
function NeuralODE(model::Chain,tspan,solver=nothing,args...;kwargs...)
    p,re = Flux.destructure(model)
    NeuralODE(p,re,tspan,solver,model,args,kwargs)
end
function NeuralODE(model::FastChain,tspan,solver=nothing,args...;kwargs...)
    p = initial_params(model)
    re = nothing
    NeuralODE(p,re,tspan,solver,model,args,kwargs)
end

Flux.@functor NeuralODE

function (n::NeuralODE{P,RE,T,S,M,A,K})(x,p=n.p) where {P,RE,T,S,M<:Chain,A,K}
    dudt_(u,p,t) = n.re(p)(u)
    ff = ODEFunction{false}(dudt_,tgrad=basic_tgrad)
    prob = ODEProblem{false}(ff,x,n.tspan,p)
    concrete_solve(prob,n.solver,x,p,n.args...;n.kwargs...)
end

function (n::NeuralODE{P,RE,T,S,M,A,K})(x,p=n.p) where {P,RE,T,S,M<:FastChain,A,K}
    fastdudt_(u,p,t) = n.model(u,p)
    ff = ODEFunction{false}(fastdudt_,tgrad=basic_tgrad)
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
end

"""
    Constructs a neural stochastic differential equation (neural SDE) with diagonal noise.

```julia
NeuralDSDE(model1,model2,tspan,alg=nothing,args...;
           sensealg=TrackerAdjoint(),kwargs...)
NeuralDSDE(model1::FastChain,model2::FastChain,tspan,alg=nothing,args...;
           sensealg=TrackerAdjoint(),kwargs...)
```

Arguments:

- `model1`: A Chain or FastChain neural network that defines the drift function.
- `model2`: A Chain or FastChain neural network that defines the diffusion function.
  Should output a vector of the same size as the input.
- `tspan`: The timespan to be solved on.
- `alg`: The algorithm used to solve the ODE. Defaults to `nothing`, i.e. the
  default algorithm from DifferentialEquations.jl.
- `sensealg`: The choice of differentiation algorthm used in the backpropogation.
  Defaults to using reverse-mode automatic differentiation via Tracker.jl
- `kwargs`: Additional arguments splatted to the ODE solver. See the
  [Common Solver Arguments](https://docs.sciml.ai/dev/basics/common_solver_opts/)
  documentation for more details.

"""
function NeuralDSDE(model1::Chain,model2::Chain,tspan,solver=nothing,args...;kwargs...)
    p1,re1 = Flux.destructure(model1)
    p2,re2 = Flux.destructure(model2)
    p = [p1;p2]
    NeuralDSDE(p,length(p1),model1,re1,model2,re2,tspan,solver,args,kwargs)
end
function NeuralDSDE(model1::FastChain,model2::FastChain,tspan,solver=nothing,args...;kwargs...)
    p1 = initial_params(model1)
    p2 = initial_params(model2)
    re1 = nothing
    re2 = nothing
    p = [p1;p2]
    NeuralDSDE(p,length(p1),model1,re1,model2,re2,tspan,solver,args,kwargs)
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
end

"""
    Constructs a neural stochastic differential equation (neural SDE).

```julia
NeuralSDE(model1,model2,tspan,nbrown,alg=nothing,args...;
          sensealg=TrackerAdjoint(),kwargs...)
NeuralSDE(model1::FastChain,model2::FastChain,tspan,nbrown,alg=nothing,args...;
          sensealg=TrackerAdjoint(),kwargs...)
```

Arguments:

- `model1`: A Chain or FastChain neural network that defines the drift function.
- `model2`: A Chain or FastChain neural network that defines the diffusion function.
  Should output a matrix that is nbrown x size(x,1).
- `tspan`: The timespan to be solved on.
- `nbrown`: The number of Brownian processes
- `alg`: The algorithm used to solve the ODE. Defaults to `nothing`, i.e. the
  default algorithm from DifferentialEquations.jl.
- `sensealg`: The choice of differentiation algorthm used in the backpropogation.
  Defaults to using reverse-mode automatic differentiation via Tracker.jl
- `kwargs`: Additional arguments splatted to the ODE solver. See the
  [Common Solver Arguments](https://docs.sciml.ai/dev/basics/common_solver_opts/)
  documentation for more details.

"""
function NeuralSDE(model1::Chain,model2::Chain,tspan,nbrown,solver=nothing,args...;kwargs...)
    p1,re1 = Flux.destructure(model1)
    p2,re2 = Flux.destructure(model2)
    p = [p1;p2]
    NeuralSDE(p,length(p1),model1,re1,model2,re2,tspan,nbrown,solver,args,kwargs)
end
function NeuralSDE(model1::FastChain,model2::FastChain,tspan,nbrown,solver=nothing,args...;kwargs...)
    p1 = initial_params(model1)
    p2 = initial_params(model2)
    re1 = nothing
    re2 = nothing
    p = [p1;p2]
    NeuralSDE(p,length(p1),model1,re1,model2,re2,tspan,nbrown,solver,args,kwargs)
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

"""
    Constructs a neural delay differential equation (neural DDE) with constant
    delays.

```julia
NeuralCDDE(model,tspan,hist,lags,alg=nothing,args...;
          sensealg=TrackerAdjoint(),kwargs...)
NeuralCDDE(model::FastChain,tspan,hist,lags,alg=nothing,args...;
          sensealg=TrackerAdjoint(),kwargs...)
```

Arguments:

- `model`: A Chain or FastChain neural network that defines the derivative function.
  Should take an input of size `[x;x(t-lag_1);...;x(t-lag_n)]` and produce and
  output shaped like `x`.
- `tspan`: The timespan to be solved on.
- `hist`: Defines the history function `h(t)` for values before the start of the
  integration.
- `lags`: Defines the lagged values that should be utilized in the neural network.
- `alg`: The algorithm used to solve the ODE. Defaults to `nothing`, i.e. the
  default algorithm from DifferentialEquations.jl.
- `sensealg`: The choice of differentiation algorthm used in the backpropogation.
  Defaults to using reverse-mode automatic differentiation via Tracker.jl
- `kwargs`: Additional arguments splatted to the ODE solver. See the
  [Common Solver Arguments](https://docs.sciml.ai/dev/basics/common_solver_opts/)
  documentation for more details.

"""
function NeuralCDDE(model::Chain,tspan,hist,lags,solver=nothing,args...;kwargs...)
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
end

"""
    Constructs a neural differential-algebraic equation (neural DAE).

```julia
NeuralDAE(model,constraints_model,tspan,alg=nothing,args...;
          sensealg=TrackerAdjoint(),kwargs...)
NeuralDAE(model::FastChain,constraints_model,tspan,alg=nothing,args...;
          sensealg=TrackerAdjoint(),kwargs...)
```

Arguments:

- `model`: A Chain or FastChain neural network that defines the derivative function.
  Should take an input of size `x` and produce the residual of `f(dx,x,t)`
  for only the differential variables.
- `constraints_model`: A function `constraints_model(u,p,t)` for the fixed
  constaints to impose on the algebraic equations.
- `tspan`: The timespan to be solved on.
- `alg`: The algorithm used to solve the ODE. Defaults to `nothing`, i.e. the
  default algorithm from DifferentialEquations.jl.
- `sensealg`: The choice of differentiation algorthm used in the backpropogation.
  Defaults to using reverse-mode automatic differentiation via Tracker.jl
- `kwargs`: Additional arguments splatted to the ODE solver. See the
  [Common Solver Arguments](https://docs.sciml.ai/dev/basics/common_solver_opts/)
  documentation for more details.

"""
function NeuralDAE(model::Chain,constraints_model,tspan,solver=nothing,du0=nothing,args...;differential_vars=nothing,kwargs...)
    p,re = Flux.destructure(model)
    NeuralDAE(model,constraints_model,p,du0,re,tspan,solver,differential_vars,args,kwargs)
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
end

"""
    Constructs a physically-constrained continuous-time recurrant neural network,
    also known as a neural differential-algebraic equation (neural DAE), with a
    mass matrix and a fast gradient calculation via adjoints [1]. The mass matrix
    formulation is:

```math
Mu' = f(u,p,t)
```

where `M` is semi-explicit, i.e. singular with zeros for rows corresponding to
the constraint equations.

```julia
NeuralODEMM(model,constraints_model,tspan,alg=nothing,args...;kwargs...)
NeuralODEMM(model::FastChain,tspan,alg=nothing,args...;
          sensealg=InterpolatingAdjoint(autojacvec=DiffEqSensitivity.ReverseDiffVJP(true)),
          kwargs...)
```

Arguments:

- `model`: A Chain or FastChain neural network that defines the ̇`f(u,p,t)`
- `constraints_model`: A function `constraints_model(u,p,t)` for the fixed
  constaints to impose on the algebraic equations.
- `tspan`: The timespan to be solved on.
- `alg`: The algorithm used to solve the ODE. Defaults to `nothing`, i.e. the
  default algorithm from DifferentialEquations.jl. This method requires an
  implicit ODE solver compatible with singular mass matrices. Consult the
  [DAE solvers](https://docs.sciml.ai/latest/solvers/dae_solve/) documentation for more details.
- `sensealg`: The choice of differentiation algorthm used in the backpropogation.
  Defaults to an adjoint method, and with `FastChain` it defaults to utilizing
  a tape-compiled ReverseDiff vector-Jacobian product for extra efficiency. Seee
  the [Local Sensitivity Analysis](https://docs.sciml.ai/dev/analysis/sensitivity/)
  documentation for more details.
- `kwargs`: Additional arguments splatted to the ODE solver. See the
  [Common Solver Arguments](https://docs.sciml.ai/dev/basics/common_solver_opts/)
  documentation for more details.

"""
function NeuralODEMM(model::Chain,constraints_model,tspan,mass_matrix,solver=nothing,args...;kwargs...)
    p,re = Flux.destructure(model)
    NeuralODEMM(model,constraints_model,p,re,tspan,solver,mass_matrix,args,kwargs)
end
function NeuralODEMM(model::FastChain,constraints_model,tspan,mass_matrix,solver=nothing,args...;kwargs...)
    p = initial_params(model)
    re = nothing
    NeuralODEMM(model,constraints_model,p,re,tspan,solver,mass_matrix,args,kwargs)
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
