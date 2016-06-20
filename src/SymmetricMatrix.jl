module SymmetricMatrix
using NullableArrays
using Iterators
using Tensors
import Base: trace, vec, vecnorm, +, -, *, .*, /, \, ./, size, transpose, convert

seg(i::Int, of::Int, limit::Int) =  (i-1)*of+1 : ((i*of <= limit) ? i*of : limit)

function issymetric{T <: AbstractFloat}(data::Array{T}, atol::Float64 = 1e-7)
  for i=2:ndims(data)
    (maximum(abs(unfold(data, 1)-unfold(data, i))) < atol) || throw(DimensionMismatch("array is not symmetric"))
  end
end
segsizetest(len::Int, segments::Int) = ((len%segments) <= (len÷segments)) || throw(DimensionMismatch("last segment len $len-segments*(len÷segments)) > segment len $(len÷segments)"))

function structfeatures{T <: AbstractFloat, S}(frame::NullableArrays.NullableArray{Array{T,S},S})
  fsize = size(frame, 1)
  all(collect(size(frame)) .== fsize) || throw(DimensionMismatch("frame not square"))
  not_nulls = !frame.isnull
  !any(map(x->!issorted(ind2sub(not_nulls, x)), find(not_nulls))) || throw(ArgumentError("underdiagonal block not null"))
  quote
    @nloops $S i x->x==$S ? 1:fsize : i_{x+1}:fsize begin
      @inbounds minimum(size($frame[i].value)) .== size($frame[i].value, 1) || throw(DimensionMismatch("[$i ] block not square"))
    end
  end
  for i=1:fsize
    @inbounds issymetric(frame[fill(i, S)...].value)
  end
end

immutable BoxStructure{T <: AbstractFloat, S}
    frame::NullableArrays.NullableArray{Array{T,S},S}
    sizesegment::Int
    function call{T, S}(::Type{BoxStructure}, frame::NullableArrays.NullableArray{Array{T,S},S})
        structfeatures(frame)
        new{T, S}(frame, size(frame[fill(1,S)...].value,1))
    end
end
#del T
function indices(N::Int, n::Int)
    ret = Array{Int}[]
    @eval begin
        @nloops $N i x -> (x==$N)? (1:$n): (i_{x+1}:$n) begin
            ind = @ntuple $N x -> i_{$N-x+1}
            @inbounds push!($ret, [ind...])
        end
    end
    ret
end

function convert{T <: AbstractFloat, N}(::Type{BoxStructure}, data::Array{T, N}, segments::Int = 2)
  issymetric(data)
  len = size(data,1)
  segsizetest(len, segments)
  (len%segments == 0)? () : segments += 1
  ret = NullableArray(Array{T, N}, fill(segments, N)...)
    ind = indices(N, segments)
    for writeind in ind
        readind = (map(k::Int -> seg(k, ceil(Int, len/segments), len), writeind)...)
        @inbounds ret[writeind...] = data[readind...]
    end
  BoxStructure(ret)
end

# function convert{T <: AbstractFloat, S <: AbstractFloat}(::Type{BoxStructure{T}}, bs::BoxStructure{S})
#   BoxStructure(convert(NullableArray{T}, bs.frame))
# end

function readsegments{T <: AbstractFloat}(i::Array{Int}, bs::BoxStructure{T})
  sortidx = sortperm(i)
  permutedims(bs.frame[i[sortidx]...].value, invperm(sortidx))
end

function size{T <: AbstractFloat}(bsdata::BoxStructure{T})
  segsize = bsdata.sizesegment
  numsegments = size(bsdata.frame, 1)
  numdata = segsize * (numsegments-1) + size(bsdata.frame[end].value, 1)
  segsize, numsegments, numdata
end

function testsize{T <: AbstractFloat}(bsdata::BoxStructure{T}...)
  for i = 2:size(bsdata,1)
    @inbounds size(bsdata[1]) == size(bsdata[i]) || throw(DimensionMismatch("dims of B1 $(size(bsdata[1])) must equal to dims of B$i $(size(bsdata[i]))"))
  end
end

function convert{T<:AbstractFloat, N}(::Type{Array}, bsdata::BoxStructure{T,N})
  s = size(bsdata)
  ret = zeros(T, fill(s[3], N)...)
    for i = 1:(s[2]^N)
        readind = ind2sub((fill(s[2], N)...), i)
        writeind = (map(k -> seg(readind[k], s[1], s[3]), 1:N)...)
        @inbounds ret[writeind...] = readsegments(collect(readind), bsdata)
      end
  ret
end

