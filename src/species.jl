# species.jl

"""
    species.jl

KIM-API species management and utilities.

This module provides functions for handling chemical species in KIM-API,
including species name lookup, validation, and mapping between string
representations and integer codes used by KIM models.

# Key Types
- `SpeciesName`: Type alias for species integer codes

# Constants
- `SpeciesSymbols`: Tuple of all supported chemical element symbols

# Key Functions
- `get_species_number`: Convert species string to integer code
- `get_species_symbol`: Convert species integer code to string
- `get_species_codes_from_model`: Map species strings to model-specific codes
- `get_species_map_closure`: Create efficient species mapping function

# Model Integration
The module provides functions to check which species are supported by
a specific KIM model and create efficient mappings for repeated use.
"""
const SpeciesName = Cint

"""
    SpeciesSymbols

Tuple containing all chemical element symbols supported by KIM-API.

This includes all elements from the periodic table from hydrogen (H)
to oganesson (Og), plus "electron" as a special particle type.
The order corresponds to the atomic numbers, with "electron" at index 1.

# Example
```julia
SpeciesSymbols[2]  # "H" (hydrogen)
SpeciesSymbols[15] # "Si" (silicon)
```
"""
const SpeciesSymbols::Tuple = (
    "electron",
    "H",
    "He",
    "Li",
    "Be",
    "B",
    "C",
    "N",
    "O",
    "F",
    "Ne",
    "Na",
    "Mg",
    "Al",
    "Si",
    "P",
    "S",
    "Cl",
    "Ar",
    "K",
    "Ca",
    "Sc",
    "Ti",
    "V",
    "Cr",
    "Mn",
    "Fe",
    "Co",
    "Ni",
    "Cu",
    "Zn",
    "Ga",
    "Ge",
    "As",
    "Se",
    "Br",
    "Kr",
    "Rb",
    "Sr",
    "Y",
    "Zr",
    "Nb",
    "Mo",
    "Tc",
    "Ru",
    "Rh",
    "Pd",
    "Ag",
    "Cd",
    "In",
    "Sn",
    "Sb",
    "Te",
    "I",
    "Xe",
    "Cs",
    "Ba",
    "La",
    "Ce",
    "Pr",
    "Nd",
    "Pm",
    "Sm",
    "Eu",
    "Gd",
    "Tb",
    "Dy",
    "Ho",
    "Er",
    "Tm",
    "Yb",
    "Lu",
    "Hf",
    "Ta",
    "W",
    "Re",
    "Os",
    "Ir",
    "Pt",
    "Au",
    "Hg",
    "Tl",
    "Pb",
    "Bi",
    "Po",
    "At",
    "Rn",
    "Fr",
    "Ra",
    "Ac",
    "Th",
    "Pa",
    "U",
    "Np",
    "Pu",
    "Am",
    "Cm",
    "Bk",
    "Cf",
    "Es",
    "Fm",
    "Md",
    "No",
    "Lr",
    "Rf",
    "Db",
    "Sg",
    "Bh",
    "Hs",
    "Mt",
    "Ds",
    "Rg",
    "Cn",
    "Nh",
    "Fl",
    "Mc",
    "Lv",
    "Ts",
    "Og",
)

"""
    SpeciesToAtomicNumbers

Simple dict map between species symbol and atomic numbers
"""
const SpeciesToAtomicNumbers::Dict{String,Cint} =
    Dict(sym => Cint(i - 1) for (i, sym) in enumerate(SpeciesSymbols))

"""
    get_species_number(name::String) -> Cint

Get species name constant from string 
"""
function get_species_number(name::String)
    @ccall libkim.KIM_SpeciesName_FromString(name::Cstring)::Cint
end

"""
    get_species_number(species::Cint) -> String

Get species symbol constant from string (e.g., "Ar", "Si", etc.)
"""
function get_species_symbol(name::Cint)
    ptr = @ccall libkim.KIM_SpeciesName_ToString(name::Cint)::Ptr{Cchar}
    return unsafe_string(ptr)
end


"""
    species_name_known(species::SpeciesName) -> Bool
    
Check if species name is known/valid in KIM-API.
"""
function species_name_known(species::SpeciesName)
    val = @ccall libkim.KIM_SpeciesName_Known(species::Cint)::Cint
    return val != 0
end

