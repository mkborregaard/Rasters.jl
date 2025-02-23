
export NCDstack, NCDarray

const NCD = NCDatasets

const UNNAMED_NCD_FILE_KEY = "unnamed"

const NCD_FILL_TYPES = (Int8,UInt8,Int16,UInt16,Int32,UInt32,Int64,UInt64,Float32,Float64,Char,String)

# CF standards don't enforce dimension names.
# But these are common, and should take care of most dims.
const NCD_DIMMAP = Dict(
    "lat" => Y,
    "latitude" => Y,
    "lon" => X,
    "long" => X,
    "longitude" => X,
    "time" => Ti,
    "lev" => Z,
    "mlev" => Z,
    "level" => Z,
    "vertical" => Z,
    "x" => X,
    "y" => Y,
    "z" => Z,
    "band" => Band,
)

haslayers(::Type{NCDfile}) = true
defaultcrs(::Type{NCDfile}) = EPSG(4326) 
defaultmappedcrs(::Type{NCDfile}) = EPSG(4326) 

# Raster ########################################################################

@deprecate NCDarray(args...; kw...) Raster(args...; source=NCDfile, kw...)

function Raster(ds::NCD.NCDataset, filename::AbstractString, key=nothing; kw...)
    key = _firstkey(ds, key)
    Raster(ds[key], filename, key; kw...)
end

_firstkey(ds::NCD.NCDataset, key::Nothing=nothing) = Symbol(first(layerkeys(ds)))
_firstkey(ds::NCD.NCDataset, key) = Symbol(key)

function FileArray(var::NCD.CFVariable, filename::AbstractString; kw...)
    da = RasterDiskArray{NCDfile}(var)
    size_ = size(da)
    eachchunk = DA.eachchunk(da)
    haschunks = DA.haschunks(da)
    T = eltype(var)
    N = length(size_)
    FileArray{NCDfile,T,N}(filename, size_; eachchunk, haschunks, kw...)
end

function Base.open(f::Function, A::FileArray{NCDfile}; write=A.write, kw...)
    _open(NCDfile, filename(A); key=key(A), write, kw...) do var
        f(RasterDiskArray{NCDfile}(var, DA.eachchunk(A), DA.haschunks(A)))
    end
end

"""
    Base.write(filename::AbstractString, ::Type{NCDfile}, s::AbstractRaster)

Write an NCDarray to a NetCDF file using NCDatasets.jl

Returns `filename`.
"""
function Base.write(filename::AbstractString, ::Type{NCDfile}, A::AbstractRaster)
    ds = NCD.Dataset(filename, "c"; attrib=_attribdict(metadata(A)))
    try
        _ncdwritevar!(ds, A)
    finally
        close(ds)
    end
    return filename
end

# Stack ########################################################################

@deprecate NCDstack(args...; kw...) RasterStack(args...; source=NCDfile, kw...)

"""
    Base.write(filename::AbstractString, ::Type{NCDfile}, s::AbstractRasterStack)

Write an NCDstack to a single netcdf file, using NCDatasets.jl.

Currently `Metadata` is not handled for dimensions, and `Metadata`
from other [`AbstractRaster`](@ref) @types is ignored.
"""
function Base.write(filename::AbstractString, ::Type{NCDfile}, s::AbstractRasterStack)
    ds = NCD.Dataset(filename, "c"; attrib=_attribdict(metadata(s)))
    try 
        map(key -> _ncdwritevar!(ds, s[key]), keys(s))
    finally
        close(ds)
    end
    return filename
end 

function create(filename, ::Type{NCDfile}, T::Union{Type,Tuple}, dims::DimTuple; 
    name=:layer1, keys=(name,), layerdims=map(_->dims, keys), missingval=nothing, metadata=NoMetadata()
)
    types = T isa Tuple ? T : Ref(T)
    missingval = T isa Tuple ? missingval : Ref(missingval)
    # Create layers of zero arrays
    layers = map(layerdims, keys, types, missingval) do lds, key, t, mv 
        A = FillArrays.Zeros{t}(map(length, lds))
        Raster(A, dims=lds; name=key, missingval=mv)
    end
    write(filename, NCDfile, Raster(first(layers)))
    return Raster(filename)
