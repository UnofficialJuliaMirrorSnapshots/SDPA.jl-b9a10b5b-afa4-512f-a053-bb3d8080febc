export PARAMETER_DEFAULT, PARAMETER_UNSTABLE_BUT_FAST, PARAMETER_STABLE_BUT_SLOW

using MathOptInterface
MOI = MathOptInterface
const MOIU = MOI.Utilities
const AFFEQ = MOI.ConstraintIndex{MOI.ScalarAffineFunction{Cdouble}, MOI.EqualTo{Cdouble}}

mutable struct Optimizer <: MOI.AbstractOptimizer
    objconstant::Cdouble
    objsign::Int
    blockdims::Vector{Int}
    varmap::Vector{Tuple{Int, Int, Int}} # Variable Index vi -> blk, i, j
    b::Vector{Cdouble}
    problem::SDPAProblem
    solve_time::Float64
    silent::Bool
    options::Dict{Symbol, Any}
    function Optimizer(; kwargs...)
		optimizer = new(
            zero(Cdouble), 1, Int[], Tuple{Int, Int, Int}[], Cdouble[],
            SDPAProblem(), NaN, false, Dict{Symbol, Any}())
		for (key, value) in kwargs
			MOI.set(optimizer, MOI.RawParameter(key), value)
		end
		return optimizer
    end
end

varmap(optimizer::Optimizer, vi::MOI.VariableIndex) = optimizer.varmap[vi.value]

function MOI.supports(optimizer::Optimizer, param::MOI.RawParameter)
	return param.name in keys(SET_PARAM)
end
function MOI.set(optimizer::Optimizer, param::MOI.RawParameter, value)
	if !MOI.supports(optimizer, param)
		throw(MOI.UnsupportedAttribute(param))
	end
	optimizer.options[param.name] = value
end
function MOI.get(optimizer::Optimizer, param::MOI.RawParameter)
	# TODO: This gives a poor error message if the name of the parameter is invalid.
	return optimizer.options[param.name]
end

MOI.supports(::Optimizer, ::MOI.Silent) = true
function MOI.set(optimizer::Optimizer, ::MOI.Silent, value::Bool)
	optimizer.silent = value
end
MOI.get(optimizer::Optimizer, ::MOI.Silent) = optimizer.silent

MOI.get(::Optimizer, ::MOI.SolverName) = "SDPA"

# See https://www.researchgate.net/publication/247456489_SDPA_SemiDefinite_Programming_Algorithm_User's_Manual_-_Version_600
# "SDPA (SemiDefinite Programming Algorithm) User's Manual — Version 6.00" Section 6.2
const RAW_STATUS = Dict(
    noINFO        => "The iteration has exceeded the maxIteration and stopped with no informationon the primal feasibility and the dual feasibility.",
    pdOPT => "The normal termination yielding both primal and dual approximate optimal solutions.",
    pFEAS => "The primal problem got feasible but the iteration has exceeded the maxIteration and stopped.",
    dFEAS => "The dual problem got feasible but the iteration has exceeded the maxIteration and stopped.",
    pdFEAS => "Both primal problem and the dual problem got feasible, but the iterationhas exceeded the maxIteration and stopped.",
    pdINF => "At least one of the primal problem and the dual problem is expected to be infeasible.",
    pFEAS_dINF => "The primal problem has become feasible but the dual problem is expected to be infeasible.",
    pINF_dFEAS => "The dual problem has become feasible but the primal problem is expected to be infeasible.",
    pUNBD => "The primal problem is expected to be unbounded.",
    dUNBD => "The dual problem is expected to be unbounded.")

function MOI.get(optimizer::Optimizer, ::MOI.RawStatusString)
	return RAW_STATUS[getPhaseValue(optimizer.problem)]
end
function MOI.get(optimizer::Optimizer, ::MOI.SolveTime)
	return optimizer.solve_time
end

function MOI.is_empty(optimizer::Optimizer)
    return iszero(optimizer.objconstant) &&
        optimizer.objsign == 1 &&
        isempty(optimizer.blockdims) &&
        isempty(optimizer.varmap) &&
        isempty(optimizer.b)
end
function MOI.empty!(optimizer::Optimizer)
    optimizer.objconstant = zero(Cdouble)
    optimizer.objsign = 1
    empty!(optimizer.blockdims)
    empty!(optimizer.varmap)
    empty!(optimizer.b)
    optimizer.problem = SDPAProblem()
