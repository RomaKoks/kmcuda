#include <cfloat>

#include "private.h"
#include "metric_abstraction.h"

#define CLUSTER_DISTANCES_BLOCK_SIZE 512
#define CLUSTER_DISTANCES_SHMEM 12288  // in float-s
#define CLUSTER_RADIUSES_BLOCK_SIZE 512
#define CLUSTER_RADIUSES_SHMEM 8192  // in float-s
#define KNN_BLOCK_SIZE 512

__constant__ uint32_t d_samples_size;
__constant__ uint32_t d_clusters_size;
__constant__ int d_shmem_size;

template <typename T>
FPATTR T dupper(T size, T each) {
  T div = size / each;
  if (div * each == size) {
    return div;
  }
  return div + 1;
}

template <typename T>
FPATTR T dmin(T a, T b) {
  return a <= b? a : b;
}

/// sample_dists musr be zero-ed!
template <KMCUDADistanceMetric M, typename F>
__global__ void knn_calc_cluster_radiuses(
    uint32_t offset, uint32_t length, const uint32_t *__restrict__ inv_asses,
    const uint32_t *__restrict__ inv_asses_offsets,
    const F *__restrict__ centroids, const F *__restrict__ samples,
    float *__restrict__ sample_dists, float *__restrict__ radiuses) {
  volatile uint32_t ci = blockIdx.x * blockDim.x + threadIdx.x;
  if (ci >= length) {
    return;
  }
  ci += offset;

  // stage 1 - accumulate partial distances for every sample
  __shared__ F shcents[CLUSTER_RADIUSES_SHMEM];
  volatile const int cent_step = dmin(
      CLUSTER_RADIUSES_SHMEM / blockDim.x, static_cast<unsigned>(d_features_size));
  F *volatile const my_cent = shcents + cent_step * threadIdx.x;
  for (int cfi = 0; cfi < d_features_size; cfi += cent_step) {
    const int fsize = dmin(cent_step, d_features_size - cfi);
    for (int f = 0; f < fsize; f++) {
      my_cent[f] = centroids[ci * d_features_size + cfi + f];
    }
    for (uint32_t ass = inv_asses_offsets[ci]; ass < inv_asses_offsets[ci + 1];
         ass++) {
       uint64_t sample = inv_asses[ass];  // uint64_t!
       sample_dists[sample] += METRIC<M, F>::partial(
           my_cent, samples + sample * d_features_size + cfi, fsize);
    }
  }
  // stage 2 - find the maximum distance
  float max_dist = FLT_MIN;
  for (uint32_t ass = inv_asses_offsets[ci]; ass < inv_asses_offsets[ci + 1];
       ass++) {
    float dist = METRIC<M, F>::finalize(sample_dists[inv_asses[ass]]);
    if (dist > max_dist) {
      max_dist = dist;
    }
  }
  radiuses[ci] = max_dist > FLT_MIN? max_dist : NAN;
}