function operation{T<: AbstractFloat, N}(op::Function, bsdata::BoxStructure{T,N}...)
  n = size(bsdata, 1)
  (n > 1)? testsize(bsdata...):()
  ret = similar(bsdata[1].frame)
  ind = indices(N, size(bsdata[1].frame, 1))
  for i in ind
    @inbounds ret[i...] = op(map(k ->  bsdata[k].frame[i...].value, 1:n)...)
  end
  BoxStructure(ret)
end

function operation{T<: AbstractFloat, N}(op::Function, bsdata::BoxStructure{T,N}, a::Real)
  ret = similar(bsdata.frame)
  ind = indices(N, size(bsdata.frame, 1))
  for i in ind
    @inbounds ret[i...] = op(bsdata.frame[i...].value, a)
  end
  BoxStructure(ret)
end

function operation!{T<: AbstractFloat,N, S <: Real}(bsdata::BoxStructure{T,N}, op::Function, n::S)
      ind = indices(N, size(bsdata.frame, 1))
      for i in ind
        @inbounds bsdata.frame[i...] = op(bsdata.frame[i...].value, n)
      end
end

for op = (:+, :-, :.*, :./)
  @eval ($op){T <: AbstractFloat, N}(bsdata::BoxStructure{T, N}, bsdata1::BoxStructure{T, N}) = operation($op, bsdata, bsdata1)
end

for op = (:+, :-, :*, :/)
  @eval ($op){T <: AbstractFloat, S <: Real}(bsdata::BoxStructure{T}, n::S)  = operation($op, bsdata, n)
end

add{T <: AbstractFloat, S <: Real}(bsdata::BoxStructure{T}, n::S)  = operation!(bsdata, +, n)

trace{T <: AbstractFloat}(bsdata::BoxStructure{T, 2}) = mapreduce(i -> trace(bsdata.frame[i,i].value), +, 1:size(bsdata)[2])
vec{T <: AbstractFloat}(bsdata::BoxStructure{T}) = Base.vec(convert(Array, bsdata))
vecnorm{T <: AbstractFloat}(bsdata::BoxStructure{T, 2}) = norm(vec(bsdata))

segmentmult{T <: AbstractFloat}(k1::Int, k2::Int, bsdata::BoxStructure{T, 2}) =
mapreduce(i -> readsegments([k1,i], bsdata)*readsegments([i,k2], bsdata), +, 1:size(bsdata.frame, 1))
segmentmult{T <: AbstractFloat}(k1::Int, k2::Int, bsdata::BoxStructure{T, 2}, bsdata1::BoxStructure{T, 2}) =
mapreduce(i -> readsegments([k1,i], bsdata)*readsegments([i,k2], bsdata1), +, 1:size(bsdata.frame, 1))

function generateperm(i::Int, ar::Array{Int})
    ret = ar
    ret[i], ret[1] = ar[1], ar[i]
    ret
end


function square{T <: AbstractFloat}(bsdata::BoxStructure{T, 2})
    s = size(bsdata)
    ret = NullableArray(Matrix{T}, size(bsdata.frame))
    for i = 1:s[2], j = i:s[2]
        @inbounds ret[i,j] = segmentmult(i,j, bsdata)
    end
    BoxStructure(ret)
end

function *{T <: AbstractFloat}(bsdata::BoxStructure{T, 2}, bsdata1::BoxStructure{T, 2})
    s = size(bsdata)
    s == size(bsdata1) || throw(DimensionMismatch("dims of B1 $(size(bsdata)) must equal to dims of B2 $(size(bsdata1))"))
    ret = zeros(T, s[3], s[3])
    for i = 1:s[2], j = 1:s[2]
        @inbounds ret[seg(i, s[1], s[3]), seg(j, s[1], s[3])] = segmentmult(i,j, bsdata, bsdata1)
    end
    ret
end

function segmentmult{T <: AbstractFloat}(i::Int, j::Int, bsdata::BoxStructure{T, 2}, m::Array{T, 2})
  s = size(bsdata)
  mapreduce(k -> readsegments([i,k], bsdata)*(m[seg(k, s[1], size(m ,1)),seg(j, s[1], size(m ,2))]), +, 1:s[2])
end

function segmentmult{T <: AbstractFloat, N}(k::Array{Int, 1}, bsdata::BoxStructure{T, N}, m::Array{T, 2}, mode::Int = 1)
  s = size(bsdata)
  mapreduce(i -> Tensors.modemult(readsegments([i, k[2:end]...], bsdata),
  m[seg(k[1], s[1], size(m ,1)),seg(i, s[1], size(m ,2))], mode), +, 1:s[2])
end