end

# DimensionalData methods for NCDatasets types ###############################

function DD.dims(ds::NCD.Dataset, crs=nothing, mappedcrs=nothing)
    map(_dimkeys(ds)) do key
        _ncddim(ds, key, crs, mappedcrs)
    end |> Tuple
end
function DD.dims(var::NCD.CFVariable, crs=nothing, mappedcrs=nothing)
    names = NCD.dimnames(var)
    map(names) do name
        _ncddim(var.var.ds, name, crs, mappedcrs)
    end |> Tuple
end

DD.metadata(ds::NCD.Dataset) = Metadata{NCDfile}(LA.metadatadict(ds.attrib))
DD.metadata(var::NCD.CFVariable) = Metadata{NCDfile}(LA.metadatadict(var.attrib))
DD.metadata(var::NCD.Variable) = Metadata{NCDfile}(LA.metadatadict(var.attrib))

function DD.layerdims(ds::NCD.Dataset)
    keys = Tuple(layerkeys(ds))
    dimtypes = map(keys) do key
        DD.layerdims(NCD.variable(ds, string(key)))
    end
    NamedTuple{map(Symbol, keys)}(dimtypes)
end
function DD.layerdims(var::NCD.Variable)
    map(NCD.dimnames(var)) do dimname
        _ncddimtype(dimname)()
    end
end

DD.layermetadata(ds::NCD.Dataset) = _layermetadata(ds, Tuple(layerkeys(ds)))
function _layermetadata(ds, keys)
    dimtypes = map(k -> DD.metadata(NCD.variable(ds, string(k))), keys)
    NamedTuple{map(Symbol, keys)}(dimtypes)
end

missingval(var::NCD.CFVariable) = missing
layermissingval(ds::NCD.Dataset) = missing

function layerkeys(ds::NCD.Dataset)
    dimkeys = _dimkeys(ds)
    toremove = if "bnds" in dimkeys
        dimkeys = setdiff(dimkeys, ("bnds",))
        boundskeys = String[]
        for k in dimkeys
            var = NCD.variable(ds, k)
            if haskey(var.attrib, "bounds")
                push!(boundskeys, var.attrib["bounds"])
            end
        end
        union(dimkeys, boundskeys)::Vector{String}
    else
        dimkeys::Vector{String}
    end
    return setdiff(keys(ds), toremove)
end

function FileStack{NCDfile}(ds::NCD.Dataset, filename::AbstractString; write=false, keys)
    keys = map(Symbol, keys isa Nothing ? layerkeys(ds) : keys) |> Tuple
    type_size_ec_hc = map(keys) do key
        var = ds[string(key)]
        Union{Missing,eltype(var)}, size(var), _ncd_eachchunk(var), _ncd_haschunks(var)
    end
    layertypes = NamedTuple{keys}(map(x->x[1], type_size_ec_hc))
    layersizes = NamedTuple{keys}(map(x->x[2], type_size_ec_hc))
    eachchunk = NamedTuple{keys}(map(x->x[3], type_size_ec_hc))
    haschunks = NamedTuple{keys}(map(x->x[4], type_size_ec_hc))
    return FileStack{NCDfile}(filename, layertypes, layersizes, eachchunk, haschunks, write)
end

# Utils ########################################################################

function _open(f, ::Type{NCDfile}, filename::AbstractString; key=nothing, write=false)
    lookup = write ? "a" : "r"
    if key isa Nothing
        NCD.Dataset(cleanreturn ∘ f, filename, lookup)
    else
        NCD.Dataset(filename, lookup) do ds
            cleanreturn(f(ds[_firstkey(ds, key)]))
        end
    end