/// distances must be zero-ed!
template <KMCUDADistanceMetric M, typename F>
__global__ void knn_calc_cluster_distances(
    uint32_t offset, const F *__restrict__ centroids, float *distances) {
  volatile const uint32_t bi = blockIdx.x + offset;
  const uint32_t bs = CLUSTER_DISTANCES_BLOCK_SIZE;
  uint32_t x, y;
  const uint32_t n = dupper(d_clusters_size, bs);
  {
    float tmp = n + 0.5;
    float d = _sqrt(tmp * tmp - 2 * bi);
    y = tmp - d;
    x = bi + y + (n - y) * (n - y + 1) / 2 - n * (n + 1) / 2;
  }
  __shared__ F shcents[CLUSTER_DISTANCES_SHMEM];
  const uint32_t fstep = CLUSTER_DISTANCES_SHMEM / bs;
  F *volatile my_cent = shcents + fstep * threadIdx.x;

  // stage 1 - accumulate distances
  for (uint16_t fpos = 0; fpos < d_features_size; fpos += fstep) {
    const uint16_t fsize = dmin(
        fstep, static_cast<uint32_t>(d_features_size - fpos));
    uint32_t cbase = x * bs + threadIdx.x;
    if (cbase < d_clusters_size) {
      for (uint16_t f = 0; f < fsize; f++) {
        my_cent[f] = centroids[cbase * d_features_size + fpos + f];
      }
    }
    __syncthreads();
    for (uint32_t ti = 0; ti < bs; ti++) {
      if ((y * bs + threadIdx.x) < d_clusters_size
          && (x * bs + ti) < d_clusters_size) {
        auto other_cent = d_clusters_size <= bs?
            shcents + (y * bs + threadIdx.x) * fstep
            :
            centroids + (y * bs + threadIdx.x) * d_features_size + fpos;
        distances[(y * bs + threadIdx.x) * d_clusters_size + x * bs + ti] +=
            METRIC<M, F>::partial(other_cent, shcents + ti * fstep, fsize);
      }
    }
  }

  // stage 2 - finalize the distances
  for (uint32_t ti = 0; ti < bs; ti++) {
    if ((y * bs + threadIdx.x) < d_clusters_size
        && (x * bs + ti) < d_clusters_size) {
      uint32_t di = (y * bs + threadIdx.x) * d_clusters_size + x * bs + ti;
      float dist = distances[di];
      dist = METRIC<M, F>::finalize(dist);
      distances[di] = dist;
    }
  }
}

__global__ void knn_mirror_cluster_distances(float *__restrict__ distances) {
  const uint32_t bs = CLUSTER_DISTANCES_BLOCK_SIZE;
  uint32_t x, y;
  const uint32_t n = dupper(d_clusters_size, bs);
  {
    float tmp = n + 0.5;
    float d = _sqrt(tmp * tmp - 2 * blockIdx.x);
    y = tmp - d;
    x = blockIdx.x + y + (n - y) * (n - y + 1) / 2 - n * (n + 1) / 2;
  }
  for (uint32_t ti = 0; ti < bs; ti++) {
    if ((y * bs + threadIdx.x) < d_clusters_size && (x * bs + ti) < d_clusters_size) {
      distances[(x * bs + ti) * d_clusters_size + y * bs + threadIdx.x] =
          distances[(y * bs + threadIdx.x) * d_clusters_size + x * bs + ti];
    }
  }
}

FPATTR void push_sample1(uint16_t k, float dist, float *head) {
  uint16_t start = 0, finish = k - 1;
  while (finish - start > 1) {
    uint16_t middle = (start + finish) / 2;
    if (head[middle] <= dist) {
      start = middle;
    } else {
      finish = middle;
    }
  }
  uint16_t inspos = (head[start * 2] >= dist? start : start + 1);
  for (uint16_t i = k - 1; i > inspos; i--) {
    head[i] = head[i - 1];
  }
  head[inspos] = dist;
}

FPATTR void push_sample2(uint16_t k, float dist, uint32_t index, float *head) {
  uint16_t start = 0, finish = k - 1;
  while (finish - start > 1) {
    uint16_t middle = (start + finish) / 2;
    if (head[middle * 2] <= dist) {
      start = middle;
    } else {
      finish = middle;
    }
  }
  uint16_t inspos = (head[start * 2] >= dist? start : start + 1);
  for (uint16_t i = k - 1; i > inspos; i--) {
    reinterpret_cast<uint64_t*>(head)[i] = reinterpret_cast<uint64_t*>(head)[i - 1];
  }
  head[inspos * 2] = dist;
  reinterpret_cast<uint32_t*>(head)[inspos * 2 + 1] = index;
}

