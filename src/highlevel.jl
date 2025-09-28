# highlevel.jl

"""
    highlevel.jl

High-level interface for KIM-API model computations.

This module provides a simplified, Julia-friendly interface to KIM-API
models. It handles all the low-level details of model initialization,
neighbor list setup, species mapping, and memory management, exposing
a clean functional interface for energy and force calculations.

# Key Functions
- `KIMModel`: Create a high-level model function from a KIM model name

# Design Philosophy
The high-level interface follows Julia conventions:
- Uses keyword arguments for optional parameters
- Returns structured results in dictionaries
- Automatically handles unit conversions and species mapping
- Provides sensible defaults for common use cases
- Supports both energy-only and energy+forces calculations

# Performance Considerations
The high-level interface pre-computes species mappings and neighbor
list structures for efficiency. For repeated calculations with the
same model, the returned function closure maintains state to minimize
overhead.
"""

import AtomsBase
import AtomsCalculators
using Unitful: ustrip, Quantity

"""
    KIMModel(model_name::String; units=:metal, neighbor_function=nothing, compute=[:energy, :forces]) -> Function

Create a high-level KIM model computation function.

This function initializes a KIM-API model and returns a closure that can be
called repeatedly to perform energy and force calculations. The returned
function handles all low-level KIM-API operations automatically.

# Arguments
- `model_name::String`: KIM model identifier (e.g., "SW_StillingerWeber_1985_Si__MO_405512056662_006")

# Keyword Arguments
- `units::Union{Symbol,NamedTuple}`: Unit system to use. Can be:
  - `:metal`: Å, eV, e, K, ps (LAMMPS metal units)
  - `:real`: Å, kcal/mol, e, K, fs (LAMMPS real units)
  - `:si`: m, J, C, K, s (SI units)
  - `:cgs`: cm, erg, statC, K, s (CGS units)
  - `:electron`: Bohr, Hartree, e, K, fs (Atomic units)
  - Custom named tuple of units:
     (leng)

- `neighbor_function`: Custom neighbor function (not yet implemented)
- `compute::Vector{Symbol}`: Properties to compute, can include `:energy` and/or `:forces`

# Returns
A function `f(species, positions, cell, pbc)` that:
- Accepts:
  - `species::Vector{String}`: Chemical symbols for each atom
  - `positions::Vector{SVector{3,Float64}}`: Atomic positions
  - `cell::Matrix{Float64}`: Unit cell matrix (3×3)
  - `pbc::Vector{Bool}`: Periodic boundary conditions [x,y,z]
- Returns:
  - `Dict{Symbol,Any}`: Results with keys `:energy` and/or `:forces`

# Throws
- `ErrorException`: If model creation fails or requested properties not supported

# Example
```julia
using KIMPortableModels, StaticVectors, LinearAlgebra

# Create model function
model = KIMPortableModels.KIMModel("SW_StillingerWeber_1985_Si__MO_405512056662_006")

# Define system
species = ["Si", "Si"]
positions = [SVector(0.0, 0.0, 0.0), SVector(1.0, 1.0, 1.0)]
cell = Matrix(5.43 * I(3))  # Silicon lattice parameter
pbc = [true, true, true]

# Compute properties
results = model(species, positions, cell, pbc)
println("Energy: ", results[:energy])
println("Forces: ", results[:forces])
```

# Implementation Notes
- Automatically generates ghost atoms for periodic boundary conditions
- Pre-computes species mappings for efficiency
- Handles multiple cutoff distances if required by the model
- Uses zero-based indexing internally to match KIM-API conventions
"""
function KIMModel(
    model_name::String;
    units::Union{Symbol,NamedTuple} = :metal,
    neighbor_function = nothing, #TODO: Handle neighbor function properly
    compute = [:energy, :forces],
)
    # Initialize model
    local units_in
    if units isa Symbol
        units_in = get_lammps_style_units(units)
    elseif units isa NamedTuple
        # Ensure units are in correct order
        if length(units) != 5
            error(
                "Units tuple must have exactly 5 elements: (length_unit, energy_unit, charge_unit, temperature_unit, time_unit)",
            )
        end
        sorted_units = []
        for unit_order in [:length, :energy, :charge, :temperature, :time]
            sorted_units = push!(sorted_units, getfield(units, Symbol(unit_order)))
        end
        units_in = (sorted_units...,)
    else
        error("Invalid units type. Must be Symbol or NamedTuple.")
    end

    model, accepted = create_model(
        Numbering(0), #TODO use one based numbering
        units_in...,
        model_name,
    )
    if !accepted
        error("Units not accepted")
    end

    args = create_compute_arguments(model)
    # Check support status
    supports_energy = notSupported
    supports_forces = notSupported

    if :energy in compute
        supports_energy = get_argument_support_status(args, partialEnergy)
        if supports_energy == notSupported
            error("Model does not support energy computation")
        end
    end

    if :forces in compute
        supports_forces = get_argument_support_status(args, partialForces)
        if supports_forces == notSupported
            error("Model does not support forces computation")
        end
    end

    if length(compute) == 0
        error("At least one compute argument must be requested: :energy or :forces")
    end
    if length(compute) > 2
        error("Only :energy and :forces can be requested together")
    end

    # TODO: Add support for other compute arguments if needed

    # Set neighbor callback if provided
    n_cutoffs = 0
    cutoffs = Float64[]
    will_not_request_ghost_neigh = true

    if neighbor_function === nothing
        # default neighbor function
        n_cutoffs, cutoffs, will_not_request_ghost_neigh = get_neighbor_list_pointers(model)
    else
        error("TODO: Handle custom neighbor function")
    end


    species_support_map = get_species_map_closure(model)

    # Return closure
    return function _compute_model(species, positions, cell, pbc)
        # Create neighbor lists if needed
        if neighbor_function === nothing
            containers, coords, all_species, contributing, atom_indices =
                create_kim_neighborlists(
                    species,
                    positions,
                    cell,
                    pbc,
                    cutoffs;
                    will_not_request_ghost_neigh = will_not_request_ghost_neigh,
                )
        else
            error("TODO: Neighbor function is not provided.")
        end
        particle_species_codes = species_support_map(all_species)
        # Set pointers

        n = size(coords, 2)
        n_ref = Ref{Cint}(n)
        energy_ref = Ref{Cdouble}(0.0)
        forces = zeros(3, n)

        set_argument_pointer!(args, numberOfParticles, n_ref)
        set_argument_pointer!(args, particleSpeciesCodes, particle_species_codes)
        set_argument_pointer!(args, coordinates, coords)
        set_argument_pointer!(args, particleContributing, contributing)

        if :energy in compute && supports_energy != notSupported
            set_argument_pointer!(args, partialEnergy, energy_ref)
        end

        if :forces in compute && supports_forces != notSupported
            set_argument_pointer!(args, partialForces, forces)
        end
        # Results storage

        results = Dict{Symbol,Any}()

        # Set neighbor list if provided
        if neighbor_function === nothing
            GC.@preserve containers coords forces energy_ref n n_ref particle_species_codes begin
                fptr = @cast_as_kim_neigh_fptr(kim_neighbors_callback)
                data_obj_ptr = pointer_from_objref(containers)
                set_callback_pointer!(args, GetNeighborList, c, fptr, data_obj_ptr)
                compute!(model, args)
            end
        else
            error("TODO: Handle custom neighbor function")
        end
        if :energy in compute && supports_energy != notSupported
            results[:energy] = energy_ref[]
        end

        if :forces in compute && supports_forces != notSupported
            results[:forces] = add_forces(forces, atom_indices)
        end
        return results
    end
