#include <cuda_runtime.h>
#include <pybind11/numpy.h>
#include <pybind11/pybind11.h>
#include <pybind11/stl.h>

#include <iostream>
#include <sstream>

namespace needle {
namespace cuda {

#define BASE_THREAD_NUM 256

#define TILE 4
typedef float scalar_t;
const size_t ELEM_SIZE = sizeof(scalar_t);
typedef ssize_t ptrdiff_t;

struct CudaArray {
  CudaArray(const size_t size) {
    cudaError_t err = cudaMalloc(&ptr, size * ELEM_SIZE);
    if (err != cudaSuccess)
      throw std::runtime_error(cudaGetErrorString(err));
    this->size = size;
  }
  ~CudaArray() { cudaFree(ptr); }
  size_t ptr_as_int() { return (size_t)ptr; }

  scalar_t* ptr;
  size_t size;
};

struct CudaDims {
  dim3 block, grid;
};

CudaDims CudaOneDim(size_t size) {
  /**
   * Utility function to get cuda dimensions for 1D call
   */
  CudaDims dim;
  size_t num_blocks = (size + BASE_THREAD_NUM - 1) / BASE_THREAD_NUM;
  dim.block = dim3(BASE_THREAD_NUM, 1, 1);
  dim.grid = dim3(num_blocks, 1, 1);
  return dim;
}

#define MAX_VEC_SIZE 8
struct CudaVec {
  uint32_t size;
  int32_t data[MAX_VEC_SIZE];
};

CudaVec VecToCuda(const std::vector<int32_t>& x) {
  CudaVec shape;
  if (x.size() > MAX_VEC_SIZE)
    throw std::runtime_error("Exceeded CUDA supported max dimesions");
  shape.size = x.size();
  for (size_t i = 0; i < x.size(); i++) {
    shape.data[i] = x[i];
  }
  return shape;
}

////////////////////////////////////////////////////////////////////////////////
// Fill call
////////////////////////////////////////////////////////////////////////////////

__global__ void FillKernel(scalar_t* out, scalar_t val, size_t size) {
  size_t gid = blockIdx.x * blockDim.x + threadIdx.x;
  if (gid < size)
    out[gid] = val;
}

void Fill(CudaArray* out, scalar_t val) {
  CudaDims dim = CudaOneDim(out->size);
  FillKernel<<<dim.grid, dim.block>>>(out->ptr, val, out->size);
}

////////////////////////////////////////////////////////////////////////////////
// Compact and setitem cals
////////////////////////////////////////////////////////////////////////////////

// Untility function to convert contiguous index i to memory location from
// strides

__device__ int32_t GetOffset(int32_t gid, const CudaVec& shape,
                              const CudaVec& strides,
                              int32_t init_offset = 0) {
  int32_t idx = init_offset;

  for (int i = shape.size - 1; i >= 0; --i) {
    idx += strides.data[i] * (gid % shape.data[i]);
    gid /= shape.data[i];
  }

  return idx;
}

__global__ void CompactKernel(const scalar_t* a, scalar_t* out, size_t size,
                              CudaVec shape, CudaVec strides, size_t offset) {
  /**
   * The CUDA kernel for the compact opeation.  This should effectively map a
   * single entry in the non-compact input a, to the corresponding item (at
   * location gid) in the compact array out.
   *
   * Args:
   *   a: CUDA pointer to a array
   *   out: CUDA point to out array
   *   size: size of out array
   *   shape: vector of shapes of a and out arrays (of type CudaVec, for past 
   * passing to CUDA kernel) 
   *   strides: vector of strides of out array 
   *   offset: offset of a array
   */
  size_t gid = blockIdx.x * blockDim.x + threadIdx.x;
  if (gid < size) {
    out[gid] = a[GetOffset(static_cast<int32_t>(gid), shape, strides, offset)];
  }
}

void Compact(const CudaArray& a, CudaArray* out, std::vector<int32_t> shape,
             std::vector<int32_t> strides, size_t offset) {
  /**
   * Compact an array in memory.  Unlike the C++ version, in CUDA this will
   * primarily call the relevant CUDA kernel.  In this case, we illustrate how
   * you should set this up (i.e., we give you the code for this fuction, and
   * also the prototype for the CompactKernel() function).  For the functions
   * after this, however, you'll need to define these kernels as you see fit to
   * execute the underlying function.
   *
   * Args:
   *   a: non-compact represntation of the array, given as input
   *   out: compact version of the array to be written
   *   shape: shapes of each dimension for a and out
   *   strides: strides of the *a* array (not out, which has compact strides)
   *   offset: offset of the *a* array (not out, which has zero offset, being
   * compact)
   */

  // Nothing needs to be added here
  CudaDims dim = CudaOneDim(out->size);
  CompactKernel<<<dim.grid, dim.block>>>(
      a.ptr, out->ptr, out->size, VecToCuda(shape), VecToCuda(strides), offset);
}

__global__ void EwiseSetitemKernel(const scalar_t* a, scalar_t* out,
                                   size_t size, CudaVec shape, CudaVec strides,
                                   size_t offset) {
  size_t gid = blockIdx.x * blockDim.x + threadIdx.x;
  if (gid < size) {
    out[GetOffset(static_cast<int32_t>(gid), shape, strides, offset)] = a[gid];
  }
}

void EwiseSetitem(const CudaArray& a, CudaArray* out,
                  std::vector<int32_t> shape, std::vector<int32_t> strides,
                  size_t offset) {
  /**
   * Set items in a (non-compact) array using CUDA.  Yyou will most likely want
   * to implement a EwiseSetitemKernel() function, similar to those above, that
   * will do the actual work.
   *
   * Args:
   *   a: _compact_ array whose items will be written to out
   *   out: non-compact array whose items are to be written
   *   shape: shapes of each dimension for a and out
   *   strides: strides of the *out* array (not a, which has compact strides)
   *   offset: offset of the *out* array (not a, which has zero offset, being
   * compact)
   */
  CudaDims dim = CudaOneDim(a.size);
  EwiseSetitemKernel<<<dim.grid, dim.block>>>(
      a.ptr, out->ptr, a.size, VecToCuda(shape), VecToCuda(strides), offset);
}

__global__ void ScalarSetitemKernel(scalar_t val, scalar_t* out, size_t size,
                                    CudaVec shape, CudaVec strides,
                                    size_t offset) {
  size_t gid = blockIdx.x * blockDim.x + threadIdx.x;
  if (gid < size) {
    out[GetOffset(static_cast<int32_t>(gid), shape, strides, offset)] = val;
  }
}

void ScalarSetitem(size_t size, scalar_t val, CudaArray* out,
                   std::vector<int32_t> shape, std::vector<int32_t> strides,
                   size_t offset) {
  /**
   * Set items is a (non-compact) array
   *
   * Args:
   *   size: number of elements to write in out array (note that this will note
   * be the same as out.size, because out is a non-compact subset array);  it
   * _will_ be the same as the product of items in shape, but covenient to just
   * pass it here. 
   *   val: scalar value to write to 
   *   out: non-compact array whose tems are to be written
   *   shape: shapes of each dimension of out 
   *   strides: strides of the out array 
   *   offset: offset of the out array
   */
  CudaDims dim = CudaOneDim(size);
  ScalarSetitemKernel<<<dim.grid, dim.block>>>(
      val, out->ptr, size, VecToCuda(shape), VecToCuda(strides), offset);
}

////////////////////////////////////////////////////////////////////////////////
// Elementwise and scalar operations
////////////////////////////////////////////////////////////////////////////////

/**
 * In the code the follows, use the above template to create analogous
 * elementise and and scalar operators for the following functions.  See the
 * numpy backend for examples of how they should work.
 *   - EwiseMul, ScalarMul
 *   - EwiseDiv, ScalarDiv
 *   - ScalarPower
 *   - EwiseMaximum, ScalarMaximum
 *   - EwiseEq, ScalarEq
 *   - EwiseGe, ScalarGe
 *   - EwiseLog
 *   - EwiseExp
 *   - EwiseTanh
 *
 * If you implement all these naively, there will be a lot of repeated code, so
 * you are welcome (but not required), to use macros or templates to define
 * these functions (however you want to do so, as long as the functions match
 * the proper) signatures above.
 */

enum class EwiseOp { add, mul, div, maximum, eq, ge };

enum class ScalarOp {
  add_scalar,
  mul_scalar,
  div_scalar,
  maximum_scalar,
  eq_scalar,
  ge_scalar,
  power_scalar
};

enum class EwiseUnitOp { log, exp, tanh };

__global__ void EwiseAddKernel(const scalar_t* a, const scalar_t* b,
                               scalar_t* out, size_t size) {
  size_t gid = blockIdx.x * blockDim.x + threadIdx.x;
  if (gid < size)
    out[gid] = a[gid] + b[gid];
}

__global__ void ScalarAddKernel(const scalar_t* a, scalar_t val, scalar_t* out,
                                size_t size) {
  size_t gid = blockIdx.x * blockDim.x + threadIdx.x;
  if (gid < size)
    out[gid] = a[gid] + val;
}

__global__ void EwiseMulKernel(const scalar_t* a, const scalar_t* b,
                               scalar_t* out, size_t size) {
  size_t gid = blockIdx.x * blockDim.x + threadIdx.x;
  if (gid < size)
    out[gid] = a[gid] * b[gid];
}

__global__ void ScalarMulKernel(const scalar_t* a, scalar_t val, scalar_t* out,
                                size_t size) {
  size_t gid = blockIdx.x * blockDim.x + threadIdx.x;
  if (gid < size)
    out[gid] = a[gid] * val;
}

__global__ void EwiseDivKernel(const scalar_t* a, const scalar_t* b,
                               scalar_t* out, size_t size) {
  size_t gid = blockIdx.x * blockDim.x + threadIdx.x;
  if (gid < size)
    out[gid] = a[gid] / b[gid];
}

__global__ void ScalarDivKernel(const scalar_t* a, scalar_t val, scalar_t* out,
                                size_t size) {
  size_t gid = blockIdx.x * blockDim.x + threadIdx.x;
  if (gid < size)
    out[gid] = a[gid] / val;
}

__global__ void EwiseMaximumKernel(const scalar_t* a, const scalar_t* b,
                                   scalar_t* out, size_t size) {
  size_t gid = blockIdx.x * blockDim.x + threadIdx.x;
  if (gid < size)
    out[gid] = (a[gid] < b[gid]) ? b[gid] : a[gid];
}

__global__ void ScalarMaximumKernel(const scalar_t* a, scalar_t val,
                                    scalar_t* out, size_t size) {
  size_t gid = blockIdx.x * blockDim.x + threadIdx.x;
  if (gid < size)
    out[gid] = max(a[gid], val);
}

__global__ void EwiseEqKernel(const scalar_t* a, const scalar_t* b,
                              scalar_t* out, size_t size) {
  size_t gid = blockIdx.x * blockDim.x + threadIdx.x;
  if (gid < size)
    out[gid] = a[gid] == b[gid];
}

__global__ void ScalarEqKernel(const scalar_t* a, scalar_t val, scalar_t* out,
                               size_t size) {
  size_t gid = blockIdx.x * blockDim.x + threadIdx.x;
  if (gid < size)
    out[gid] = a[gid] == val;
}

__global__ void EwiseGeKernel(const scalar_t* a, const scalar_t* b,
                              scalar_t* out, size_t size) {
  size_t gid = blockIdx.x * blockDim.x + threadIdx.x;
  if (gid < size)
    out[gid] = a[gid] >= b[gid];
}

__global__ void ScalarGeKernel(const scalar_t* a, scalar_t val, scalar_t* out,
                               size_t size) {
  size_t gid = blockIdx.x * blockDim.x + threadIdx.x;
  if (gid < size)
    out[gid] = a[gid] >= val;
}

__global__ void ScalarPowerKernel(const scalar_t* a, scalar_t val,
                                  scalar_t* out, size_t size) {
  size_t gid = blockIdx.x * blockDim.x + threadIdx.x;
  if (gid < size)
    out[gid] = pow(a[gid], val);
}

__global__ void EwiseLogKernel(const scalar_t* a, scalar_t* out, size_t size) {
  size_t gid = blockIdx.x * blockDim.x + threadIdx.x;
  if (gid < size)
    out[gid] = log(a[gid]);
}

__global__ void EwiseExpKernel(const scalar_t* a, scalar_t* out, size_t size) {
  size_t gid = blockIdx.x * blockDim.x + threadIdx.x;
  if (gid < size)
    out[gid] = exp(a[gid]);
}

__global__ void EwiseTanhKernel(const scalar_t* a, scalar_t* out, size_t size) {
  size_t gid = blockIdx.x * blockDim.x + threadIdx.x;
  if (gid < size)
    out[gid] = tanh(a[gid]);
}

template <EwiseOp op>
void EwiseFunction(const CudaArray& a, const CudaArray& b, CudaArray* out) {
  CudaDims dim = CudaOneDim(out->size);

  switch (op) {
  case EwiseOp::add:
    EwiseAddKernel<<<dim.grid, dim.block>>>(a.ptr, b.ptr, out->ptr, out->size);
    break;
  case EwiseOp::mul:
    EwiseMulKernel<<<dim.grid, dim.block>>>(a.ptr, b.ptr, out->ptr, out->size);
    break;
  case EwiseOp::div:
    EwiseDivKernel<<<dim.grid, dim.block>>>(a.ptr, b.ptr, out->ptr, out->size);
    break;
  case EwiseOp::maximum:
    EwiseMaximumKernel<<<dim.grid, dim.block>>>(a.ptr, b.ptr, out->ptr,
                                                out->size);
    break;
  case EwiseOp::eq:
    EwiseEqKernel<<<dim.grid, dim.block>>>(a.ptr, b.ptr, out->ptr, out->size);
    break;
  case EwiseOp::ge:
    EwiseGeKernel<<<dim.grid, dim.block>>>(a.ptr, b.ptr, out->ptr, out->size);
    break;
  }
}

template <ScalarOp op>
void ScalarFunction(const CudaArray& a, scalar_t val, CudaArray* out) {
  CudaDims dim = CudaOneDim(out->size);

  switch (op) {
  case ScalarOp::add_scalar:
    ScalarAddKernel<<<dim.grid, dim.block>>>(a.ptr, val, out->ptr, out->size);
    break;
  case ScalarOp::mul_scalar:
    ScalarMulKernel<<<dim.grid, dim.block>>>(a.ptr, val, out->ptr, out->size);
    break;
  case ScalarOp::div_scalar:
    ScalarDivKernel<<<dim.grid, dim.block>>>(a.ptr, val, out->ptr, out->size);
    break;
  case ScalarOp::maximum_scalar:
    ScalarMaximumKernel<<<dim.grid, dim.block>>>(a.ptr, val, out->ptr,
                                                 out->size);
    break;
  case ScalarOp::eq_scalar:
    ScalarEqKernel<<<dim.grid, dim.block>>>(a.ptr, val, out->ptr, out->size);
    break;
  case ScalarOp::ge_scalar:
    ScalarGeKernel<<<dim.grid, dim.block>>>(a.ptr, val, out->ptr, out->size);
    break;
  case ScalarOp::power_scalar:
    ScalarPowerKernel<<<dim.grid, dim.block>>>(a.ptr, val, out->ptr, out->size);
    break;
  }
}

template <EwiseUnitOp op>
void EwiseUnitFunction(const CudaArray& a, CudaArray* out) {
  CudaDims dim = CudaOneDim(out->size);

  switch (op) {
  case EwiseUnitOp::log:
    EwiseLogKernel<<<dim.grid, dim.block>>>(a.ptr, out->ptr, out->size);
    break;
  case EwiseUnitOp::exp:
    EwiseExpKernel<<<dim.grid, dim.block>>>(a.ptr, out->ptr, out->size);
    break;
  case EwiseUnitOp::tanh:
    EwiseTanhKernel<<<dim.grid, dim.block>>>(a.ptr, out->ptr, out->size);
    break;
  }
}

////////////////////////////////////////////////////////////////////////////////
// Matmul
////////////////////////////////////////////////////////////////////////////////

__global__ void MatmulKernel(const float* a, const float* b, float* out,
                             uint32_t M, uint32_t N, uint32_t P) {
  size_t gid = blockIdx.x * blockDim.x + threadIdx.x;
  if (gid < M * P) {
    size_t i = gid / P;
    size_t j = gid % P; 
    out[gid] = 0;
    for (size_t k = 0; k < N; ++k) {
      out[gid] += a[i * N + k] * b[k * P + j];
    }
  }
}

void Matmul(const CudaArray& a, const CudaArray& b, CudaArray* out, uint32_t M,
            uint32_t N, uint32_t P) {
  /**
   * Multiply two (compact) matrices into an output (also comapct) matrix.  You
   * will want to look at the lecture and notes on GPU-based linear algebra to
   * see how to do this.  Since ultimately mugrade is just evaluating
   * correctness, you _can_ implement a version that simply parallelizes over
   * (i,j) entries in the output array.  However, to really get the full benefit
   * of this problem, we would encourage you to use cooperative fetching, shared
   * memory register tiling, and other ideas covered in the class notes.  Note
   * that unlike the tiled matmul function in the CPU backend, here you should
   * implement a single function that works across all size matrices, whether or
   * not they are a multiple of a tile size.  As with previous CUDA
   * implementations, this function here will largely just set up the kernel
   * call, and you should implement the logic in a separate MatmulKernel() call.
   *
   *
   * Args:
   *   a: compact 2D array of size m x n
   *   b: comapct 2D array of size n x p
   *   out: compact 2D array of size m x p to write the output to
   *   M: rows of a / out
   *   N: columns of a / rows of b
   *   P: columns of b / out
   */
  CudaDims dim = CudaOneDim(M * P);
  MatmulKernel<<<dim.grid, dim.block>>>(a.ptr, b.ptr, out->ptr, M, N, P);
}

////////////////////////////////////////////////////////////////////////////////
// Max and sum reductions
////////////////////////////////////////////////////////////////////////////////

__global__ void ReduceMaxKernel(const float* a, float* out, size_t size,
                                size_t reduce_size) {
  size_t gid = blockIdx.x * blockDim.x + threadIdx.x;
  if (gid < size / reduce_size) {
    for (size_t i = 0; i < reduce_size; ++i) {
      if (i == 0) {
        out[gid] = a[reduce_size * gid];
      } else {
        out[gid] = max(out[gid], a[reduce_size * gid + i]);
      }
    }
  }
}

void ReduceMax(const CudaArray& a, CudaArray* out, size_t reduce_size) {
  /**
   * Reduce by taking maximum over `reduce_size` contiguous blocks.  Even though
   * it is inefficient, for simplicity you can perform each reduction in a
   * single CUDA thread.
   *
   * Args:
   *   a: compact array of size a.size = out.size * reduce_size to reduce over
   *   out: compact array to write into
   *   redice_size: size of the dimension to reduce over
   */
  CudaDims dim = CudaOneDim(a.size / reduce_size);
  ReduceMaxKernel<<<dim.grid, dim.block>>>(a.ptr, out->ptr, a.size,
                                           reduce_size);
}

__global__ void ReduceSumKernel(const float* a, float* out, size_t size,
                                size_t reduce_size) {
  size_t gid = blockIdx.x * blockDim.x + threadIdx.x;
  if (gid < size / reduce_size) {
    out[gid] = 0;
    for (size_t i = 0; i < reduce_size; ++i) {
      out[gid] += a[reduce_size * gid + i];
    }
  }
}

void ReduceSum(const CudaArray& a, CudaArray* out, size_t reduce_size) {
  /**
   * Reduce by taking summation over `reduce_size` contiguous blocks.  Again,
   * for simplicity you can perform each reduction in a single CUDA thread.
   *
   * Args:
   *   a: compact array of size a.size = out.size * reduce_size to reduce over
   *   out: compact array to write into
   *   redice_size: size of the dimension to reduce over
   */
  CudaDims dim = CudaOneDim(a.size / reduce_size);
  ReduceSumKernel<<<dim.grid, dim.block>>>(a.ptr, out->ptr, a.size,
                                           reduce_size);
}

} // namespace cuda
} // namespace needle