end

cleanreturn(A::NCD.CFVariable) = Array(A)

function _ncddim(ds, dimname::Key, crs=nothing, mappedcrs=nothing)
    if haskey(ds, dimname)
        D = _ncddimtype(dimname)
        lookup = _ncdlookup(ds, dimname, D, crs, mappedcrs)
        return D(lookup)
    else
        # The var doesn't exist. Maybe its `complex` or some other marker,
        # so make it a custom `Dim` with `NoLookup`
        len = _ncfinddimlen(ds, dimname)
        len === nothing && _unuseddimerror()
        return Dim{Symbol(dimname)}(NoLookup(Base.OneTo(len)))
    end
end

function _ncfinddimlen(ds, dimname) 
    for key in keys(ds)
        var = NCD.variable(ds, key)
        dimnames = NCD.dimnames(var)
        if dimname in dimnames 
            return size(var)[findfirst(==(dimname), dimnames)]
        end
    end
    return nothing
end

# Find the matching dimension constructor. If its an unknown name 
# use the generic Dim with the dim name as type parameter
_ncddimtype(dimname) = haskey(NCD_DIMMAP, dimname) ? NCD_DIMMAP[dimname] : DD.basetypeof(DD.key2dim(Symbol(dimname)))

# _ncdlookup
# Generate a `LookupArray` from a netcdf dim.
function _ncdlookup(ds::NCD.Dataset, dimname, D, crs, mappedcrs)
    dvar = ds[dimname]
    index = dvar[:]
    metadata = Metadata{NCDfile}(LA.metadatadict(dvar.attrib))
    return _ncdlookup(ds, dimname, D, index, metadata, crs, mappedcrs)
end
# For unknown types we just make a Categorical lookup
function _ncdlookup(ds::NCD.Dataset, dimname, D, index::AbstractArray, metadata, crs, mappedcrs)
    Categorical(index; metadata=metadata)
end
# For Number and AbstractTime we generate order/span/sampling
function _ncdlookup(
    ds::NCD.Dataset, dimname, D, index::AbstractArray{<:Union{Number,Dates.AbstractTime}}, 
    metadata, crs, mappedcrs
)
    # Assume the locus is at the center of the cell if boundaries aren't provided.
    # http://cfconventions.org/cf-conventions/cf-conventions.html#cell-boundaries
    order = _ncdorder(index)
    var = NCD.variable(ds, dimname)
    if haskey(var.attrib, "bounds")
        boundskey = var.attrib["bounds"]
        boundsmatrix = Array(ds[boundskey])
        span, sampling = Explicit(boundsmatrix), Intervals(Center())
        return _ncdlookup(D, index, order, span, sampling, metadata, crs, mappedcrs)
    elseif eltype(index) <: Dates.AbstractTime
        span, sampling = _ncdperiod(index, metadata)
        return _ncdlookup(D, index, order, span, sampling, metadata, crs, mappedcrs)
    else
        span, sampling = _ncdspan(index, order), Points()
        return _ncdlookup(D, index, order, span, sampling, metadata, crs, mappedcrs)
    end
end
# For X and Y use a Mapped <: AbstractSampled lookup
function _ncdlookup(
    D::Type{<:Union{<:XDim,<:YDim}}, index, order::Order, span, sampling, metadata, crs, mappedcrs
)
    # If the index is regularly spaced and there is no crs
    # then there is probably just one crs - the mappedcrs
    crs = if crs isa Nothing && span isa Regular
        mappedcrs
    else
        crs
    end
    dim = DD.basetypeof(D)()
    return Mapped(index, order, span, sampling, metadata, crs, mappedcrs, dim)
end
# Band dims have a Categorical lookup, with order
function _ncdlookup(D::Type{<:Band}, index, order::Order, span, sampling, metadata, crs, mappedcrs)
    Categorical(index, order, metadata)