end

"""
    KIMCalculator(model_name::String; kwargs...) -> AtomsCalculators.AbstractCalculator

Create a simple `AtomsCalculators`-compatible calculator that wraps a KIM model.

This provides a minimal interface to KIM models that works with the AtomsCalculators
ecosystem. The calculator can compute energies and forces for AtomsBase systems.

# Arguments
- `model_name::String`: KIM model identifier

# Keyword Arguments
- `units::Symbol`: Unit system (default: `:metal`)
- `compute::Vector{Symbol}`: Properties to compute (default: `[:energy, :forces]`)

# Example
```julia
using AtomsBase, AtomsCalculators
calc = KIMCalculator("SW_StillingerWeber_1985_Si__MO_405512056662_006")
energy = AtomsCalculators.potential_energy(calc, system)
forces = AtomsCalculators.forces(calc, system)
```
"""
struct KIMCalculator
    model_name::String
    model_fn::Function
end

function KIMCalculator(model_name::String; kwargs...)
    model_fn = KIMModel(model_name; kwargs...)
    return KIMCalculator(model_name, model_fn)
end

# Direct call interface - compute everything and return dict
(calc::KIMCalculator)(system) = _evaluate_system(calc, system)

# AtomsCalculators interface
AtomsCalculators.potential_energy(calc::KIMCalculator, system) =
    _evaluate_system(calc, system)[:energy]

