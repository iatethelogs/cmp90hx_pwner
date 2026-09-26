#!/usr/bin/env bash
set -Eeuo pipefail

min_tflops="${1:-15.0}"
nvcc_bin="${NVCC:-}"

if [[ -z "$nvcc_bin" ]]; then
    nvcc_bin="$(command -v nvcc || true)"
fi
if [[ -z "$nvcc_bin" && -x /usr/local/cuda/bin/nvcc ]]; then
    nvcc_bin="/usr/local/cuda/bin/nvcc"
fi
if [[ -z "$nvcc_bin" || ! -x "$nvcc_bin" ]]; then
    printf 'nvcc not found; install CUDA toolkit first\n'
    exit 31
fi

src="/tmp/cmp90hx_fp32_verify.cu"
bin="/tmp/cmp90hx_fp32_verify"

cat > "$src" <<'EOF_CU'
#include <cuda_runtime.h>
#include <cublas_v2.h>
#include <cstdio>
#include <cstdlib>

#define CHECK_CUDA(x) do { cudaError_t e=(x); if(e!=cudaSuccess){ \
  std::fprintf(stderr,"CUDA error: %s\n", cudaGetErrorString(e)); return 10; }} while(0)

#define CHECK_CUBLAS(x) do { cublasStatus_t s=(x); if(s!=CUBLAS_STATUS_SUCCESS){ \
  std::fprintf(stderr,"cuBLAS error: %d\n", (int)s); return 11; }} while(0)

int main(int argc, char **argv) {
    double min_tflops = argc > 1 ? std::atof(argv[1]) : 15.0;
    int n = argc > 2 ? std::atoi(argv[2]) : 6144;
    int warmup = argc > 3 ? std::atoi(argv[3]) : 2;
    int repeat = argc > 4 ? std::atoi(argv[4]) : 5;

    int count = 0;
    CHECK_CUDA(cudaGetDeviceCount(&count));
    if (count <= 0) {
        std::fprintf(stderr, "no CUDA devices visible\n");
        return 12;
    }

    int failed = 0;
    std::printf("FP32_SGEMM_CHECK,n=%d,warmup=%d,repeat=%d,min_tflops=%.2f\n", n, warmup, repeat, min_tflops);

    for (int dev = 0; dev < count; ++dev) {
        cudaDeviceProp prop{};
        CHECK_CUDA(cudaGetDeviceProperties(&prop, dev));
        CHECK_CUDA(cudaSetDevice(dev));

        size_t elems = (size_t)n * (size_t)n;
        size_t bytes = elems * sizeof(float);

        float *A = nullptr, *B = nullptr, *C = nullptr;
        CHECK_CUDA(cudaMalloc(&A, bytes));
        CHECK_CUDA(cudaMalloc(&B, bytes));
        CHECK_CUDA(cudaMalloc(&C, bytes));

        CHECK_CUDA(cudaMemset(A, 1, bytes));
        CHECK_CUDA(cudaMemset(B, 2, bytes));
        CHECK_CUDA(cudaMemset(C, 0, bytes));

        cublasHandle_t h;
        CHECK_CUBLAS(cublasCreate(&h));
        CHECK_CUBLAS(cublasSetMathMode(h, CUBLAS_DEFAULT_MATH));

        const float alpha = 1.0f;
        const float beta = 0.0f;

        for (int i = 0; i < warmup; ++i) {
            CHECK_CUBLAS(cublasSgemm(h, CUBLAS_OP_N, CUBLAS_OP_N, n, n, n, &alpha, A, n, B, n, &beta, C, n));
        }
        CHECK_CUDA(cudaDeviceSynchronize());

        cudaEvent_t start, stop;
        CHECK_CUDA(cudaEventCreate(&start));
        CHECK_CUDA(cudaEventCreate(&stop));
        CHECK_CUDA(cudaEventRecord(start));

        for (int i = 0; i < repeat; ++i) {
            CHECK_CUBLAS(cublasSgemm(h, CUBLAS_OP_N, CUBLAS_OP_N, n, n, n, &alpha, A, n, B, n, &beta, C, n));
        }

        CHECK_CUDA(cudaEventRecord(stop));
        CHECK_CUDA(cudaEventSynchronize(stop));

        float ms = 0.0f;
        CHECK_CUDA(cudaEventElapsedTime(&ms, start, stop));

        double sec = (double)ms / 1000.0 / (double)repeat;
        double tflops = (2.0 * (double)n * (double)n * (double)n) / sec / 1.0e12;
        int pass = tflops >= min_tflops;

        std::printf("FP32_TFLOPS,device=%d,bus=%04x:%02x:%02x.0,name=%s,tflops=%.2f,pass=%s\n",
            dev, prop.pciDomainID, prop.pciBusID, prop.pciDeviceID, prop.name, tflops, pass ? "yes" : "no");

        if (!pass) failed = 1;

        cudaEventDestroy(start);
        cudaEventDestroy(stop);
        cublasDestroy(h);
        cudaFree(A);
        cudaFree(B);
        cudaFree(C);
    }

    return failed ? 32 : 0;
}
EOF_CU

"$nvcc_bin" -O3 "$src" -lcublas -o "$bin"
"$bin" "$min_tflops"