PYBIND11_MODULE(ndarray_backend_cuda, m) {
  namespace py = pybind11;
  using namespace needle;
  using namespace cuda;

  m.attr("__device_name__") = "cuda";
  m.attr("__tile_size__") = TILE;

  py::class_<CudaArray>(m, "Array")
      .def(py::init<size_t>(), py::return_value_policy::take_ownership)
      .def_readonly("size", &CudaArray::size)
      .def("ptr", &CudaArray::ptr_as_int);

  // return numpy array, copying from CPU
  m.def("to_numpy", [](const CudaArray& a, std::vector<size_t> shape,
                       std::vector<size_t> strides, size_t offset) {
    std::vector<size_t> numpy_strides = strides;
    std::transform(numpy_strides.begin(), numpy_strides.end(),
                   numpy_strides.begin(),
                   [](size_t& c) { return c * ELEM_SIZE; });

    // copy memory to host
    scalar_t* host_ptr = (scalar_t*)std::malloc(a.size * ELEM_SIZE);
    if (host_ptr == 0)
      throw std::bad_alloc();
    cudaError_t err =
        cudaMemcpy(host_ptr, a.ptr, a.size * ELEM_SIZE, cudaMemcpyDeviceToHost);
    if (err != cudaSuccess)
      throw std::runtime_error(cudaGetErrorString(err));

    // return numpy array
    py::capsule deallocate_buffer(host_ptr, [](void* p) { free(p); });
    return py::array_t<scalar_t>(shape, numpy_strides, host_ptr + offset,
                                 deallocate_buffer);
  });

  // copy numpy array to GPU
  m.def("from_numpy", [](py::array_t<scalar_t> a, CudaArray* out) {
    cudaError_t err = cudaMemcpy(out->ptr, a.request().ptr,
                                 out->size * ELEM_SIZE, cudaMemcpyHostToDevice);
    if (err != cudaSuccess)
      throw std::runtime_error(cudaGetErrorString(err));
  });

  m.def("fill", Fill);
  m.def("compact", Compact);
  m.def("ewise_setitem", EwiseSetitem);
  m.def("scalar_setitem", ScalarSetitem);
  m.def("ewise_add", EwiseFunction<EwiseOp::add>);
  m.def("scalar_add", ScalarFunction<ScalarOp::add_scalar>);

  m.def("ewise_mul", EwiseFunction<EwiseOp::mul>);
  m.def("scalar_mul", ScalarFunction<ScalarOp::mul_scalar>);
  m.def("ewise_div", EwiseFunction<EwiseOp::div>);
  m.def("scalar_div", ScalarFunction<ScalarOp::div_scalar>);
  m.def("scalar_power", ScalarFunction<ScalarOp::power_scalar>);

  m.def("ewise_maximum", EwiseFunction<EwiseOp::maximum>);
  m.def("scalar_maximum", ScalarFunction<ScalarOp::maximum_scalar>);
  m.def("ewise_eq", EwiseFunction<EwiseOp::eq>);
  m.def("scalar_eq", ScalarFunction<ScalarOp::eq_scalar>);
  m.def("ewise_ge", EwiseFunction<EwiseOp::ge>);
  m.def("scalar_ge", ScalarFunction<ScalarOp::ge_scalar>);

  m.def("ewise_log", EwiseUnitFunction<EwiseUnitOp::log>);
  m.def("ewise_exp", EwiseUnitFunction<EwiseUnitOp::exp>);
  m.def("ewise_tanh", EwiseUnitFunction<EwiseUnitOp::tanh>);

  m.def("matmul", Matmul);

  m.def("reduce_max", ReduceMax);
  m.def("reduce_sum", ReduceSum);
}