template <KMCUDADistanceMetric M, typename F>
__global__ void knn_assign_shmem(
    uint32_t offset, uint32_t length, uint16_t k,
    const float *__restrict__ cluster_distances,
    const float *__restrict__ cluster_radiuses,
    const F *__restrict__ samples, const F *__restrict__ centroids,
    const uint32_t *assignments, const uint32_t *inv_asses,
    const uint32_t *inv_asses_offsets, uint32_t *neighbors) {
  volatile uint64_t sample = blockIdx.x * blockDim.x + threadIdx.x;
  if (sample >= length) {
    return;
  }
  sample += offset;
  volatile uint32_t mycls = assignments[sample];
  volatile float mydist = METRIC<M, F>::distance(
      samples + sample * d_features_size, centroids + mycls * d_features_size);
  extern __shared__ float buffer[];
  float *volatile mynearest = buffer + k * 2 * threadIdx.x;
  volatile float mndist = FLT_MAX;
  for (int i = 0; i < static_cast<int>(k); i++) {
    mynearest[i * 2] = FLT_MAX;
  }
  for (uint32_t pos = inv_asses_offsets[mycls];
       pos < inv_asses_offsets[mycls + 1]; pos++) {
    uint64_t other_sample = inv_asses[pos];
    if (sample == other_sample) {
      continue;
    }
    float dist = METRIC<M, F>::distance(
        samples + sample * d_features_size,
        samples + other_sample * d_features_size);
    if (dist <= mndist) {
      push_sample2(k, dist, other_sample, mynearest);
      mndist = mynearest[k * 2 - 2];
    }
  }
  for (uint32_t cls = 0; cls < d_clusters_size; cls++) {
    if (cls == mycls) {
      continue;
    }
    float cdist = cluster_distances[cls * d_clusters_size + mycls];
    if (cdist != cdist) {
      continue;
    }
    float dist = cdist - mydist - cluster_radiuses[cls];
    if (dist >= mndist) {
      continue;
    }
    for (uint32_t pos = inv_asses_offsets[cls];
         pos < inv_asses_offsets[cls + 1]; pos++) {
      uint64_t other_sample = inv_asses[pos];
      dist = METRIC<M, F>::distance(
          samples + sample * d_features_size,
          samples + other_sample * d_features_size);
      if (dist <= mndist) {
        push_sample2(k, dist, other_sample, mynearest);
        mndist = mynearest[k * 2 - 2];
      }
    }
  }
  for (int i = 0; i < static_cast<int>(k); i++) {
    neighbors[(sample - offset) * k + i] =
        reinterpret_cast<uint32_t*>(mynearest)[i * 2 + 1];
  }
}

template <KMCUDADistanceMetric M, typename F>
__global__ void knn_assign_gmem_border(
    uint32_t offset, uint32_t length, uint16_t k,
    const float *__restrict__ cluster_distances,
    const float *__restrict__ cluster_radiuses,
    const F *__restrict__ samples, const F *__restrict__ centroids,
    const uint32_t *assignments, const uint32_t *inv_asses,
    const uint32_t *inv_asses_offsets, uint32_t *neighbors) {
  volatile uint64_t sample = blockIdx.x * blockDim.x + threadIdx.x;
  if (sample >= length) {
    return;
  }
  sample += offset;
  volatile uint32_t mycls = assignments[sample];
  volatile float mydist = METRIC<M, F>::distance(
      samples + sample * d_features_size, centroids + mycls * d_features_size);
  float *volatile mynearest = reinterpret_cast<float*>(neighbors + (sample - offset) * k);
  for (int i = 0; i < static_cast<int>(k); i++) {
    mynearest[i] = FLT_MAX;
  }
  volatile float mndist = FLT_MAX;
  for (uint32_t pos = inv_asses_offsets[mycls];
       pos < inv_asses_offsets[mycls + 1]; pos++) {
    uint64_t other_sample = inv_asses[pos];
    if (sample == other_sample) {
      continue;
    }
    float dist = METRIC<M, F>::distance(
        samples + sample * d_features_size,
        samples + other_sample * d_features_size);
    if (dist <= mndist) {
      push_sample1(k, dist, mynearest);
      mndist = mynearest[k - 1];
    }
  }
  for (uint32_t cls = 0; cls < d_clusters_size; cls++) {
    if (cls == mycls) {
      continue;
    }
    float cdist = cluster_distances[cls * d_clusters_size + mycls];
    if (cdist != cdist) {
      continue;
    }
    float dist = cdist - mydist - cluster_radiuses[cls];
    if (dist > mndist) {
      continue;
    }
    for (uint32_t pos = inv_asses_offsets[cls];
         pos < inv_asses_offsets[cls + 1]; pos++) {
      uint64_t other_sample = inv_asses[pos];
      dist = METRIC<M, F>::distance(
          samples + sample * d_features_size,
          samples + other_sample * d_features_size);
      if (dist <= mndist) {
        push_sample1(k, dist, mynearest);
        mndist = mynearest[k - 1];
      }
    }
  }
}