end
# Otherwise use a regular Sampled lookup
function _ncdlookup(D::Type, index, order::Order, span, sampling, metadata, crs, mappedcrs)
    Sampled(index, order, span, sampling, metadata)
end


function _ncdorder(index)
    index[end] > index[1] ? ForwardOrdered() : ReverseOrdered()
end

function _ncdspan(index, order)
    # Handle a length 1 index
    length(index) == 1 && return Regular(zero(eltype(index)))
    step = index[2] - index[1]
    for i in 2:length(index)-1
        # If any step sizes don't match, its Irregular
        if !(index[i+1] - index[i] ≈ step)
            bounds = if length(index) > 1
                beginhalfcell = abs((index[2] - index[1]) * 0.5)
                endhalfcell = abs((index[end] - index[end-1]) * 0.5)
                if LA.isrev(order)
                    index[end] - endhalfcell, index[1] + beginhalfcell
                else
                    index[1] - beginhalfcell, index[end] + endhalfcell
                end
            else
                index[1], index[1]
            end
            return Irregular(bounds)
        end
    end
    # Otherwise regular
    return Regular(step)
end

# delta_t and ave_period are not CF standards, but CDC
function _ncdperiod(index, metadata::Metadata{NCDfile})
    if haskey(metadata, :delta_t)
        period = _parse_period(metadata[:delta_t])
        period isa Nothing || return Regular(period), Points()
    elseif haskey(metadata, :avg_period)
        period = _parse_period(metadata[:avg_period])
        period isa Nothing || return Regular(period), Intervals(Center())
    end
    return sampling = Irregular((nothing, nothing)), Points()
end

function _parse_period(period_str::String)
    regex = r"(\d\d\d\d)-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)"
    mtch = match(regex, period_str)
    if mtch === nothing
        return nothing
    else
        vals = Tuple(parse.(Int, mtch.captures))
        periods = (Year, Month, Day, Hour, Minute, Second)
        if length(vals) == length(periods)
            compound = sum(map((p, v) -> p(v), periods, vals))
            if length(compound.periods) == 1
                return compound.periods[1]
            else
                return compound
            end
        else
            return nothing 
        end
    end
end

_attribdict(md::Metadata{NCDfile}) = Dict{String,Any}(string(k) => v for (k, v) in md)
_attribdict(md) = Dict{String,Any}()

_dimkeys(ds::NCD.Dataset) = keys(ds.dim)

# Add a var array to a dataset before writing it.
function _ncdwritevar!(ds::NCD.Dataset, A::AbstractRaster{T,N}) where {T,N}
    _def_dim_var!(ds, A)
    attrib = _attribdict(metadata(A))
    # Set _FillValue
    eltyp = _notmissingtype(Base.uniontypes(T)...)
    if ismissing(missingval(A))
        fillval = if haskey(attrib, "_FillValue") && attrib["_FillValue"] isa eltyp
            attrib["_FillValue"]
        else
            NCD.fillvalue(eltyp)
        end
        attrib["_FillValue"] = fillval
        A = replace_missing(A, fillval)
    elseif missingval(A) isa T
        attrib["_FillValue"] = missingval(A)
    else
        missingval(A) isa Nothing || @warn "`missingval` $(missingval(A)) is not the same type as your data $T."
    end

    key = if string(name(A)) == ""
        UNNAMED_NCD_FILE_KEY
    else
        string(name(A))
    end

    dimnames = lowercase.(string.(map(name, dims(A))))
    var = NCD.defVar(ds, key, eltyp, dimnames; attrib=attrib)
    # TODO do this with DiskArrays broadcast ??
    var[:] = parent(read(A))
end

