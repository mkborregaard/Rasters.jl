using Rasters, Test, Statistics, Dates, Plots
using Rasters.LookupArrays, Rasters.Dimensions
import NCDatasets, ArchGDAL
using Rasters: FileArray, GRDfile, GDALfile

testpath = joinpath(dirname(pathof(Rasters)), "../test/")
include(joinpath(testpath, "test_utils.jl"))
const DD = DimensionalData

maybedownload("https://raw.githubusercontent.com/rspatial/raster/master/inst/external/rlogo.grd", "rlogo.grd")
maybedownload("https://github.com/rspatial/raster/raw/master/inst/external/rlogo.gri", "rlogo.gri")
stem = joinpath(testpath, "data/rlogo")
@test isfile(stem * ".grd")
@test isfile(stem * ".gri")
path = stem * ".gri"

@testset "Grd array" begin
    @time grdarray = Raster(path)

    @testset "open" begin
        @test all(open(A -> A[Y=1], grdarray) .=== grdarray[:, 1, :])
        tempfile = tempname()
        cp(stem * ".grd", tempfile * ".grd")
        cp(stem * ".gri", tempfile * ".gri")
        grdwritearray = Raster(tempfile * ".gri")
        open(grdwritearray; write=true) do A
            A .*= 2
        end
        @test Raster(tempfile * ".gri") == grdarray .* 2
    end

    @testset "read" begin
        A = read(grdarray)
        @test A isa Raster
        @test parent(A) isa Array
        A2 = zero(A)
        @time read!(grdarray, A2);
        A3 = zero(A)
        @time read!(path, A3);
        @test A == A2 == A3
    end

    @testset "array properties" begin
        @test grdarray isa Raster{Float32,3}
    end

    @testset "dimensions" begin
        @test length(val(dims(dims(grdarray), X))) == 101
        @test ndims(grdarray) == 3
        @test dims(grdarray) isa Tuple{<:X,<:Y,<:Band}
        @test refdims(grdarray) == ()
        @test bounds(grdarray) == ((0.0, 101.0), (0.0, 77.0), (1, 3))
    end

    @testset "other fields" begin
        @test missingval(grdarray) == -3.4f38
        @test metadata(grdarray) isa Metadata{GRDfile}
        @test name(grdarray) == Symbol("red:green:blue")
        @test label(grdarray) == "red:green:blue"
        @test units(grdarray) == nothing
        customgrdarray = Raster(path; name=:test, mappedcrs=EPSG(4326));
        @test name(customgrdarray) == :test
        @test label(customgrdarray) == "test"
        @test mappedcrs(dims(customgrdarray, Y)) == EPSG(4326)
        @test mappedcrs(dims(customgrdarray, X)) == EPSG(4326)
        @test mappedcrs(customgrdarray) == EPSG(4326)
        proj = ProjString("+proj=merc +datum=WGS84")
        @test crs(dims(customgrdarray, Y)) == proj
        @test crs(dims(customgrdarray, X)) == proj
        @test crs(customgrdarray) == proj
    end

    @testset "getindex" begin
        @test grdarray[Band(1)] isa Raster{Float32,2}
        @test grdarray[Y(1), Band(1)] isa Raster{Float32,1}
        @test grdarray[X(1), Band(1)] isa Raster{Float32,1}
        @test grdarray[X(50), Y(30), Band(1)] == 115.0f0
        @test grdarray[1, 1, 1] == 255.0f0
        @test grdarray[Y(At(20.0; atol=1e10)), X(At(20; atol=1e10)), Band(3)] == 255.0f0
        @test grdarray[Y(Contains(60)), X(Contains(20)), Band(1)] == 255.0f0
    end

    @testset "methods" begin 
        @test mean(grdarray; dims=Y) == mean(parent(grdarray); dims=2)
        @testset "trim, crop, extend" begin
            a = read(grdarray)
            a[X(1:20)] .= missingval(a)
            trimmed = trim(a)
            @test size(trimmed) == (81, 77, 3)
            cropped = crop(a; to=trimmed)
            @test size(cropped) == (81, 77, 3)
            @test all(collect(cropped .== trimmed))
            extended = extend(cropped; to=a);
            @test all(collect(extended .== a))
        end

        @testset "mask and mask! to disk" begin
            msk = replace_missing(grdarray, missing)
            msk[X(1:73), Y([1, 5, 77])] .= missingval(msk)
            @test !any(grdarray[X(1:73)] .=== missingval(msk))
            masked = mask(grdarray; to=msk)
            @test all(masked[X(1:73), Y([1, 5, 77])] .=== missingval(masked))
            tn = tempname()
            tempgrd = tn * ".grd"
            tempgri = tn * ".gri"
            cp(stem * ".grd", tempgrd)
            cp(stem * ".gri", tempgri)
            @test !all(Raster(tempgrd)[X(1:73), Y([1, 5, 77])] .=== missingval(grdarray))
            open(Raster(tempgrd); write=true) do A
                mask!(A; to=msk, missingval=missingval(A))
            end
            @test all(Raster(tempgri)[X(1:73), Y([1, 5, 77])] .=== missingval(grdarray))
            rm(tempgrd)
            rm(tempgri)
        end

        @testset "classify! to disk" begin
            tn = tempname()
            tempgrd = tn * ".grd"
            tempgri = tn * ".gri"
            cp(stem * ".grd", tempgrd)
            cp(stem * ".gri", tempgri)
            extrema(Raster(tempgrd))
            open(Raster(tempgrd); write=true) do A
                classify!(A, [0.0f0 100.0f0 100.0f0; 100 300 255.0f0])
            end
            A = Raster(tempgrd)
            @test count(==(100.0f0), A) + count(==(255.0f0), A) == length(A)
        end

        @testset "mosaic" begin
            @time grdarray = Raster(path)
            A1 = grdarray[X(1:40), Y(1:30)]
            A2 = grdarray[X(27:80), Y(25:60)]
            tn = tempname()
            tempgrd = tn * ".grd"
            tempgri = tn * ".gri"
            cp(stem * ".grd", tempgrd)
            cp(stem * ".gri", tempgri)
            Afile = mosaic(first, A1, A2; missingval=0.0f0, atol=1e-1, filename=tempgrd)
            Amem = mosaic(first, A1, A2; missingval=0.0f0, atol=1e-1)
            Atest = grdarray[X(1:80), Y(1:60)]
            Atest[X(1:26), Y(31:60)] .= 0.0f0
            Atest[X(41:80), Y(1:24)] .= 0.0f0
            @test size(Atest) == size(Afile) == size(Amem)
            @test all(Atest .=== Amem .== Afile)
        end

        @testset "rasterize" begin
            A = read(grdarray)
            R = rasterize(A; to=A)
            # Currently the relation makes this upside-down
            # This will be fixed in another branch.
            @test all(A .=== R .== grdarray)
            B = rebuild(read(grdarray) .= 0x00; missingval=0x00)
            rasterize!(B, read(grdarray))
            @test all(B .=== grdarray |> collect)
        end

        @testset "chunk_series" begin
            @test Rasters.chunk_series(grdarray) isa RasterSeries
            @test size(Rasters.chunk_series(grdarray)) == (1, 1, 1)
        end
    end

    @testset "selectors" begin
        geoA = grdarray[Y(Contains(3)), X(:), Band(1)]
        @test geoA isa Raster{Float32,1}
        @test grdarray[X(Contains(20)), Y(Contains(10)), Band(1)] isa Float32
    end

    @testset "conversion to Raster" begin
        geoA = grdarray[X(1:50), Y(1:1), Band(1)]
        @test size(geoA) == (50, 1)
        @test eltype(geoA) <: Float32
        @time geoA isa Raster{Float32,1}
        @test dims(geoA) isa Tuple{<:X,Y}
        @test refdims(geoA) isa Tuple{<:Band}
        @test metadata(geoA) == metadata(grdarray)
        @test missingval(geoA) == -3.4f38
        @test name(geoA) == Symbol("red:green:blue")
    end

    @testset "write" begin
        @testset "2d" begin
            filename2 = tempname() * ".gri"
            write(filename2, grdarray[Band(1)])
            saved = read(Raster(filename2))
            # 1 band is added again on save
            @test size(saved) == size(grdarray[Band(1:1)])
            @test parent(saved) == parent(grdarray[Band(1:1)])
        end

        @testset "3d with subset" begin
            geoA = grdarray[1:100, 1:50, 1:2]
            filename = tempname() * ".grd"
            write(filename, GRDfile, geoA)
            saved = read(Raster(filename))
            @test size(saved) == size(geoA)
            @test refdims(saved) == ()
            @test bounds(saved) == bounds(geoA)
            @test size(saved) == size(geoA)
            @test missingval(saved) === missingval(geoA)
            @test metadata(saved) != metadata(geoA)
            @test metadata(saved)["creator"] == "Rasters.jl"
            @test all(metadata.(dims(saved)) .== metadata.(dims(geoA)))
            @test name(saved) == name(geoA)
            @test all(lookup.(dims(saved)) .== lookup.(dims(geoA)))
            @test dims(saved) isa typeof(dims(geoA))
            @test all(val.(dims(saved)) .== val.(dims(geoA)))
            @test all(lookup.(dims(saved)) .== lookup.(dims(geoA)))
            @test all(metadata.(dims(saved)) .== metadata.(dims(geoA)))
            @test dims(saved) == dims(geoA)
            @test all(parent(saved) .=== parent(geoA))
            @test saved isa typeof(geoA)
            @test parent(saved) == parent(geoA)
        end

        @testset "to netcdf" begin
            filename2 = tempname() * ".nc"
            span(grdarray[Band(1)])
            write(filename2, grdarray[Band(1)])
            saved = read(Raster(filename2; crs=crs(grdarray)))
            @test size(saved) == size(grdarray[Band(1)])
            @test replace_missing(saved, missingval(grdarray)) ≈ grdarray[Band(1)]
            @test index(saved, X) ≈ index(grdarray, X) .+ 0.5
            @test index(saved, Y) ≈ index(grdarray, Y) .+ 0.5
            @test bounds(saved, Y) == bounds(grdarray, Y)
            @test bounds(saved, X) == bounds(grdarray, X)
        end

        @testset "to gdal" begin
            # No Band
            gdalfilename = tempname() * ".tif"
            write(gdalfilename, GDALfile, grdarray[Band(1)])
            gdalarray = Raster(gdalfilename)
            # @test convert(ProjString, crs(gdalarray)) == convert(ProjString, EPSG(4326))
            @test val(dims(gdalarray, X)) ≈ val(dims(grdarray, X))
            @test val(dims(gdalarray, Y)) ≈ val(dims(grdarray, Y))
            @test Raster(gdalarray) ≈ permutedims(grdarray[Band(1)], [X(), Y()])
            # 3 Bands
            gdalfilename2 = tempname() * ".tif"
            write(gdalfilename2, grdarray)
            gdalarray2 = Raster(gdalfilename2)
            @test all(Raster(gdalarray2) .== Raster(grdarray))
            @test val(dims(gdalarray2, Band)) == 1:3
        end

        @testset "write missing" begin
            A = replace_missing(grdarray, missing)
            filename = tempname() * ".grd"
            write(filename, A)
            @test missingval(Raster(filename)) === typemin(Float32)
            rm(filename)
        end

    end

    @testset "show" begin
        sh = sprint(show, MIME("text/plain"), grdarray)
        # Test but don't lock this down too much
        @test occursin("Raster", sh)
        @test occursin("Y", sh)
        @test occursin("X", sh)
        @test occursin("Band", sh)
    end

    @testset "plot" begin
        grdarray |> plot
        grdarray[Band(1)] |> plot
    end

