module LibDeflate

using libdeflate_jll

# Error message strings.
const BAD_HEADER = "Bad header"
const UNTERMINATED_NULL_STRING = "Unterminated null string"
const HEADER_CRC16_CHECKSUM_DOES_NOT_MATCH = "Header CRC16 checksum does not match"
const PAYLOAD_CRC132_CHECKSUM_DOES_NOT_MATCH = "Payload CRC132 checksum does not match"
const OUTPUT_DATA_TOO_LONG = "Output data too long"
const INPUT_DATA_TOO_SHORT = "Input data too short"
const EXTRA_DATA_TOO_LONG = "Extra data too long"
const EXTRA_DATA_INVALID = "Extra data invalid"
const OUTPUT_BUFFER_TOO_SMALL = "Output buffer too small"

# Must be mutable for the GC to be able to interact with it
"""
    Decompressor()

Create an object which can decompress using the DEFLATE algorithm.
The same decompressor cannot be used by multiple threads at the same time.
To parallelize decompression, create multiple instances of `Decompressor`
and use one for each thread.

See also: [`decompress!`](@ref), [`unsafe_decompress!`](@ref)
"""
mutable struct Decompressor
    actual_nbytes_ret::UInt
    ptr::Ptr{Nothing}
end

Base.unsafe_convert(::Type{Ptr{Nothing}}, x::Decompressor) = x.ptr

function Decompressor()
    decompressor = Decompressor(0, ccall((:libdeflate_alloc_decompressor,
                   libdeflate), Ptr{Nothing}, ()))
    finalizer(free_decompressor, decompressor)
    return decompressor
end

function free_decompressor(decompressor::Decompressor)
    ccall((:libdeflate_free_decompressor, libdeflate),
           Nothing, (Ptr{Nothing},), decompressor)
    return nothing
end

"""
    Compressor(compresslevel::Int=6)

Create an object which can compress using the DEFLATE algorithm. `compresslevel`
can be from 1 (fast) to 12 (slow), and defaults to 6. The same compressor cannot
be used by multiple threads at the same time. To parallelize compression, create
multiple instances of `Compressor` and use one for each thread.

See also: [`compress!`](@ref), [`unsafe_compress!`](@ref)
"""
mutable struct Compressor
    level::Int
    ptr::Ptr{Nothing}
end

Base.unsafe_convert(::Type{Ptr{Nothing}}, x::Compressor) = x.ptr

function Compressor(compresslevel::Integer=6)
    compresslevel in 1:12 || throw(ArgumentError("Compresslevel must be in 1:12"))
    ptr = ccall((:libdeflate_alloc_compressor, libdeflate), Ptr{Nothing},
                (UInt,), compresslevel)
    compressor = Compressor(compresslevel, ptr)
    finalizer(free_compressor, compressor)
    return compressor
end

function free_compressor(compressor::Compressor)
    ccall((:libdeflate_free_compressor, libdeflate), Nothing, (Ptr{Nothing},), compressor)
    return nothing
end

# Compression and decompression functions
# Types and constants
const LIBDEFLATE_SUCCESS            = Cint(0)
const LIBDEFLATE_BAD_DATA           = Cint(1)
const LIBDEFLATE_SHORT_INPUT        = Cint(2)
const LIBDEFLATE_INSUFFICIENT_SPACE = Cint(3)

const BAD_DATA = "libdeflate 1: bad data"
const SHORT_INPUT = "libdeflate 2: short input"
const INSUFFICIENT_SPACE = "libdeflate 3: insufficient space"

"""
    LibDeflateError(message::String)

`LibDeflate` failed with `message`.
"""
struct LibDeflateError <: Exception
    msg::String
end

@noinline function check_return_code(code)
    iszero(code) && return nothing
    message = if code == LIBDEFLATE_BAD_DATA
        BAD_DATA
    elseif code == LIBDEFLATE_SHORT_INPUT
        SHORT_INPUT
    elseif code == LIBDEFLATE_INSUFFICIENT_SPACE
        INSUFFICIENT_SPACE
    end
    throw(LibDeflateError(message))
end

# Raw C call - do not export this
function _unsafe_decompress!(decompressor::Decompressor,
                             outptr::Ptr{UInt8}, outlen::Integer,
                             inptr::Ptr{UInt8}, inlen::Integer, nptr::Ptr)
    status = ccall((:libdeflate_deflate_decompress, libdeflate), UInt,
                  (Ptr{Nothing}, Ptr{UInt8}, UInt, Ptr{UInt8}, UInt, Ptr{UInt}),
                   decompressor, inptr, inlen, outptr, outlen, nptr)
    check_return_code(status)
    return nothing
end

"""
    unsafe_decompress!(s::IteratorSize, ::Decompressor, outptr, n_out, inptr, n_in)

Decompress `n_in` bytes from `inptr` to `outptr` using the DEFLATE algorithm,
returning the number of decompressed bytes.
`s` gives whether you know the decompressed size or not.

If `s` isa `Base.HasLength`, the number of decompressed bytes is given as `n_out`.
This is more efficient, but will fail if the number is not correct.

If `s` isa `Base.SizeUnknown`, pass the number of available space in the output
to `n_out`.

See also: [`decompress!`](@ref)
"""
function unsafe_decompress! end

