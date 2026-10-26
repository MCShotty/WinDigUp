#include "ggml.h"
#include "ggml-alloc.h"
#include "ggml-backend.h"
#include <cstdio>

// Runs on a machine without any GPU. It must reject arithmetic before changing the output buffer.
int main(int argc, char ** argv) {
    if (!ggml_backend_accelerator_only()) { return 1; }
    if (ggml_backend_accelerator_policy_version() != 2) { return 8; }
    if (ggml_backend_vulkan_vendor_allowed(0x10de)) { return 9; }
    if (!ggml_backend_vulkan_vendor_allowed(0x1002) || !ggml_backend_vulkan_vendor_allowed(0x8086)) { return 10; }
    if (argc > 1) { ggml_backend_load_all_from_path(argv[1]); } else { ggml_backend_load_all(); }
    auto backend = ggml_backend_init_by_type(GGML_BACKEND_DEVICE_TYPE_CPU, nullptr);
    if (!backend) { return 7; }
    auto ctx = ggml_init({16 * 1024 * 1024, nullptr, true});
    auto input = ggml_new_tensor_1d(ctx, GGML_TYPE_F32, 4);
    auto result = ggml_scale(ctx, input, 2.0f);
    ggml_set_name(result, "must-never-compute-on-cpu");
    auto graph = ggml_new_graph(ctx);
    ggml_build_forward_expand(graph, result);
    auto buffer = ggml_backend_alloc_ctx_tensors(ctx, backend);
    const float ones[] = {1, 1, 1, 1};
    const float sentinel[] = {-99, -99, -99, -99};
    ggml_backend_tensor_set(input, ones, 0, sizeof(ones));
    ggml_backend_tensor_set(result, sentinel, 0, sizeof(sentinel));
    if (ggml_backend_graph_compute(backend, graph) != GGML_STATUS_FAILED) { return 2; }
    if (ggml_backend_graph_compute_async(backend, graph) != GGML_STATUS_FAILED) { return 3; }
    auto sched = ggml_backend_sched_new(&backend, nullptr, 1, 32, false, true);
    if (ggml_backend_sched_graph_compute(sched, graph) != GGML_STATUS_FAILED) { return 4; }
    float actual[4];
    ggml_backend_tensor_get(result, actual, 0, sizeof(actual));
    for (float value : actual) { if (value != -99) { return 5; } }
    // Host storage views are metadata; they do not invoke a CPU numerical kernel.
    auto view = ggml_view_1d(ctx, input, 4, 0);
    auto metadata = ggml_new_graph(ctx);
    ggml_build_forward_expand(metadata, view);
    if (ggml_backend_graph_compute(backend, metadata) != GGML_STATUS_SUCCESS) { return 6; }
    ggml_backend_sched_free(sched);
    ggml_backend_buffer_free(buffer);
    ggml_free(ctx);
    ggml_backend_free(backend);
    std::puts("PASS: direct, asynchronous and scheduled CPU arithmetic denied; output untouched");
}
