#include "CSearchMath.h"
#include <string.h>

void digup_search_half_to_float_portable(const uint16_t *source, float *destination, size_t count) {
    for (size_t index = 0; index < count; ++index) {
        uint32_t half = source[index], sign = (half & 0x8000u) << 16;
        uint32_t exponent = (half >> 10) & 31u, mantissa = half & 1023u, bits;
        if (exponent == 0) {
            float subnormal = (float) mantissa * (1.0f / 16777216.0f);
            memcpy(&bits, &subnormal, sizeof(bits));
            bits |= sign;
        } else if (exponent == 31) {
            bits = sign | 0x7f800000u | (mantissa << 13);
            if (mantissa) bits |= 0x00400000u; // Quiet NaNs while preserving their payload/sign.
        } else {
            bits = sign | ((exponent + 112u) << 23) | (mantissa << 13);
        }
        memcpy(destination + index, &bits, sizeof(bits));
    }
}

#if (defined(__x86_64__) || defined(_M_X64)) && (defined(__clang__) || defined(__GNUC__))
#include <immintrin.h>
#if defined(_WIN32)
#include <intrin.h>
#else
#include <cpuid.h>
#endif

// Keep the generic executable usable on older x64 CPUs. Check CPU AND OS support before executing AVX/F16C.
__attribute__((target("xsave"))) static int has_f16c(void) {
    unsigned int ecx;
#if defined(_WIN32)
    int registers[4];
    __cpuidex(registers, 1, 0);
    ecx = (unsigned int) registers[2];
#else
    unsigned int eax, ebx, edx;
    if (!__get_cpuid(1, &eax, &ebx, &ecx, &edx)) return 0;
#endif
    const unsigned int required = (1u << 27) | (1u << 28) | (1u << 29);
    if ((ecx & required) != required) return 0;
    return (_xgetbv(0) & 6u) == 6u;
}

__attribute__((target("avx,f16c"))) static void convert_f16c(const uint16_t *source, float *destination, size_t count) {
    size_t index = 0;
    for (; index + 8 <= count; index += 8) {
        __m128i halves = _mm_loadu_si128((const __m128i *) (source + index));
        _mm256_storeu_ps(destination + index, _mm256_cvtph_ps(halves));
    }
    _mm256_zeroupper();
    digup_search_half_to_float_portable(source + index, destination + index, count - index);
}
#endif

void digup_search_half_to_float(const uint16_t *source, float *destination, size_t count) {
#if (defined(__x86_64__) || defined(_M_X64)) && (defined(__clang__) || defined(__GNUC__))
    if (has_f16c()) { convert_f16c(source, destination, count); return; }
#endif
    digup_search_half_to_float_portable(source, destination, count);
}
