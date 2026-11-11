// CMP90HX BAR1 P2P: validate SM reads from another GPU's allocation.
// Build: nvcc -O2 -std=c++14 tools/bar1_peer_smoke.cu -o bar1_peer_smoke
#include <cuda_runtime.h>
#include <cstdio>
#include <vector>

static constexpr int kWords = 4096;

__global__ void read_peer(const unsigned int *remote, unsigned int *local)
{
    int index = blockIdx.x * blockDim.x + threadIdx.x;
    if (index < kWords)
        local[index] = remote[index] ^ 0x5a5a5a5aU;
}

__global__ void write_peer(unsigned int *remote)
{
    int index = blockIdx.x * blockDim.x + threadIdx.x;
    if (index < kWords)
        remote[index] = 0x9e3779b9U ^ static_cast<unsigned int>(index);
}

static int test_pair(int dst, int src)
{
    unsigned int *remote = nullptr;
    unsigned int *local = nullptr;
    bool enabled = false;
    bool success = false;
    const size_t bytes = static_cast<size_t>(kWords) * sizeof(unsigned int);
    cudaError_t status;
    int can_access = 0;

#define CHECK(call) do { \
    status = (call); \
    if (status != cudaSuccess) { \
        std::fprintf(stderr, "GPU%d <- GPU%d: %s: %s\n", dst, src, #call, cudaGetErrorString(status)); \
        goto cleanup; \
    } \
} while (0)

    CHECK(cudaDeviceCanAccessPeer(&can_access, dst, src));
    if (!can_access) {
        std::fprintf(stderr, "GPU%d <- GPU%d: CUDA peer access unavailable\n", dst, src);
        goto cleanup;
    }
    CHECK(cudaSetDevice(src));
    CHECK(cudaMalloc(reinterpret_cast<void **>(&remote), bytes));
    CHECK(cudaMemset(remote, 0xa5, bytes));
    CHECK(cudaDeviceSynchronize());

    CHECK(cudaSetDevice(dst));
    CHECK(cudaMalloc(reinterpret_cast<void **>(&local), bytes));
    status = cudaDeviceEnablePeerAccess(src, 0);
    if (status == cudaSuccess)
        enabled = true;
    else if (status == cudaErrorPeerAccessAlreadyEnabled)
        cudaGetLastError();
    else {
        std::fprintf(stderr, "GPU%d <- GPU%d: cudaDeviceEnablePeerAccess: %s\n", dst, src,
                     cudaGetErrorString(status));
        goto cleanup;
    }

    read_peer<<<(kWords + 255) / 256, 256>>>(remote, local);
    CHECK(cudaGetLastError());
    CHECK(cudaDeviceSynchronize());  // Catches remote SM access faults / SIGBUS.

    {
        std::vector<unsigned int> host(kWords);
        CHECK(cudaMemcpy(host.data(), local, bytes, cudaMemcpyDeviceToHost));
        for (int i = 0; i < kWords; ++i) {
            if (host[i] != 0xffffffffU) {
                std::fprintf(stderr, "GPU%d <- GPU%d: mismatch[%d] = 0x%08x\n",
                             dst, src, i, host[i]);
                goto cleanup;
            }
        }
    }
    // Verify remote SM writes independently: the destination GPU's kernel
    // changes a source GPU allocation, which must be visible to its owner.
    write_peer<<<(kWords + 255) / 256, 256>>>(remote);
    CHECK(cudaGetLastError());
    CHECK(cudaDeviceSynchronize());
    CHECK(cudaSetDevice(src));
    {
        std::vector<unsigned int> host(kWords);
        CHECK(cudaMemcpy(host.data(), remote, bytes, cudaMemcpyDeviceToHost));
        for (int i = 0; i < kWords; ++i) {
            unsigned int expected = 0x9e3779b9U ^ static_cast<unsigned int>(i);
            if (host[i] != expected) {
                std::fprintf(stderr, "GPU%d -> GPU%d: remote write mismatch[%d] = 0x%08x\n",
                             dst, src, i, host[i]);
                goto cleanup;
            }
        }
    }
    success = true;
    std::printf("BAR1_SM_PEER_PASS GPU%d <-> GPU%d: direct SM read/write (%zu bytes)\n",
                dst, src, bytes);

cleanup:
    cudaSetDevice(dst);
    if (enabled)
        cudaDeviceDisablePeerAccess(src);
    if (local)
        cudaFree(local);
    cudaSetDevice(src);
    if (remote)
        cudaFree(remote);
#undef CHECK
    return success ? 0 : 1;
}

int main()
{
    int devices = 0;
    cudaError_t status = cudaGetDeviceCount(&devices);
    if (status != cudaSuccess || devices < 2) {
        std::fprintf(stderr, "Expected >=2 CUDA GPUs: %s, count=%d\n",
                     cudaGetErrorString(status), devices);
        return 2;
    }
    int failures = 0;
    for (int dst = 0; dst < devices; ++dst) {
        for (int src = 0; src < devices; ++src) {
            if (dst != src)
                failures += test_pair(dst, src);
        }
    }
    if (failures) {
        std::fprintf(stderr, "BAR1_SM_PEER_FAIL: %d directed pairs failed\n", failures);
        return 1;
    }
    std::printf("BAR1_SM_PEER_ALL_PASS: %d directed pairs\n", devices * (devices - 1));
    return 0;
}