function *{T <: AbstractFloat}(bsdata::BoxStructure{T, 2}, mat::Matrix{T})
    s = size(bsdata)
    s[3] == size(mat,1) || throw(DimensionMismatch("size of B1 $(s[3]) must equal to size of A $(size(mat,1))"))
    ret = similar(mat)
    for i = 1:s[2], j = 1:ceil(Int, size(mat, 2)/s[1])
        @inbounds ret[seg(i, s[1], size(mat,1)), seg(j, s[1], size(mat,2))] = segmentmult(i,j, bsdata, mat)
    end
    ret
end

function modemult{T <: AbstractFloat, N}(bsdata::BoxStructure{T, N}, mat::Matrix{T}, mode::Int)
    s = size(bsdata)
    s[3] == size(mat,2) || throw(DimensionMismatch("size of B1 $(s[3]) must equal to size of A $(size(mat,1))"))
    ret = zeros(T, size(mat,1), fill(s[3], N-1)...)
    matseg = ceil(Int, size(mat, 1)/s[1])
    for i = 1:(s[2]^(N-1)*matseg)
        readind = ind2sub((matseg, fill(s[2], N-1)...), i)
        writeind = (map(k -> seg(readind[k], s[1], size(ret,k)), 1:N)...)
        @inbounds ret[writeind...] = segmentmult([readind...], bsdata, mat)
    end
    permutedims(ret, generateperm(mode, collect(1:N)))
end
#covariance

function covbs{T <: AbstractFloat}(data::Matrix{T}, segments::Int = 2, corrected::Bool = false)
    len = size(data,2)
    segsizetest(len, segments)
    (len%segments == 0)? () : segments += 1
    ret = NullableArray(Matrix{T}, segments, segments)
    segsize = ceil(Int, len/segments)
    for i = 1:segments, j = i:segments
        @inbounds ret[i,j] = cov(data[:,seg(i, segsize, len)], data[:,seg(j, segsize, len)], corrected = corrected)
    end
    BoxStructure(ret)
end

#bcss 2d functions

function segmentmult{T <: AbstractFloat}(k::Int, m::Array{T, 2}, v::Array{Array{T, 2}})
  s = size(v[1], 1)
  mapreduce(i -> transpose(m[seg(i, s, size(m ,1)), seg(k, s, size(m ,2))])*(v[i]), +, 1:size(v , 1))
end

function bcss{T <: AbstractFloat}(bsdata::BoxStructure{T, 2}, m::Matrix{T})
    s = size(bsdata)
    s[3]  == size(m,1)||throw(DimensionMismatch("size of B1 $(s[3]) must equal to size of A $(size(m,1))"))
    segments = ceil(Int, size(m, 2)/s[1])
    ret = NullableArray(Array{T, 2}, segments, segments)
    for i = 1:segments
      temp = Array(Array{T, 2}, s[2])
      for k = 1:s[2]
          @inbounds temp[k] = segmentmult(k,i, bsdata, m)
      end
      for j = 1:i
	       @inbounds ret[j,i] = segmentmult(j, m, temp)
      end
   end
   BoxStructure(ret)
end

function bcsscel{T <: AbstractFloat, N}(bsdata::BoxStructure{T, N}, v::Array{T}...)
    ret = modemult(bsdata, v[1], N)
    for j = 2:N
        @inbounds ret = Tensors.modemult(ret, v[j], N-j+1)
    end
    ret[1]
end

function bcsseg{T <: AbstractFloat, N}(bsdata::BoxStructure{T, N}, r::Array{T, 2}...)
    dims = [map(i -> size(r[i], 1), 1:N)...]
    ret = zeros(T, dims...)
    for i = 1:mapreduce(k -> dims[k], *, 1:N)
        ind = ind2sub((dims...), i)
        @inbounds ret[ind...] = bcsscel(bsdata, map(k -> r[k][ind[k],:], 1:N)...)
    end
    ret
end

function bcssclass{T <: AbstractFloat, N}(bsdata::BoxStructure{T, N}, m::Matrix{T}, segments::Int = 2)
    len = size(m,1)
    segsizetest(len, segments)
    (len%segments == 0)? () : segments += 1
    ret = NullableArray(Array{T, N}, fill(segments, N)...)
    segsize = ceil(Int, len/segments)
    ind = indices(N, segments)
    for i in ind
        @inbounds ret[i...] = bcsseg(bsdata, map(k -> m[seg(i[k], segsize, len),:], 1:N)...)
    end
    BoxStructure(ret)
end

# moments

function centre{T<:AbstractFloat}(data::Matrix{T})
    centred = zeros(data)
    n = size(data, 2)
    for i = 1:n
        centred[:,i] = data[:,i]-mean(data[:,i])
    end
    centred
end

momentel{T <: AbstractFloat}(v::Array{T}...) = mean(mapreduce(i -> v[i], .*, 1:size(v,1)))