end

function MOI.supports(
    optimizer::Optimizer,
    ::Union{MOI.ObjectiveSense,
            MOI.ObjectiveFunction{<:Union{MOI.SingleVariable,
                                          MOI.ScalarAffineFunction{Cdouble}}}})
    return true
end

function MOI.supports_constraint(
    ::Optimizer, ::Type{MOI.VectorOfVariables}, ::Type{MOI.Reals})
    return false
end
const SupportedSets = Union{MOI.Nonnegatives, MOI.PositiveSemidefiniteConeTriangle}
function MOI.supports_constraint(
    ::Optimizer, ::Type{MOI.VectorOfVariables},
    ::Type{<:SupportedSets})
    return true
end
function MOI.supports_constraint(
    ::Optimizer, ::Type{MOI.ScalarAffineFunction{Cdouble}},
    ::Type{MOI.EqualTo{Cdouble}})
    return true
end

function MOI.copy_to(dest::Optimizer, src::MOI.ModelLike; kws...)
    return MOIU.automatic_copy_to(dest, src; kws...)
end
MOIU.supports_allocate_load(::Optimizer, copy_names::Bool) = !copy_names

function MOIU.allocate(optimizer::Optimizer, ::MOI.ObjectiveSense, sense::MOI.OptimizationSense)
    # To be sure that it is done before load(optimizer, ::ObjectiveFunction, ...), we do it in allocate
    optimizer.objsign = sense == MOI.MIN_SENSE ? -1 : 1
end
function MOIU.allocate(::Optimizer, ::MOI.ObjectiveFunction, ::Union{MOI.SingleVariable, MOI.ScalarAffineFunction}) end

function MOIU.load(::Optimizer, ::MOI.ObjectiveSense, ::MOI.OptimizationSense) end
# Loads objective coefficient α * vi
function load_objective_term!(optimizer::Optimizer, α, vi::MOI.VariableIndex)
    blk, i, j = varmap(optimizer, vi)
    coef = optimizer.objsign * α
    if i != j
        coef /= 2
    end
    # in SDP format, it is max and in MPB Conic format it is min
    inputElement(optimizer.problem, 0, blk, i, j, float(coef), false)
end
function MOIU.load(optimizer::Optimizer, ::MOI.ObjectiveFunction, f::MOI.ScalarAffineFunction)
    obj = MOIU.canonical(f)
    optimizer.objconstant = f.constant
    for t in obj.terms
        if !iszero(t.coefficient)
            load_objective_term!(optimizer, t.coefficient, t.variable_index)
        end
    end
end
function MOIU.load(optimizer::Optimizer, ::MOI.ObjectiveFunction, f::MOI.SingleVariable)
    load_objective_term!(optimizer, one(Cdouble), f.variable)
end

function new_block(optimizer::Optimizer, set::MOI.Nonnegatives)
    push!(optimizer.blockdims, -MOI.dimension(set))
    blk = length(optimizer.blockdims)
    for i in 1:MOI.dimension(set)
        push!(optimizer.varmap, (blk, i, i))
    end
end

function new_block(optimizer::Optimizer, set::MOI.PositiveSemidefiniteConeTriangle)
    push!(optimizer.blockdims, set.side_dimension)
    blk = length(optimizer.blockdims)
    for i in 1:set.side_dimension
        for j in 1:i
            push!(optimizer.varmap, (blk, i, j))
        end
    end
end

function MOIU.allocate_constrained_variables(optimizer::Optimizer,
                                             set::SupportedSets)
    offset = length(optimizer.varmap)
    new_block(optimizer, set)
    ci = MOI.ConstraintIndex{MOI.VectorOfVariables, typeof(set)}(offset + 1)
    return [MOI.VariableIndex(i) for i in offset .+ (1:MOI.dimension(set))], ci
end

function MOIU.load_constrained_variables(
    optimizer::Optimizer, vis::Vector{MOI.VariableIndex},
    ci::MOI.ConstraintIndex{MOI.VectorOfVariables},
    set::SupportedSets)
end