end

@testset "Grd stack" begin
    grdstack = RasterStack((a=path, b=path))

    @test length(grdstack) == 2
    @test dims(grdstack) isa Tuple{<:X,<:Y,<:Band}

    @testset "read" begin
        st = read(grdstack)
        @test st isa RasterStack
        @test st.data isa NamedTuple
        @test first(st.data) isa Array
    end

    @testset "indexing" begin
        @test grdstack[:a][Y(20), X(20), Band(3)] == 70.0f0
        @test grdstack[:a][Y([2,3]), X(40), Band(2)] == [240.0f0, 246.0f0]
    end

    @testset "child array properties" begin
        @test size(grdstack[:a]) == size(Raster(grdstack[:a])) == (101, 77, 3)
        @test grdstack[:a] isa Raster{Float32,3}
    end

    # Stack Constructors
    @testset "conversion to RasterStack" begin
        geostack = RasterStack(grdstack)
        @test Symbol.(Tuple(keys(grdstack))) == keys(geostack)
        smallstack = RasterStack(grdstack; keys=(:a,))
        @test keys(smallstack) == (:a,)
    end

    if VERSION > v"1.1-"
        @testset "copy" begin
            geoA = zero(Raster(grdstack[:a]))
            copy!(geoA, grdstack, :a)
            # First wrap with Raster() here or == loads from disk for each cell.
            # we need a general way of avoiding this in all disk-based sources
            @test geoA == Raster(grdstack[:a])
        end
    end

    @testset "write" begin
        geoA = Raster(grdstack[:b])
        filename = tempname() * ".grd"
        write(filename, grdstack)
        base, ext = splitext(filename)
        filename_b = string(base, "_b", ext)
        saved = read(Raster(filename_b))
        @test typeof(read(geoA)) == typeof(saved)
        @test parent(saved) == parent(geoA)
    end

    @testset "show" begin
        sh = sprint(show, MIME("text/plain"), grdstack)
        # Test but don't lock this down too much
        @test occursin("RasterStack", sh)
        @test occursin("Y", sh)
        @test occursin("X", sh)
        @test occursin("Band", sh)
        @test occursin(":a", sh)
        @test occursin(":b", sh)
    end

