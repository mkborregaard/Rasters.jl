# Rasters

[![](https://img.shields.io/badge/docs-stable-blue.svg)](https://rafaqz.github.io/Rasters.jl/stable)
[![](https://img.shields.io/badge/docs-dev-blue.svg)](https://rafaqz.github.io/Rasters.jl/dev)
[![CI](https://github.com/rafaqz/Rasters.jl/actions/workflows/ci.yml/badge.svg)](https://github.com/rafaqz/Rasters.jl/actions/workflows/ci.yml)
[![Codecov](https://codecov.io/gh/rafaqz/Rasters.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/rafaqz/Rasters.jl)
[![Aqua.jl Quality Assurance](https://img.shields.io/badge/Aquajl-%F0%9F%8C%A2-aqua.svg)](https://github.com/JuliaTesting/Aqua.jl)

Rasters.jl defines common types and methods for reading, writing and
manipulating rasterized spatial data. 

These currently include raster arrays like GeoTIFF and NetCDF, R grd files, 
multi-layered stacks, and multi-file series of arrays and stacks. 

![EarthEnv HabitatHeterogeneity layers trimmed to Australia](https://rafaqz.github.io/Rasters.jl/stable/trim_example_after.png)

_A RasterStack of EarthEnv HabitatHeterogeneity layers, trimmed to Australia and plotted with Plots.jl_


## Lazyness

- Data is loaded lazily wherever possible using
  [DiskArrays.jl](https://github.com/meggart/DiskArrays.jl). Indexing a
  `RasterStack` by name is always lazy, while `view` of a `Raster` is lazy and
  `getindex` will load to memory. `read` can be used on any object to ensure
  that all data is loaded to memory.
- Broadcast over disk-based objects is lazy - it will only run when the array is
  indexed. Always prefer broadcasts to explicit loops - these can be very slow
  with disk-based data.

## Data-source abstraction

Rasters provides a standardised interface that allows many source data types to
be used with identical syntax.

- Scripts and packages building on Rasters.jl can treat `AbstractRaster`,
  `AbstractRasterStack`, and `AbstrackRasterSeries` as black boxes.
  - The data could hold GeoTiff or NetCDF files, `Array`s in memory or
    `CuArray`s on the GPU - they will all behave in the same way.
  - `RasterStack` can be backed by a Netcdf or HDF5 file, or a `NamedTuple` of
    `Raster` holding `.tif` files, or all `Raster` in memory.
  - Users do not have to deal with the specifics of spatial file types.
- `Projected` lookups can by indexed with any projection by setting the
  `mappedcrs` keyword on construction. You don't need to know the underlying
  projection, the conversion is handled automatically. This means lat/lon
  `EPSG(4326)` can be used across all sources seamlessly if you need that.
- Regions and points selected with `Between` and `Contains` select the right
  point or whole interval no matter the order of the index or it's position in
  the cell.

## Named dimensions and index lookups

Rasters.jl extends
[DimensionalData.jl](https://github.com/rafaqz/DimensionalData.jl) so that
spatial data can be indexed using named dimensions like `X`, `Y` and `Ti` (time)
and e.g. spatial coordinates.

Dimensions can also be used in most `Base` and `Statistics` methods like `mean`
and `reduce` where `dims` arguments are required. Much of the behaviour is
covered in the [DimensionalData
docs](https://rafaqz.github.io/DimensionalData.jl/stable/).

See [the docs](https://rafaqz.github.io/Rasters.jl/stable) for more details and
examples for Rasters.jl.
