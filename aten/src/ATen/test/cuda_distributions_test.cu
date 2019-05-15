#include <gtest/gtest.h>

#include <ATen/ATen.h>
#include <ATen/cuda/CUDAContext.h>
#include <cuda.h>
#include <cuda_runtime.h>

#include <curand.h>
#include <curand_kernel.h>
#include <curand_philox4x32_x.h>

__global__ void expected_randoms(float* x, uint64_t counter_offset) {
  for(int i=0; i < 4; i++) {
    curandStatePhilox4_32_10_t state;
    curand_init(
            123,
            i,
            counter_offset,
            &state);
    auto ret = curand_uniform4(&state);
    x[i] = ret.x;
  }
}

TEST(DistributionsTest, TestPhiloxIncrementSmallTensor) {
  // Test Description:
  //   In Distributions.cu we mentioned that philox increment
  //   should be at least the number of curand() random numbers used in
  //   each thread. In this test, we make sure that uniform_ correctly
  //   increments philox and doesn't reuse randoms from previous calls
  //   for a small tensor size of 4.
  //    - We check that by first getting 4 randoms from uniform_.
  //      Once we get these 4 randoms, that would mean that philox counter for
  //      thread 0, 1, 2 and 3, was incremented by 4 (check calc_execution_policy
  //      function for details).
  //    - Now get 4 randoms with offset=4 for thread {0,1,2,3} from expected_randoms
  //      kernel above.
  //    - Now get 4 more randoms from uniform_ (note thread {0,1,2,3} for this call would
  //      start from a philox_offset value of 4)
  //    - the 4 randoms from expected_randoms and the 4 randoms from the previous call
  //      of uniform_ should match, signifying that the philox offset was 
  //      incremented properly and no randoms are being reused from previous calls

  // if cuda not available, return
  if (!at::cuda::is_available()) return;

  // manual seed to 123
  at::manual_seed(123);

  // get 4 randoms from uniform_(), philox offset is now incremented to 4 by this call
  at::empty({4}, at::TensorOptions(at::kCUDA)).uniform_();

  // allocate 4 float on host memory
  float *x;
  cudaMallocManaged(&x, 4*sizeof(float));

  // launch kernel to get expected randoms
  expected_randoms<<<1, 1>>>(x, 4);

  // Wait for GPU to finish before accessing on host
  cudaDeviceSynchronize();
  
  // get 4 new float from uniform_()
  auto self = at::empty({4}, at::TensorOptions(at::kCUDA));
  self.uniform_();
  
  // check randoms from expected_randoms kernel are equal to the randoms from the second
  // call of uniform_()
  for (int i = 0; i < 4; i++) {
    ASSERT_EQ(self[i].item().to<float>(), x[i]);
  }

  // Free memory
  cudaFree(x);
}

TEST(DistributionsTest, TestPhiloxIncrementBigTensor) {
  // Test Description:
  //   In Distributions.cu we mentioned that philox increment
  //   should be at least the number of curand() random numbers used in
  //   each thread. In this test, we make sure that uniform_ correctly
  //   increments philox and doesn't reuse randoms from previous calls
  //   for a big size tensor.
  //    - First of all, we come up with what the size of the big tensor
  //      should be for this test. Our goal is to show that when the uniform_
  //      kernel runs at full occupancy (i.e. when the number of elements is
  //      greater the number of threads launched), it hits the unroll loop in
  //      the uniform_ kernel.
  //    - Hence, we set the size of the tensor in this test to be 8 times the
  //      maximum number of threads we can launch. This means that, each thread will
  //      be yielding 8 elements, and as a result, curand_uniform4 will be called twice
  //      and all the 8 elements in a thread will consume all the float4 from the
  //      two calls of curand_unfiorm4 as a result of the unroll loop. Therefore,
  //      after this call to the unform_, counter_offset for the next call to uniform_
  //      will start from 8. This is what we test next.
  //    - Now get 4 randoms with offset=8 for thread {0,1,2,3} from expected_randoms
  //      kernel above.
  //    - Now get 4 more randoms from uniform_ (note thread {0,1,2,3} for this call would
  //      start from a philox_offset value of 8)
  //    - the 4 randoms from expected_randoms kernel and the 4 randoms from the previous call
  //      of uniform_ should match, signifying that the philox offset was
  //      incremented properly and no randoms are being reused from previous calls

  // if cuda not available, return
  if (!at::cuda::is_available()) return;

  // manual seed to 123
  at::manual_seed(123);

  // calculate maximum number of threads that can be launched
  // and set the numel to be 8 times that
  const int block_size = 256;
  dim3 dim_block(block_size);
  uint32_t blocks_per_sm = at::cuda::getCurrentDeviceProperties()->maxThreadsPerMultiProcessor / block_size;
  dim3 grid(static_cast<uint32_t>(at::cuda::getCurrentDeviceProperties()->multiProcessorCount) * blocks_per_sm);
  auto numel = block_size * grid.x * 8;

  // get numel randoms from uniform_(), philox offset is now incremented to 8 by this call
  at::empty({numel}, at::TensorOptions(at::kCUDA)).uniform_();

  // allocate 4 float on host memory
  float *x;
  cudaMallocManaged(&x, 4*sizeof(float));

  // launch kernel to get expected randoms
  expected_randoms<<<1, 1>>>(x, 8);

  // Wait for GPU to finish before accessing on host
  cudaDeviceSynchronize();

  // get 4 new float from uniform_()
  auto self = at::empty({4}, at::TensorOptions(at::kCUDA));
  self.uniform_();

  // check randoms from expected_randoms kernel are equal to the randoms from the second
  // call of uniform_()
  for (int i = 0; i < 4; i++) {
    ASSERT_EQ(self[i].item().to<float>(), x[i]);
  }

  // Free memory
  cudaFree(x);
}