function unsafe_decompress!(::Base.HasLength, decompressor::Decompressor,
                            outptr::Ptr{UInt8}, n_out::Integer,
                            inptr::Ptr{UInt8}, n_in::Integer)
    _unsafe_decompress!(decompressor, outptr, n_out, inptr, n_in, C_NULL)
    return n_out
end

function unsafe_decompress!(::Base.SizeUnknown, decompressor::Decompressor,
                            outptr::Ptr{UInt8}, n_out::Integer,
                            inptr::Ptr{UInt8}, n_in::Integer)
    GC.@preserve decompressor begin
        retptr = pointer_from_objref(decompressor)
        _unsafe_decompress!(decompressor, outptr, n_out, inptr, n_in, retptr)
    end
    return decompressor.actual_nbytes_ret % Int
end

"""
    decompress!(::Decompressor, outdata, indata, [n_out::Integer]) -> Int

Use the passed `Decompressor` to decompress the byte vector `indata` into the
first bytes of `outdata` using the DEFLATE algorithm.
If the decompressed size is known beforehand, pass it as `n_out`. This will increase
performance, but will fail if it is wrong.

Return the number of bytes written to `outdata`.
"""
function decompress! end

# Decompress method with length known (preferred)
function decompress!(decompressor::Decompressor,
                     outdata::Vector{UInt8}, indata::Vector{UInt8}, n_out::Integer)
    if length(outdata) < n_out
        throw(ValueError("n_out must be less than or equal to length of outdata"))
    end
    GC.@preserve outdata indata unsafe_decompress!(Base.HasLength(),
        decompressor, pointer(outdata), n_out, pointer(indata), length(indata))
end

# Decompress method with length unknown (not preferred)
function decompress!(decompressor::Decompressor,
                     outdata::Vector{UInt8}, indata::Vector{UInt8})
    GC.@preserve outdata indata unsafe_decompress!(Base.SizeUnknown(),
        decompressor, pointer(outdata), length(outdata), pointer(indata), length(indata))
end

"""
    unsafe_compress(::Compressor, outptr, n_out, inptr, n_in)

Use the passed `Compressor` to compress `n_in` bytes from the pointer `inptr`
to the pointer `n_out`. If the compressed size is larger than the available
space `n_out`, throw an error.

See also: [`compress!`](@ref)
"""
function unsafe_compress!(compressor::Compressor, outptr::Ptr{UInt8}, n_out::Integer,
                          inptr::Ptr{UInt8}, n_in::Integer)
    bytes = ccall((:libdeflate_deflate_compress, libdeflate), UInt,
            (Ptr{Nothing}, Ptr{UInt8}, UInt, Ptr{UInt8}, UInt),
            compressor, inptr, n_in, outptr, n_out)

    if iszero(bytes)
        throw(LibDeflateError(OUTPUT_BUFFER_TOO_SMALL))
    end
    return bytes % Int
end

"""
    compress!(::Compressor, outdata, indata) -> Int

Use the passed `Compressor` to compress the byte vector `indata` into the first
bytes of `outdata` using the DEFLATE algorithm.

The output must fit in `outdata`. Return the number of bytes written to `outdata`.
"""
function compress!(compressor::Compressor,
                   outdata::Vector{UInt8}, indata::Vector{UInt8})
    GC.@preserve outdata indata unsafe_compress!(compressor, pointer(outdata),
        length(outdata), pointer(indata), length(indata))
end

"""
    unsafe_crc32(inptr, n_in, start) -> UInt32

Calculate the crc32 checksum of the first `n_in` of the pointer `inptr`,
with seed `start` (default is 0).
Note that crc32 is a different and slower algorithm than the `crc32c` provided
in the Julia standard library.

See also: [`crc32`](@ref)
"""
function unsafe_crc32(inptr::Ptr{UInt8}, n_in::Integer, start::UInt32=UInt32(0))
    return ccall((:libdeflate_crc32, libdeflate),
               UInt32, (UInt, Ptr{UInt8}, UInt), start, inptr, n_in)
end

"""
    crc32(data, start=UInt32(0)) -> UInt32

Calculate the crc32 checksum of the byte vector `data` and seed `start`.
Note that crc32 is a different and slower algorithm than the `crc32c` provided
in the Julia standard library.
"""
function crc32(data::Vector{UInt8}, start::UInt32=UInt32(0))
    GC.@preserve data unsafe_crc32(pointer(data), length(data), start)
end

include("gzip.jl")

export Decompressor,
       Compressor,

       LibDeflateError,
       unsafe_decompress!,
       decompress!,
       unsafe_gzip_decompress!,
       gzip_decompress!,
       unsafe_compress!,
       compress!,
       unsafe_gzip_compress!,
       gzip_compress!,
       unsafe_crc32,
       crc32,

       unsafe_parse_gzip_header,
       is_valid_extra_data

end # module