_def_dim_var!(ds::NCD.Dataset, A) = map(d -> _def_dim_var!(ds, d), dims(A))
function _def_dim_var!(ds::NCD.Dataset, dim::Dimension)
    dimkey = lowercase(string(name(dim)))
    haskey(ds.dim, dimkey) && return nothing
    NCD.defDim(ds, dimkey, length(dim))
    lookup(dim) isa NoLookup && return nothing

    # Shift index before conversion to Mapped
    dim = _ncdshiftlocus(dim)
    if dim isa Y || dim isa X
        dim = convertlookup(Mapped, dim)
    end
    attrib = _attribdict(metadata(dim))
    if span(dim) isa Explicit
        bounds = val(span(dim))
        boundskey = get(metadata(dim), :bounds, string(dimkey, "_bnds"))
        push!(attrib, "bounds" => boundskey)
        NCD.defVar(ds, boundskey, bounds, ("bnds", dimkey))
    end
    NCD.defVar(ds, dimkey, Vector(index(dim)), (dimkey,); attrib=attrib)
    return nothing
end

_notmissingtype(::Type{Missing}, next...) = _notmissingtype(next...)
_notmissingtype(x::Type, next...) = x in NCD_FILL_TYPES ? x : _notmissingtype(next...)
_notmissingtype() = error("Your data is not a type that netcdf can store")

_ncdshiftlocus(dim::Dimension) = _ncdshiftlocus(lookup(dim), dim)
_ncdshiftlocus(::LookupArray, dim::Dimension) = dim
function _ncdshiftlocus(lookup::AbstractSampled, dim::Dimension)
    if span(lookup) isa Regular && sampling(lookup) isa Intervals
        # We cant easily shift a DateTime value
        if eltype(dim) isa Dates.AbstractDateTime
            if !(locus(dim) isa Center)
                @warn "To save to netcdf, DateTime values should be the interval Center, rather than the $(nameof(typeof(locus(dim))))"
            end
            dim
        else
            shiftlocus(Center(), dim)
        end
    else
        dim
    end
end

_unuseddimerror(dimname) = error("Netcdf contains unused dimension $dimname")

function _ncd_eachchunk(var) 
    # chunklookup, chunkvec = NCDatasets.chunking(var)
    # chunksize = chunklookup == :chunked ? Tuple(chunkvec) : 
    chunksize = size(var)
    DA.GridChunks(var, chunksize)
end

function _ncd_haschunks(var) 
    # chunklookup, _ = NCDatasets.chunking(var)
    # chunklookup == :chunked ? DA.Chunked() : 
    DA.Unchunked()
end

# precompilation

const _NCDVar = NCDatasets.CFVariable{Union{Missing, Float32}, 3, NCDatasets.Variable{Float32, 3, NCDatasets.NCDataset}, NCDatasets.Attributes{NCDatasets.NCDataset{Nothing}}, NamedTuple{(:fillvalue, :scale_factor, :add_offset, :calendar, :time_origin, :time_factor), Tuple{Float32, Nothing, Nothing, Nothing, Nothing, Nothing}}}
precompile(Rasters.FileArray, (_NCDVar, String))
precompile(layerkeys, (NCDatasets.NCDataset{Nothing},))
precompile(dims, (_NCDVar,Symbol))
precompile(dims, (_NCDVar,Symbol,Nothing,Nothing))
precompile(dims, (_NCDVar,Symbol,Nothing,EPSG))
precompile(dims, (_NCDVar,Symbol,EPSG,EPSG))
precompile(_firstkey, (NCDatasets.NCDataset{Nothing},))
precompile(_ncddim, (NCDatasets.NCDataset{Nothing}, Symbol, Nothing, Nothing))
precompile(_ncddim, (NCDatasets.NCDataset{Nothing}, Symbol, Nothing, EPSG))
precompile(_ncddim, (NCDatasets.NCDataset{Nothing}, Symbol, EPSG, EPSG))
precompile(Raster, (NCDatasets.NCDataset{Nothing}, String, Nothing))
precompile(Raster, (NCDatasets.NCDataset{Nothing}, String, Symbol))
precompile(Raster, (_NCDVar, String, Symbol))

precompile(geoarray, (String,))
precompile(Raster, (String,))