function MOIU.load_variables(optimizer::Optimizer, nvars)
    @assert nvars == length(optimizer.varmap)
    dummy = isempty(optimizer.b)
    if dummy
        optimizer.b = [one(Cdouble)]
        optimizer.blockdims = [optimizer.blockdims; -1]
    end
    optimizer.problem = SDPAProblem()
    setParameterType(optimizer.problem, PARAMETER_DEFAULT)
	# TODO Take `silent` into account here
    setparameters!(optimizer.problem, optimizer.options)
    inputConstraintNumber(optimizer.problem, length(optimizer.b))
    inputBlockNumber(optimizer.problem, length(optimizer.blockdims))
    for (i, blkdim) in enumerate(optimizer.blockdims)
        inputBlockSize(optimizer.problem, i, blkdim)
        inputBlockType(optimizer.problem, i, blkdim < 0 ? LP : SDP)
    end
    initializeUpperTriangleSpace(optimizer.problem)
    for i in eachindex(optimizer.b)
        inputCVec(optimizer.problem, i, optimizer.b[i])
    end
    if dummy
        inputElement(optimizer.problem, 1, length(optimizer.blockdims), 1, 1, one(Cdouble), false)
    end
end

function MOIU.allocate_constraint(optimizer::Optimizer,
                                  func::MOI.ScalarAffineFunction{Cdouble},
                                  set::MOI.EqualTo{Cdouble})
    push!(optimizer.b, MOI.constant(set))
    return AFFEQ(length(optimizer.b))
end

function MOIU.load_constraint(m::Optimizer, ci::AFFEQ,
                              f::MOI.ScalarAffineFunction, s::MOI.EqualTo)
    if !iszero(MOI.constant(f))
        throw(MOI.ScalarFunctionConstantNotZero{
            Cdouble, MOI.ScalarAffineFunction{Cdouble}, MOI.EqualTo{Cdouble}}(
                MOI.constant(f)))
    end
    f = MOIU.canonical(f) # sum terms with same variables and same outputindex
    for t in f.terms
        if !iszero(t.coefficient)
            blk, i, j = varmap(m, t.variable_index)
            coef = t.coefficient
            if i != j
                coef /= 2
            end
            inputElement(m.problem, ci.value, blk, i, j, float(coef), false)
        end
    end
end

function MOI.optimize!(m::Optimizer)
	start_time = time()
    SDPA.initializeUpperTriangle(m.problem, false)
    SDPA.initializeSolve(m.problem)
    SDPA.solve(m.problem)
    m.solve_time = time() - start_time
end

function MOI.get(m::Optimizer, ::MOI.TerminationStatus)
    status = getPhaseValue(m.problem)
    if status == noINFO
        return MOI.OPTIMIZE_NOT_CALLED
    elseif status == pFEAS
        return MOI.SLOW_PROGRESS
    elseif status == dFEAS
        return MOI.SLOW_PROGRESS
    elseif status == pdFEAS
        return MOI.OPTIMAL
    elseif status == pdINF
        return MOI.INFEASIBLE_OR_UNBOUNDED
    elseif status == pFEAS_dINF
        return MOI.DUAL_INFEASIBLE
    elseif status == pINF_dFEAS
        return MOI.INFEASIBLE
    elseif status == pdOPT
        return MOI.OPTIMAL
    elseif status == pUNBD
        return MOI.DUAL_INFEASIBLE
    elseif status == dUNBD
        return MOI.INFEASIBLE
    end
end

function MOI.get(m::Optimizer, ::MOI.PrimalStatus)
    status = getPhaseValue(m.problem)
    if status == noINFO
        return MOI.UNKNOWN_RESULT_STATUS
    elseif status == pFEAS
        return MOI.FEASIBLE_POINT
    elseif status == dFEAS
        return MOI.UNKNOWN_RESULT_STATUS
    elseif status == pdFEAS
        return MOI.FEASIBLE_POINT
    elseif status == pdINF
        return MOI.UNKNOWN_RESULT_STATUS
    elseif status == pFEAS_dINF
        return MOI.INFEASIBILITY_CERTIFICATE
    elseif status == pINF_dFEAS
        return MOI.INFEASIBLE_POINT
    elseif status == pdOPT
        return MOI.FEASIBLE_POINT
    elseif status == pUNBD
        return MOI.INFEASIBILITY_CERTIFICATE
    elseif status == dUNBD
        return MOI.INFEASIBLE_POINT
    end
end

