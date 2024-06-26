
_check_hilbert(q1::QuantumOperator, q2::QuantumOperator) =
    if q1.hilbert != q2.hilbert
        throw(ErrorException("Hilbert spaces are different"))
    end

_get_dense_similar(A::AbstractArray, args...) = similar(A, args...)
_get_dense_similar(A::AbstractSparseMatrix, args...) = similar(nonzeros(A), args...)

function _lmul_dict!(α::Number, dict::DT) where {KT,MT<:AbstractMatrix,DT<:Dict{KT,MT}}
    iszero(α) && (empty!(dict); return dict)

    for mat in values(dict)
        rmul!(mat, α)
    end

    return dict
end

function _change_matrix_type(::Type{M}, ::Type{T}) where {M<:AbstractMatrix,T}
    par = M.parameters
    npar = length(par)
    (2 ≤ npar ≤ 3) || error("Type $M is not supported.")
    if npar == 2
        S = M.name.wrapper{T,par[2]}
    else
        S = M.name.wrapper{T,par[2],par[3]}
    end
    return S
end

function _change_matrix_type(::Type{M}, ::Type{T}) where {M<:AbstractSparseMatrix,T}
    par = M.parameters
    npar = length(par)
    (npar == 2) || error("Type $M is not supported.")
    S = M.name.wrapper{T,par[2]}
    return S
end

function _convert_dict(dict::DT, ::Type{T}) where {KT,MT<:AbstractMatrix,DT<:Dict{KT,MT},T}
    MT_new = _change_matrix_type(MT, T)
    return Dict{KT,MT_new}(key => copy(convert(MT_new, value)) for (key, value) in dict)
end

_promote_quantum_operator(q::QuantumOperator, α::T) where {T<:Number} = _promote_quantum_operator(q, T)

function _promote_quantum_operator(
    q::QuantumOperator{HT,DT,CRT},
    T1::Type{<:Number},
) where {HT<:Hilbert,T2<:Number,KT,MT<:AbstractMatrix,DT<:Dict{KT,MT},CT<:T2,CRT<:Ref{CT}}
    T3 = eltype(MT)
    T = promote_type(T1, T2, T3)

    dict = _convert_dict(q.dict, T)

    constant = T(q.constant[])

    return QuantumOperator(q.hilbert, dict, constant)
end

function _permute_kron(hilbert, acting_on, mat)
    issorted(acting_on) && return acting_on, mat

    n = size(mat, 1)
    perm = sortperm(acting_on)
    sizes = collect(hilbert.dims[acting_on])

    mat = reshape(mat, reverse!(repeat(sizes, 2))...)
    to_permute = 2 * length(perm) + 1 .- vcat(perm, perm .+ length(perm))
    reverse!(to_permute)
    mat = PermutedDimsArray(mat, to_permute)
    mat = reshape(mat, n, n)

    # We need to copy since the reshape and the PermutedDimsArray return a view
    return acting_on[perm], copy(mat)
end

function _multiply_keys_values(
    hilbert::Hilbert,
    key1::KT1,
    value1::VT1,
    key2::KT2,
    value2::VT2,
) where {KT1<:AbstractVector,KT2<:AbstractVector,VT1<:AbstractMatrix,VT2<:AbstractMatrix}
    key1 == key2 && return Dict(key1 => value1 * value2)

    if length(intersect(key1, key2)) == 0
        acting_on, mat_product = _permute_kron(hilbert, vcat(key1, key2), kron(value1, value2))

        return Dict(acting_on => mat_product)
    end

    acting_on = sort!(union(key1, key2))
    acting_on1 = copy(key1)
    acting_on2 = copy(key2)
    mat1 = copy(value1)
    mat2 = copy(value2)

    @inbounds for i in eachindex(acting_on)
        if !(acting_on[i] in key1)
            Id = I(hilbert.dims[acting_on[i]])
            if acting_on[i] < first(acting_on1)
                mat1 = kron(Id, mat1)
                insert!(acting_on1, 1, acting_on[i])
            else
                mat1 = kron(mat1, Id)
                push!(acting_on1, acting_on[i])
            end
        end

        if !(acting_on[i] in key2)
            Id = I(hilbert.dims[acting_on[i]])
            if acting_on[i] < first(acting_on2)
                mat2 = kron(Id, mat2)
                insert!(acting_on2, 1, acting_on[i])
            else
                mat2 = kron(mat2, Id)
                push!(acting_on2, acting_on[i])
            end
        end
    end

    acting_on1, mat1 = _permute_kron(hilbert, acting_on1, mat1)
    acting_on2, mat2 = _permute_kron(hilbert, acting_on2, mat2)

    acting_on1 == acting_on2 || throw(ArgumentError("The acting_on should be the same"))

    return Dict(acting_on1 => mat1 * mat2)
end

function _max_nonzeros_per_row(mat)
    rows, cols, vals = findnz(mat)

    # The line below is not supported on GPU arrays
    # return mapreduce(i -> count(j -> rows[j] == i && rows[j] != cols[j], eachindex(rows)), max, 1:size(mat, 1))

    # The line below is supported on GPU arrays
    # It allocates some memoty though
    # TODO: We can define a predefined cache to store the Bool values
    return mapreduce(i -> count(rows .== i .&& rows .!= cols), max, 1:size(mat, 1))
end
