#ifndef DIGUP_GPU_ADMISSION_H
#define DIGUP_GPU_ADMISSION_H
#ifdef __cplusplus
extern "C" {
#endif
typedef struct digup_lease digup_lease;
digup_lease * digup_lease_try(const char *path, int shared);
void digup_lease_release(digup_lease *lease);
double digup_monotonic_seconds(void);
#ifdef __cplusplus
}
#endif
#endif