AtomsCalculators.forces(calc::KIMCalculator, system) =
    _evaluate_system(calc, system)[:forces]

# Internal evaluation
@inline function _evaluate_system(calc::KIMCalculator, system)
    # Handle different AtomsBase system types
    local species::Vector{String}, positions::Vector{SVector{3,Float64}}, cell::Matrix{Float64}, pbc::Vector{Bool}

    if hasfield(typeof(system), :particles)
        # FlexibleSystem - extract from particles
        n_particles = length(system.particles)
        species = Vector{String}(undef, n_particles)
        positions = Vector{SVector{3,Float64}}(undef, n_particles)

        @inbounds for (i, p) in enumerate(system.particles)
            species[i] = String(p.first)
            positions[i] = SVector{3,Float64}(_strip_units.(p.second))
        end
    else
        # Try standard AtomsBase interface
        try
            raw_species = AtomsBase.chemical_symbols(system)
            raw_positions = AtomsBase.positions(system)
            n_particles = length(raw_species)

            species = Vector{String}(undef, n_particles)
            positions = Vector{SVector{3,Float64}}(undef, n_particles)

            @inbounds for i in 1:n_particles
                species[i] = String(raw_species[i])
                positions[i] = SVector{3,Float64}(_strip_units.(raw_positions[i]))
            end
        catch
            error("Cannot extract species and positions from system of type $(typeof(system))")
        end
    end

    # Handle cell matrix
    try
        if hasmethod(AtomsBase.cell_vectors, Tuple{typeof(system)})
            # Use cell_vectors if available
            vecs = AtomsBase.cell_vectors(system)
            cell = Matrix{Float64}(undef, 3, 3)
            @inbounds for (j, v) in enumerate(vecs)
                for i in 1:3
                    cell[i, j] = Float64(_strip_units(v[i]))
                end
            end
        else
            # Fall back to cell matrix
            raw_cell = AtomsBase.cell(system)
            cell = Matrix{Float64}(undef, 3, 3)
            @inbounds for i in 1:3, j in 1:3
                cell[i, j] = Float64(_strip_units(raw_cell[i, j]))
            end
        end
    catch
        error("Cannot extract cell information from system of type $(typeof(system))")
    end

    # Get boundary conditions
    try
        if hasmethod(AtomsBase.periodicity, Tuple{typeof(system)})
            raw_pbc = AtomsBase.periodicity(system)
            pbc = Vector{Bool}(undef, 3)
            @inbounds for i in 1:3
                pbc[i] = Bool(raw_pbc[i])
            end
        elseif hasmethod(AtomsBase.boundary_conditions, Tuple{typeof(system)})
            raw_pbc = AtomsBase.boundary_conditions(system)
            pbc = Vector{Bool}(undef, 3)
            @inbounds for i in 1:3
                pbc[i] = Bool(raw_pbc[i])
            end
        else
            pbc = Bool[false, false, false]  # Default to non-periodic
        end
    catch
        pbc = Bool[false, false, false]  # Default to non-periodic
    end

    return calc.model_fn(species, positions, cell, pbc)
end

# Helper function to strip units
@inline _strip_units(x::Quantity) = Float64(x.val)
@inline _strip_units(x::Number) = Float64(x)

# Export high-level interface
export KIMModel, KIMCalculator
