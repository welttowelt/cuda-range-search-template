#pragma once

#include <cstdint>

#if defined(__CUDACC__)
#define RANGE_SEARCH_INLINE __host__ __device__ __forceinline__
#else
#define RANGE_SEARCH_INLINE inline
#endif

namespace range_search {

RANGE_SEARCH_INLINE std::uint64_t splitmix64(std::uint64_t value) {
    value += 0x9e3779b97f4a7c15ULL;
    value = (value ^ (value >> 30U)) * 0xbf58476d1ce4e5b9ULL;
    value = (value ^ (value >> 27U)) * 0x94d049bb133111ebULL;
    return value ^ (value >> 31U);
}

RANGE_SEARCH_INLINE bool matches(std::uint64_t candidate, std::uint64_t seed,
                                 unsigned int zero_bits) {
    const std::uint64_t mask = (1ULL << zero_bits) - 1ULL;
    return (splitmix64(candidate ^ seed) & mask) == 0ULL;
}

}  // namespace range_search

#undef RANGE_SEARCH_INLINE