template <KMCUDADistanceMetric M, typename F>
__global__ void knn_assign_gmem_indices(
    uint32_t offset, uint32_t length, uint16_t k,
    const float *__restrict__ cluster_distances,
    const float *__restrict__ cluster_radiuses,
    const F *__restrict__ samples, const F *__restrict__ centroids,
    const uint32_t *assignments, const uint32_t *inv_asses,
    const uint32_t *inv_asses_offsets,
    uint32_t *neighbors) {
  volatile uint64_t sample = blockIdx.x * blockDim.x + threadIdx.x;
  if (sample >= length) {
    return;
  }
  sample += offset;
  volatile uint32_t mycls = assignments[sample];
  volatile float mydist = METRIC<M, F>::distance(
      samples + sample * d_features_size, centroids + mycls * d_features_size);
  volatile float mndist = reinterpret_cast<float*>(neighbors + (sample - offset) * k)[k - 1];
  uint32_t *volatile myneighbors = neighbors + (sample - offset) * k;
  for (uint32_t pos = inv_asses_offsets[mycls];
       pos < inv_asses_offsets[mycls + 1]; pos++) {
    uint64_t other_sample = inv_asses[pos];
    if (sample == other_sample) {
      continue;
    }
    float dist = METRIC<M, F>::distance(
        samples + sample * d_features_size,
        samples + other_sample * d_features_size);
    if (dist <= mndist) {
      *myneighbors++ = other_sample;
    }
  }
  for (uint32_t cls = 0; cls < d_clusters_size; cls++) {
    if (cls == mycls) {
      continue;
    }
    float cdist = cluster_distances[cls * d_clusters_size + mycls];
    if (cdist != cdist) {
      continue;
    }
    float dist = cdist - mydist - cluster_radiuses[cls];
    if (dist > mndist) {
      continue;
    }
    for (uint32_t pos = inv_asses_offsets[cls];
         pos < inv_asses_offsets[cls + 1]; pos++) {
      uint64_t other_sample = inv_asses[pos];
      dist = METRIC<M, F>::distance(
          samples + sample * d_features_size,
          samples + other_sample * d_features_size);
      if (dist <= mndist) {
        *myneighbors++ = other_sample;
      }
    }
  }
}