end


@testset "Grd Band stack" begin
    grdstack = RasterStack(path)

    @test length(grdstack) == 3
    @test dims(grdstack) isa Tuple{<:X,<:Y}

    @testset "read" begin
        st = read(grdstack)
        @test st isa RasterStack
        @test st.data isa NamedTuple
        @test first(st.data) isa Array
    end

    @testset "indexing" begin
        @test grdstack[:Band_3][Y(20), X(20)] == 70.0f0
        @test grdstack[:Band_2][Y([2,3]), X(40)] == [240.0f0, 246.0f0]
    end

    @testset "child array properties" begin
        @test size(grdstack[:Band_3]) == size(Raster(grdstack[:Band_3])) == (101, 77)
        @test grdstack[:Band_1] isa Raster{Float32,2}
    end

    # Stack Constructors
    @testset "conversion to RasterStack" begin
        geostack = RasterStack(grdstack)
        @test Symbol.(Tuple(keys(grdstack))) == keys(geostack)
        smallstack = RasterStack(grdstack; keys=(:Band_2,))
        @test keys(smallstack) == (:Band_2,)
    end

    if VERSION > v"1.1-"
        @testset "copy" begin
            geoA = zero(Raster(grdstack[:Band_3]))
            copy!(geoA, grdstack, :Band_3)
            # First wrap with Raster() here or == loads from disk for each cell.
            # we need a general way of avoiding this in all disk-based sources
            @test geoA == Raster(grdstack[:Band_3])
        end
    end

    @testset "save" begin
        geoA = Raster(grdstack[:Band_3])
        filename = tempname() * ".grd"
        write(filename, grdstack)
        base, ext = splitext(filename)
        filename_3 = string(base, "_Band_3", ext)
        saved = read(Raster(filename_3))
        @test typeof(rebuild(saved[Band(1)], refdims=())) == typeof(read(geoA))
        @test parent(saved[Band(1)]) == parent(geoA)
    end

    @testset "show" begin
        sh = sprint(show, MIME("text/plain"), grdstack)
        # Test but don't lock this down too much
        @test occursin("RasterStack", sh)
        @test occursin("Y", sh)
        @test occursin("X", sh)
        @test occursin(":Band_1", sh)
        @test occursin(":Band_2", sh)
        @test occursin(":Band_3", sh)
    end

end

@testset "Grd series" begin
    grdseries = RasterSeries([path, path], (Ti,); mappedcrs=EPSG(4326))
    @test grdseries[Ti(1)] == Raster(path; mappedcrs=EPSG(4326))
    stacks = [RasterStack((a=path, b=path); mappedcrs=EPSG(4326))]

    grdseries2 = RasterSeries(stacks, (Ti,))
    @test all(grdseries2[Ti(1)][:a] .== Raster(path; mappedcrs=EPSG(4326), name=:test))
    modified_ser = modify(x -> Array(1.0f0x), grdseries2)
    @test typeof(modified_ser) <: RasterSeries{<:RasterStack{<:NamedTuple{(:a,:b),<:Tuple{<:Array{Float32,3},Vararg}}},1}

    @testset "read" begin
        geoseries = read(grdseries2)
        @test geoseries isa RasterSeries{<:RasterStack}
        @test geoseries.data isa Vector{<:RasterStack}
        @test geoseries.data isa Vector{<:RasterStack}
        @test first(geoseries.data[1].data) isa Array 
    end
end


nothing
