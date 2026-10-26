#ifndef DIGUP_SEARCH_MATH_H
#define DIGUP_SEARCH_MATH_H
#include <stddef.h>
#include <stdint.h>

// Stored search vectors -> host scoring scratch space. These functions never execute model inference.
// Input/output buffers must not overlap. All finite binary16 values convert exactly, including signed zero.
void digup_search_half_to_float(const uint16_t *source, float *destination, size_t count);
void digup_search_half_to_float_portable(const uint16_t *source, float *destination, size_t count);
#endif
