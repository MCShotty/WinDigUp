// Physical CUDA acceptance: real Q8/F32 matrix operations with activations outside FP16 range, plus GPU L2 normalization.
// No CPU model execution. Quantization below prepares fixture weights; expected arithmetic is analytic.
#include "ggml.h"
#include "ggml-backend.h"
#include "ggml-alloc.h"
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

static bool matrix_check(ggml_backend_t backend, ggml_type type) {
    constexpr int inner=256, rows=64, batch=128;
    auto ctx=ggml_init({ggml_tensor_overhead()*16+ggml_graph_overhead_custom(32,false),nullptr,true});
    if (!ctx) { return false; }
    auto w=ggml_new_tensor_2d(ctx,type,inner,rows);
    auto x=ggml_new_tensor_2d(ctx,GGML_TYPE_F32,inner,batch);
    auto result=ggml_mul_mat(ctx,w,x);
    auto normalized=ggml_l2_norm(ctx,result,1e-12f);
    auto graph=ggml_new_graph_custom(ctx,32,false);
    ggml_build_forward_expand(graph,normalized);
    auto buffer=ggml_backend_alloc_ctx_tensors(ctx,backend);
    if (!buffer) { ggml_free(ctx);return false; }
    std::vector<float> weights(inner*rows,1.0f), input(inner*batch,100000.0f);
    if (type==GGML_TYPE_Q8_0) {
        std::vector<unsigned char> quantized(ggml_nbytes(w));
        const auto bytes=ggml_quantize_chunk(type,weights.data(),quantized.data(),0,rows,inner,nullptr);
        if (bytes!=quantized.size()) { ggml_backend_buffer_free(buffer);ggml_free(ctx);return false; }
        ggml_backend_tensor_set(w,quantized.data(),0,quantized.size());
    } else { ggml_backend_tensor_set(w,weights.data(),0,weights.size()*sizeof(float)); }
    ggml_backend_tensor_set(x,input.data(),0,input.size()*sizeof(float));
    bool ok=ggml_backend_graph_compute(backend,graph)==GGML_STATUS_SUCCESS;
    if (ok) {
        std::vector<float> raw(rows*batch), vectors(rows*batch);
        ggml_backend_tensor_get(result,raw.data(),0,raw.size()*sizeof(float));
        ggml_backend_tensor_get(normalized,vectors.data(),0,vectors.size()*sizeof(float));
        for (float value:raw) { ok=ok && std::isfinite(value) && std::abs(value/(inner*100000.0f)-1.0f)<0.002f; }
        for (int n=0;n<batch;n++) {
            double norm=0;
            for (int i=0;i<rows;i++) { float value=vectors[n*rows+i];ok=ok && std::isfinite(value);norm+=double(value)*value; }
            ok=ok && std::abs(norm-1.0)<0.005;
        }
    }
    ggml_backend_buffer_free(buffer);ggml_free(ctx);
    return ok;
}

int main(int argc,char **argv) {
    if (!ggml_backend_accelerator_only() || ggml_backend_accelerator_policy_version()!=2 || ggml_backend_vulkan_vendor_allowed(0x10de)) { return 1; }
    if (argc<2) { std::fprintf(stderr,"usage: cuda-policy-check <installed helper directory>\n");return 2; }
    ggml_backend_load_all_from_path(argv[1]);
    auto reg=ggml_backend_reg_by_name("CUDA");
    if (!reg) { std::fprintf(stderr,"CUDA unavailable: this check requires a physical supported NVIDIA GPU and driver\n");return 3; }
    ggml_backend_dev_t device=nullptr;
    ggml_accelerator_device_info info{};
    const char * requested=std::getenv("DIGUP_GPU");
    for (size_t i=0;i<ggml_backend_reg_dev_count(reg);i++) {
        auto candidate=ggml_backend_reg_dev_get(reg,i);
        if (!ggml_backend_dev_accelerator_info(candidate,&info) || info.policy_version!=2 || info.vendor_id!=0x10de || (info.compute_capability!=75 && info.compute_capability!=86 && info.compute_capability!=89 && info.compute_capability!=120) || info.driver_version<12090) { continue; }
        if (requested && *requested && std::strcmp(requested,info.stable_id) && std::strcmp(requested,ggml_backend_dev_name(candidate))) { continue; }
        device=candidate;break;
    }
    if (!device) { std::fprintf(stderr,"The requested supported CUDA device is unavailable\n");return 4; }
    auto backend=ggml_backend_dev_init(device,nullptr);
    if (!backend) { return 5; }
    const bool ok=matrix_check(backend,GGML_TYPE_F32) && matrix_check(backend,GGML_TYPE_Q8_0);
    ggml_backend_free(backend);
    if (!ok) { std::fprintf(stderr,"CUDA large-activation or normalization check failed\n");return 6; }
    std::printf("{\"passed\":true,\"backend\":\"cuda\",\"deviceId\":\"%s\",\"computeCapability\":%d,\"driverAPI\":%d,\"runtimeAPI\":%d,\"precision\":\"cuda-fp32-v1\"}\n",info.stable_id,info.compute_capability,info.driver_version,info.runtime_version);
    return 0;
}