extern "C" {

KMCUDAResult knn_cuda_setup(
    uint32_t h_samples_size, uint16_t h_features_size, uint32_t h_clusters_size,
    const std::vector<int> &devs, int32_t verbosity) {
  FOR_EACH_DEV(
    CUCH(cudaMemcpyToSymbol(d_samples_size, &h_samples_size, sizeof(h_samples_size)),
         kmcudaMemoryCopyError);
    CUCH(cudaMemcpyToSymbol(d_features_size, &h_features_size, sizeof(h_features_size)),
         kmcudaMemoryCopyError);
    CUCH(cudaMemcpyToSymbol(d_clusters_size, &h_clusters_size, sizeof(h_clusters_size)),
         kmcudaMemoryCopyError);
    cudaDeviceProp props;
    CUCH(cudaGetDeviceProperties(&props, dev), kmcudaRuntimeError);
    int h_shmem_size = static_cast<int>(props.sharedMemPerBlock);
    DEBUG("GPU #%" PRIu32 " has %d bytes of shared memory per block\n",
          dev, h_shmem_size);
    h_shmem_size /= sizeof(uint32_t);
    CUCH(cudaMemcpyToSymbol(d_shmem_size, &h_shmem_size, sizeof(h_shmem_size)),
         kmcudaMemoryCopyError);
  );
  return kmcudaSuccess;
}

KMCUDAResult knn_cuda_calc(
    uint16_t k, uint32_t h_samples_size, uint32_t h_clusters_size,
    uint16_t h_features_size, KMCUDADistanceMetric metric,
    const std::vector<int> &devs, int fp16x2, int verbosity,
    const udevptrs<float> &samples, const udevptrs<float> &centroids,
    const udevptrs<uint32_t> &assignments, const udevptrs<uint32_t> &inv_asses,
    const udevptrs<uint32_t> &inv_asses_offsets, udevptrs<float> *distances,
    udevptrs<float>* sample_dists, udevptrs<float> *radiuses,
    udevptrs<uint32_t> *neighbors) {
  auto plan = distribute(h_clusters_size, h_features_size * sizeof(float), devs);
  if (verbosity > 1) {
    print_plan("plan_calc_radiuses", plan);
  }
  INFO("calculating the cluster radiuses...\n");
  FOR_EACH_DEVI(
    uint32_t offset, length;
    std::tie(offset, length) = plan[devi];
    if (length == 0) {
      continue;
    }
    dim3 block(CLUSTER_RADIUSES_BLOCK_SIZE, 1, 1);
    dim3 grid(upper(h_clusters_size, block.x), 1, 1);
    float *dsd;
    if (h_clusters_size * h_clusters_size >= h_samples_size) {
      dsd = (*distances)[devi].get();
    } else {
      dsd = (*sample_dists)[devi].get();
    }
    KERNEL_SWITCH(knn_calc_cluster_radiuses, <<<grid, block>>>(
        offset, length, inv_asses[devi].get(), inv_asses_offsets[devi].get(),
        reinterpret_cast<const F*>(centroids[devi].get()),
        reinterpret_cast<const F*>(samples[devi].get()),
        dsd, (*radiuses)[devi].get()));
  );
  FOR_EACH_DEVI(
    uint32_t offset, length;
    std::tie(offset, length) = plan[devi];
    FOR_OTHER_DEVS(
      CUP2P(radiuses, offset, length);
    );
  );
  if (h_clusters_size * h_clusters_size >= h_samples_size) {
    CUMEMSET_ASYNC(*distances, 0, h_samples_size);
  }
  uint32_t dist_blocks_dim = upper(
      h_clusters_size, static_cast<uint32_t>(CLUSTER_DISTANCES_BLOCK_SIZE));
  uint32_t dist_blocks_n = (2 * dist_blocks_dim + 1) * (2 * dist_blocks_dim + 1) / 8;
  plan = distribute(dist_blocks_n, 512, devs);
  {  // align across CLUSTER_DISTANCES_BLOCK_SIZE horizontal boundaries
    uint32_t align = 0;
    for (auto& p : plan) {
      uint32_t offset, length;
      std::tie(offset, length) = p;
      offset += align;
      std::get<0>(p) = offset;
      uint32_t n = dist_blocks_dim;
      float tmp = n + 0.5;
      float d = sqrt(tmp * tmp - 2 * (offset + length));
      uint32_t y = tmp - d;
      uint32_t x = offset + length + (n - y) * (n - y + 1) / 2 - n * (n + 1) / 2;
      if (x > 0) {
        align = n - y - x;
        std::get<1>(p) += align;
      }
    }
  }
  if (verbosity > 1) {
    print_plan("plan_calc_cluster_distances", plan);
  }
  INFO("calculating the centroid distance matrix...\n");
  FOR_EACH_DEVI(
    uint32_t offset, length;
    std::tie(offset, length) = plan[devi];
    if (length == 0) {
      continue;
    }
    dim3 block(CLUSTER_DISTANCES_BLOCK_SIZE, 1, 1);
    dim3 grid(length, 1, 1);
    KERNEL_SWITCH(knn_calc_cluster_distances, <<<grid, block>>>(
        offset, reinterpret_cast<const F*>(centroids[devi].get()),
        (*distances)[devi].get()));
  );
  FOR_EACH_DEVI(
    uint32_t y_start, y_finish;
    {
      uint32_t offset, length;
      std::tie(offset, length) = plan[devi];
      float tmp = dist_blocks_dim + 0.5;
      float d = sqrt(tmp * tmp - 2 * offset);
      y_start = tmp - d;
      d = sqrt(tmp * tmp - 2 * (offset + length));
      y_finish = tmp - d;
    }
    if (y_finish == y_start) {
      continue;
    }
    uint32_t p_offset = y_start * h_clusters_size * CLUSTER_DISTANCES_BLOCK_SIZE;
    uint32_t p_size = (y_finish - y_start) * h_clusters_size * CLUSTER_DISTANCES_BLOCK_SIZE;
    p_size = std::min(p_size, h_clusters_size * h_clusters_size - p_offset);
    FOR_OTHER_DEVS(
      CUP2P(distances, p_offset, p_size);
    );
  );
  FOR_EACH_DEVI(
    dim3 block(CLUSTER_DISTANCES_BLOCK_SIZE, 1, 1);
    dim3 grid(dist_blocks_n, 1, 1);
    knn_mirror_cluster_distances<<<grid, block>>>((*distances)[devi].get());
  );
  plan = distribute(h_samples_size, h_features_size * sizeof(float), devs);
  INFO("searching for the nearest neighbors...\n");
  FOR_EACH_DEVI(
    uint32_t offset, length;
    std::tie(offset, length) = plan[devi];
    dim3 block(KNN_BLOCK_SIZE, 1, 1);
    dim3 grid(upper(h_samples_size, block.x), 1, 1);
    cudaDeviceProp props;
    CUCH(cudaGetDeviceProperties(&props, devs[devi]), kmcudaRuntimeError);
    int shmem_size = static_cast<int>(props.sharedMemPerBlock);
    int needed_shmem_size = KNN_BLOCK_SIZE * 2 * k * sizeof(uint32_t);
    if (needed_shmem_size > shmem_size) {
      INFO("device #%d: needed shmem size %d > %d => chose 2-pass slow algo",
           devs[devi], needed_shmem_size, shmem_size);
      KERNEL_SWITCH(knn_assign_gmem_border, <<<grid, block>>>(
          offset, length, k, (*distances)[devi].get(), (*radiuses)[devi].get(),
          reinterpret_cast<const F*>(samples[devi].get()),
          reinterpret_cast<const F*>(centroids[devi].get()),
          assignments[devi].get(), inv_asses[devi].get(),
          inv_asses_offsets[devi].get(), (*neighbors)[devi].get()));
      KERNEL_SWITCH(knn_assign_gmem_indices, <<<grid, block>>>(
          offset, length, k, (*distances)[devi].get(), (*radiuses)[devi].get(),
          reinterpret_cast<const F*>(samples[devi].get()),
          reinterpret_cast<const F*>(centroids[devi].get()),
          assignments[devi].get(), inv_asses[devi].get(),
          inv_asses_offsets[devi].get(), (*neighbors)[devi].get()));
    } else {
      KERNEL_SWITCH(knn_assign_shmem, <<<grid, block, needed_shmem_size>>>(
          offset, length, k, (*distances)[devi].get(), (*radiuses)[devi].get(),
          reinterpret_cast<const F*>(samples[devi].get()),
          reinterpret_cast<const F*>(centroids[devi].get()),
          assignments[devi].get(), inv_asses[devi].get(),
          inv_asses_offsets[devi].get(), (*neighbors)[devi].get()));
    }
  );
  return kmcudaSuccess;
}

}  // extern "C"
