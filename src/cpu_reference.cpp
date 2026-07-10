#include "predicate.hpp"

#include <algorithm>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <vector>

namespace {

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

}  // namespace

int main(int argc, char** argv) {
    if (argc < 3 || argc > 6) {
        std::fprintf(stderr, "usage: %s START COUNT [SEED] [ZERO_BITS] [MATCH_CAPACITY]\n", argv[0]);
        return 64;
    }

    std::uint64_t start = 0;
    std::uint64_t count = 0;
    std::uint64_t seed = 0;
    std::uint64_t zero_bits_raw = 20;
    std::uint64_t capacity_raw = 4096;
    if (!parse_u64(argv[1], &start) || !parse_u64(argv[2], &count) || count == 0 ||
        (argc >= 4 && !parse_u64(argv[3], &seed)) ||
        (argc >= 5 && !parse_u64(argv[4], &zero_bits_raw)) ||
        (argc >= 6 && !parse_u64(argv[5], &capacity_raw)) ||
        zero_bits_raw == 0 || zero_bits_raw > 63 ||
        capacity_raw == 0 || capacity_raw > std::numeric_limits<unsigned int>::max() ||
        count - 1ULL > std::numeric_limits<std::uint64_t>::max() - start) {
        std::fprintf(stderr, "INPUT_ERROR invalid range, seed, or ZERO_BITS\n");
        return 64;
    }

    unsigned long long matches = 0;
    std::vector<std::uint64_t> found;
    found.reserve(static_cast<std::size_t>(
        std::min<std::uint64_t>(count, capacity_raw)));
    const unsigned int zero_bits = static_cast<unsigned int>(zero_bits_raw);
    for (std::uint64_t offset = 0; offset < count; ++offset) {
        const std::uint64_t candidate = start + offset;
        if (range_search::matches(candidate, seed, zero_bits)) {
            ++matches;
            if (matches > capacity_raw) {
                std::fprintf(stderr,
                             "CAPACITY_ERROR matches>%llu capacity=%llu; no partial result emitted\n",
                             static_cast<unsigned long long>(capacity_raw),
                             static_cast<unsigned long long>(capacity_raw));
                return 75;
            }
            found.push_back(candidate);
        }
    }
    for (const std::uint64_t candidate : found) {
        std::printf("MATCH value=%llu\n",
                    static_cast<unsigned long long>(candidate));
    }
    std::fprintf(stderr,
                 "CPU_COVERAGE start=%llu count=%llu matches=%llu zero_bits=%u\n",
                 static_cast<unsigned long long>(start),
                 static_cast<unsigned long long>(count), matches, zero_bits);
    return 0;
}