function MOI.get(m::Optimizer, ::MOI.DualStatus)
    status = getPhaseValue(m.problem)
    if status == noINFO
        return MOI.UNKNOWN_RESULT_STATUS
    elseif status == pFEAS
        return MOI.UNKNOWN_RESULT_STATUS
    elseif status == dFEAS
        return MOI.FEASIBLE_POINT
    elseif status == pdFEAS
        return MOI.FEASIBLE_POINT
    elseif status == pdINF
        return MOI.UNKNOWN_RESULT_STATUS
    elseif status == pFEAS_dINF
        return MOI.INFEASIBLE_POINT
    elseif status == pINF_dFEAS
        return MOI.INFEASIBILITY_CERTIFICATE
    elseif status == pdOPT
        return MOI.FEASIBLE_POINT
    elseif status == pUNBD
        return MOI.INFEASIBLE_POINT
    elseif status == dUNBD
        return MOI.INFEASIBILITY_CERTIFICATE
    end
end

MOI.get(m::Optimizer, ::MOI.ResultCount) = 1
function MOI.get(m::Optimizer, ::MOI.ObjectiveValue)
    return m.objsign * getPrimalObj(m.problem) + m.objconstant
end
function MOI.get(m::Optimizer, ::MOI.DualObjectiveValue)
    return m.objsign * getDualObj(m.problem) + m.objconstant
end
struct PrimalSolutionMatrix <: MOI.AbstractModelAttribute end
MOI.is_set_by_optimize(::PrimalSolutionMatrix) = true
MOI.get(optimizer::Optimizer, ::PrimalSolutionMatrix) = PrimalSolution(optimizer.problem)

struct DualSolutionVector <: MOI.AbstractModelAttribute end
MOI.is_set_by_optimize(::DualSolutionVector) = true
function MOI.get(optimizer::Optimizer, ::DualSolutionVector)
    return unsafe_wrap(Array, getResultXVec(optimizer.problem), getConstraintNumber(optimizer.problem))
end

struct DualSlackMatrix <: MOI.AbstractModelAttribute end
MOI.is_set_by_optimize(::DualSlackMatrix) = true
MOI.get(optimizer::Optimizer, ::DualSlackMatrix) = VarDualSolution(optimizer.problem)

function block(optimizer::Optimizer, ci::MOI.ConstraintIndex{MOI.VectorOfVariables})
    return optimizer.varmap[ci.value][1]
end
function dimension(optimizer::Optimizer, ci::MOI.ConstraintIndex{MOI.VectorOfVariables})
    blockdim = optimizer.blockdims[block(optimizer, ci)]
    if blockdim < 0
        return -blockdim
    else
        return MOI.dimension(MOI.PositiveSemidefiniteConeTriangle(blockdim))
    end
end
function vectorize_block(M, blk::Integer, s::Type{MOI.Nonnegatives})
    return diag(block(M, blk))
end
function vectorize_block(M::AbstractMatrix{Cdouble}, blk::Integer, s::Type{MOI.PositiveSemidefiniteConeTriangle}) where T
    B = block(M, blk)
    d = LinearAlgebra.checksquare(B)
    n = MOI.dimension(MOI.PositiveSemidefiniteConeTriangle(d))
    v = Vector{Cdouble}(undef, n)
    k = 0
    for j in 1:d
        for i in 1:j
            k += 1
            v[k] = B[i, j]
        end
    end
    @assert k == n
    return v
end

function MOI.get(optimizer::Optimizer, ::MOI.VariablePrimal, vi::MOI.VariableIndex)
    blk, i, j = varmap(optimizer, vi)
    return block(MOI.get(optimizer, PrimalSolutionMatrix()), blk)[i, j]
end

function MOI.get(optimizer::Optimizer, ::MOI.ConstraintPrimal,
                 ci::MOI.ConstraintIndex{MOI.VectorOfVariables, S}) where S<:SupportedSets
    return vectorize_block(MOI.get(optimizer, PrimalSolutionMatrix()), block(optimizer, ci), S)
end
function MOI.get(m::Optimizer, ::MOI.ConstraintPrimal, ci::AFFEQ)
    return m.b[ci.value]
end

function MOI.get(optimizer::Optimizer, ::MOI.ConstraintDual,
                 ci::MOI.ConstraintIndex{MOI.VectorOfVariables, S}) where S<:SupportedSets
    return vectorize_block(MOI.get(optimizer, DualSlackMatrix()), block(optimizer, ci), S)
end
function MOI.get(optimizer::Optimizer, ::MOI.ConstraintDual, ci::AFFEQ)
    return -MOI.get(optimizer, DualSolutionVector())[ci.value]
end