function momentseg{T <: AbstractFloat}(r::Array{T, 2}...)
    N = size(r, 1)
    dims = [map(i -> size(r[i], 2), 1:N)...]
    ret = zeros(T, dims...)
    for i = 1:mapreduce(k -> dims[k], *, 1:N)
        ind = ind2sub((dims...), i)
        ret[ind...] = momentel(map(k -> r[k][:,ind[k]], 1:N)...)
    end
    ret
end

function momentbc{T <: AbstractFloat}(m::Matrix{T}, N::Int, segments::Int = 2)
    len = size(m,2)
    segsizetest(len, segments)
    (len%segments == 0)? () : segments += 1
    ret = NullableArray(Array{T, N}, fill(segments, N)...)
    segsize = ceil(Int, len/segments)
    ind = indices(N, segments)
    for i in ind
        ret[i...] = momentseg(map(k -> m[:,seg(i[k], segsize, len)], 1:N)...)
    end
    BoxStructure(ret)
end

#cumulants


function imputbs(pe::Array{Array{Int,1},1}, ls::Array{Int, 1})
    ret = []
    for p in pe
        push!(ret, findfirst(ls, size(p, 1)))
    end
    ret
end

function productseg{T <: AbstractFloat}(part::Array, k::Int, c::Array{T}...)
    N = cumsum(part)[end]
    s = size(c[1], 1)
    ret = zeros(T, fill(s, N)...)
    for i = 1:(s^N)
        ind = ind2sub((fill(s, N)...), i)
        pe = permuteind([ind...], part, k)
        ret[ind...] = mapreduce(i -> c[i][pe[i]...], *, 1:size(part, 1))
    end
        ret
end

function permuteind(ind::Array{Int}, s::Array{Int}, i::Int)
    ret = []
    k = 1
    for p in partitions(ind, size(s,1))
        if (mapreduce(i -> (size(p[i], 1) in s), *, 1:size(s,1)))
            (k == i)? (return p): ()
            k += 1
        end
    end
    [0,0]
end

function comb(a::Array{Int})
    issorted(a) || throw(ArgumentError("list not sorted"))
    thesame = mapreduce(i -> factorial(findlast(a, i)-findfirst(a, i)+1), *, 2:maximum(a))
    div(factorial(cumsum(a)[end]), mapreduce(i -> factorial(a[i]), *, 1:size(a,1))*thesame)
end

function pbc{T <: AbstractFloat}(part::Array, bscum::BoxStructure{T}...)
    ls = map(i -> ndims(bscum[i].frame), 1:size(bscum, 1))
    N = cumsum(part)[end]
    s = size(bscum[1])
    n = size(part, 1)
    m = comb(part)
    ret = NullableArray(Array{T, N}, fill(s[2], N)...)
    ind = indices(N, s[2])           
    for i in ind
        temp = zeros(T, fill(s[1], N)...)
        for k = 1:m
            pe = permuteind([i...], part, k)
            inn = imputbs(pe, ls)
            temp += productseg(part, k, map(i -> bscum[inn[i]].frame[pe[i]...].value, 1:size(part, 1))...)
        end
        ret[i...] = temp
    end
    BoxStructure(ret)
end

cumulant2{T <: AbstractFloat}(m::Matrix{T}, segments::Int = 2) = momentbc(m, 2, segments)
cumulant3{T <: AbstractFloat}(m::Matrix{T}, segments::Int = 2) = momentbc(m, 3, segments)
cumulant4{T <: AbstractFloat}(m::Matrix{T}, c2::BoxStructure{T, 2}, segments::Int = 2) = momentbc(m, 4, segments) - pbc([2,2], c2)
cumulant5{T <: AbstractFloat}(m::Matrix{T}, c2::BoxStructure{T}, c3::BoxStructure{T}, segments::Int = 2) = momentbc(m, 5, segments) - pbc([2,3], c2, c3)
cumulant6{T <: AbstractFloat}(m::Matrix{T}, c2::BoxStructure{T}, c3::BoxStructure{T}, c4::BoxStructure{T}, segments::Int = 2) = momentbc(m, 6, segments) - pbc([2,2,2], c2) - pbc([2,4], c2, c4) - pbc([3,3], c3)

function cumulants{T <: AbstractFloat}(data::Matrix{T}, seg::Int = 2)
    c2 = cumulant2(data, seg)
    c3 = cumulant3(data, seg)
    c4 = cumulant4(data, c2, seg);
    c5 = cumulant5(data, c2, c3, seg);
    c6 = cumulant6(data, c2, c3, c4, seg);
    c2, c3, c4, c5, c6
end

export BoxStructure, convert, +, -, *, /, add, trace, vec, vecnorm, covbs, modemult, square, bcss,
bcssclass, indices, momentbc, centre, cumulants
end