"""
    species_name_equal(lhs::SpeciesName, rhs::SpeciesName) -> Bool
    
Check if two species names are equal.
"""
function species_name_equal(lhs::SpeciesName, rhs::SpeciesName)
    val = @ccall libkim.KIM_SpeciesName_Equal(lhs::Cint, rhs::Cint)::Cint
    return val != 0
end

"""
    species_name_not_equal(lhs::SpeciesName, rhs::SpeciesName) -> Bool
    
Check if two species names are not equal.
"""
function species_name_not_equal(lhs::SpeciesName, rhs::SpeciesName)
    val = @ccall libkim.KIM_SpeciesName_NotEqual(lhs::Cint, rhs::Cint)::Cint
    return val != 0
end

"""
    get_species_codes(model::Model, species_strings::Vector{String})
    
Check species support and return array of KIM species codes for each particle.
Throws error if any species not supported. From mdstresslab++
"""
function get_species_codes_from_model(model::Model, species_strings::Vector{String})
    species_codes = Vector{Cint}(undef, length(species_strings))

    for (i, species_str) in enumerate(species_strings)
        species_name = get_species_number(species_str)
        supported, code = get_species_support_and_code(model, species_name)

        if !supported
            error("Species '$species_str' of particle $i not supported")
        end

        species_codes[i] = code
    end

    return species_codes
end

"""
    get_unique_species_map(model::Model, species_list::Vector{String})
    
Check unique species and return mapping dict.
More efficient when many particles of same species.
"""
function get_unique_species_map(model::Model, species_list::Vector{String})
    species_map = Dict{String,Cint}()

    for species_str in unique(species_list)
        species_name = get_species_number(species_str)
        supported, code = get_species_support_and_code(model, species_name)

        if !supported
            error("Species '$species_str' not supported by model")
        end

        species_map[species_str] = code
    end

    return species_map
end


"""
    get_unique_species_map(model::Model, species_list::Vector{String})
    
Map all species strings to their codes from the model.
TODO: Rename :symbol? It might gte confusing with actual Julia :Symbols
"""
function get_supported_species_map(model::Model; species_type::Symbol = :number)
    if species_type != :symbol && species_type != :number
        error("Unsupported species encoding requested")
    end

    species_map = species_type == :symbol ? Dict{String,Cint}() : Dict{Cint,Cint}()

    for species_str in SpeciesSymbols
        species_name = get_species_number(species_str)
        supported, code = get_species_support_and_code(model, species_name)

        if supported
            if species_type == :symbol
                species_map[species_str] = code
            else
                species_map[SpeciesToAtomicNumbers[species_str]] = code
            end
        end
    end

    return species_map
end


"""
    get_static_species_map(model::Model, species_list::Vector{String}) -> Vector{Cint}
    Get a static closure that maps species strings to their codes.
"""
@inline function get_species_map_closure(model::Model; species_type::Symbol = :number)

    species_map = get_supported_species_map(model; species_type = species_type)

    if species_type == :symbol
        return function (species_list::Vector{String})
            species_codes = Vector{Cint}(undef, length(species_list))
            @inbounds for (i, str) in enumerate(species_list)
                species_codes[i] = get(species_map, str, -1)  # -1 if not found
            end
            return species_codes
        end
    elseif species_type == :number
        return function (species_list::Vector{<:Integer})
            species_codes = Vector{Cint}(undef, length(species_list))
            @inbounds for (i, str) in enumerate(species_list)
                species_codes[i] = get(species_map, str, -1)  # -1 if not found
            end
            return species_codes
        end
    else
        error(
            "Invalid species_type, expected types: :number (atomic numbers) and :symbol (atomic symbols)",
        )
    end
end

"""
    get_species_support_and_code(model::Model, species::Cint) -> (supported, code)

Check if a species is supported and get its code.
"""
function get_species_support_and_code(model::Model, species::Cint)
    supported = Ref{Cint}()
    code = Ref{Cint}()

    species_name_unknown = @ccall libkim.KIM_Model_GetSpeciesSupportAndCode(
        model.p::Ptr{Cvoid},
        species::Cint,
        supported::Ptr{Cint},
        code::Ptr{Cint},
    )::Cint
    if species_name_unknown != 0
        error("Species name $species not found")
    end
    return Bool(supported[]), code[]
end


export SpeciesName,
    SpeciesSymbols,
    get_species_number,
    get_species_symbol,
    species_name_known,
    species_name_equal,
    species_name_not_equal,
    get_species_codes_from_model,
    get_unique_species_map,
    get_supported_species_map,
    get_species_map_closure,
    get_species_support_and_code
