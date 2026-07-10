#include <cuda_runtime.h>

#include <algorithm>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <vector>

#include "predicate.hpp"

namespace {

constexpr unsigned int kDefaultCapacity = 4096;
constexpr int kThreadsPerBlock = 256;

bool parse_u64(const char* text, std::uint64_t* value) {
    if (text == nullptr || *text == '\0' || *text == '-') {
        return false;
    }
    errno = 0;
    char* end = nullptr;
    const unsigned long long parsed = std::strtoull(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0') {
        return false;
    }
    *value = static_cast<std::uint64_t>(parsed);
    return true;
}

bool parse_u32(const char* text, unsigned int* value) {
    std::uint64_t parsed = 0;
    if (!parse_u64(text, &parsed) ||
        parsed > std::numeric_limits<unsigned int>::max()) {
        return false;
    }
    *value = static_cast<unsigned int>(parsed);
    return true;
}

bool cuda_ok(cudaError_t result, const char* operation) {
    if (result == cudaSuccess) {
        return true;
    }
    std::fprintf(stderr, "CUDA_ERROR operation=%s detail=%s\n", operation,
                 cudaGetErrorString(result));
    return false;
}

__global__ void search_range(std::uint64_t start, std::uint64_t count,
                             std::uint64_t seed, unsigned int zero_bits,
                             std::uint64_t* matches,
                             unsigned long long* match_count,
                             unsigned int capacity) {
    const std::uint64_t first =
        static_cast<std::uint64_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    const std::uint64_t stride =
        static_cast<std::uint64_t>(blockDim.x) * gridDim.x;
    for (std::uint64_t offset = first; offset < count; offset += stride) {
        const std::uint64_t candidate = start + offset;
        if (range_search::matches(candidate, seed, zero_bits)) {
            const unsigned long long slot = atomicAdd(match_count, 1ULL);
            if (slot < capacity) {
                matches[slot] = candidate;
            }
        }
    }
}

}  // namespace

int main(int argc, char** argv) {
    if (argc < 3 || argc > 6) {
        std::fprintf(stderr,
                     "usage: %s START COUNT [SEED] [ZERO_BITS] [MATCH_CAPACITY]\n",
                     argv[0]);
        return 64;
    }

    std::uint64_t start = 0;
    std::uint64_t count = 0;
    std::uint64_t seed = 0;
    unsigned int zero_bits = 20;
    unsigned int capacity = kDefaultCapacity;

    if (!parse_u64(argv[1], &start) || !parse_u64(argv[2], &count) || count == 0 ||
        (argc >= 4 && !parse_u64(argv[3], &seed)) ||
        (argc >= 5 && !parse_u32(argv[4], &zero_bits)) ||
        (argc >= 6 && !parse_u32(argv[5], &capacity))) {
        std::fprintf(stderr, "INPUT_ERROR malformed numeric argument\n");
        return 64;
    }
    if (zero_bits == 0 || zero_bits > 63 || capacity == 0) {
        std::fprintf(stderr,
                     "INPUT_ERROR ZERO_BITS must be 1..63 and MATCH_CAPACITY must be positive\n");
        return 64;
    }
    if (count - 1ULL > std::numeric_limits<std::uint64_t>::max() - start) {
        std::fprintf(stderr, "INPUT_ERROR range overflows uint64\n");
        return 64;
    }

    int device = 0;
    cudaDeviceProp properties{};
    if (!cuda_ok(cudaGetDevice(&device), "cudaGetDevice") ||
        !cuda_ok(cudaGetDeviceProperties(&properties, device),
                 "cudaGetDeviceProperties")) {
        return 70;
    }

    std::uint64_t* device_matches = nullptr;
    unsigned long long* device_match_count = nullptr;
    if (!cuda_ok(cudaMalloc(&device_matches,
                            static_cast<std::size_t>(capacity) * sizeof(std::uint64_t)),
                 "cudaMalloc(matches)") ||
        !cuda_ok(cudaMalloc(&device_match_count, sizeof(unsigned long long)),
                 "cudaMalloc(match_count)")) {
        cudaFree(device_matches);
        cudaFree(device_match_count);
        return 70;
    }
    if (!cuda_ok(cudaMemset(device_match_count, 0, sizeof(unsigned long long)),
                 "cudaMemset(match_count)")) {
        cudaFree(device_matches);
        cudaFree(device_match_count);
        return 70;
    }

    const std::uint64_t blocks_needed =
        ((count - 1ULL) / static_cast<std::uint64_t>(kThreadsPerBlock)) + 1ULL;
    const std::uint64_t preferred_blocks =
        static_cast<std::uint64_t>(std::max(properties.multiProcessorCount, 1)) * 32ULL;
    const int blocks = static_cast<int>(std::min(blocks_needed, preferred_blocks));

    search_range<<<blocks, kThreadsPerBlock>>>(start, count, seed, zero_bits,
                                               device_matches, device_match_count,
                                               capacity);
    if (!cuda_ok(cudaGetLastError(), "kernel launch") ||
        !cuda_ok(cudaDeviceSynchronize(), "kernel synchronize")) {
        cudaFree(device_matches);
        cudaFree(device_match_count);
        return 70;
    }

    unsigned long long total_matches = 0;
    if (!cuda_ok(cudaMemcpy(&total_matches, device_match_count,
                            sizeof(unsigned long long), cudaMemcpyDeviceToHost),
                 "cudaMemcpy(match_count)")) {
        cudaFree(device_matches);
        cudaFree(device_match_count);
        return 70;
    }
    if (total_matches > capacity) {
        std::fprintf(stderr,
                     "CAPACITY_ERROR matches=%llu capacity=%u; no partial result emitted\n",
                     total_matches, capacity);
        cudaFree(device_matches);
        cudaFree(device_match_count);
        return 75;
    }

    std::vector<std::uint64_t> host_matches(static_cast<std::size_t>(total_matches));
    if (total_matches > 0 &&
        !cuda_ok(cudaMemcpy(host_matches.data(), device_matches,
                            static_cast<std::size_t>(total_matches) *
                                sizeof(std::uint64_t),
                            cudaMemcpyDeviceToHost),
                 "cudaMemcpy(matches)")) {
        cudaFree(device_matches);
        cudaFree(device_match_count);
        return 70;
    }

    cudaFree(device_matches);
    cudaFree(device_match_count);

    std::sort(host_matches.begin(), host_matches.end());
    for (const std::uint64_t match : host_matches) {
        std::printf("MATCH value=%llu\n",
                    static_cast<unsigned long long>(match));
    }
    std::fprintf(stderr,
                 "COVERAGE start=%llu count=%llu matches=%llu device=%d zero_bits=%u\n",
                 static_cast<unsigned long long>(start),
                 static_cast<unsigned long long>(count), total_matches, device,
                 zero_bits);
    return 0;
}
