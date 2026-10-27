# Resource profiles and device counters

This stage is based on main at 4aa0e49. It does not change the model, vector fingerprints,
selected accelerator, index scope or retained vectors.

## Background resource profiles

Settings stores acceleration.resourceProfile independently of acceleration.jobs. Existing settings
default to balanced, including custom --settings files. Applying the preference uses the existing
Apply and Restart flow. The CLI accepts DIGUP_RESOURCE_PROFILE=quiet|balanced|faster.
Unknown future profile strings remain intact when settings are saved or reloaded. They block
inference with a readable error until a supported profile is selected; other preferences are retained.

- Quiet admits one background GPU model owner.
- Balanced preserves the existing job limit.
- Faster permits the configured upper limit, subject to the existing three-operation ceiling and
  verified free-memory admission. It never raises an explicitly selected one- or two-job limit.

Balanced and Faster currently share the same maximum GPU owner count. There is no calibrated
throughput auto-tuner or measured Faster speed claim. Further preparation/batch tuning requires
the paired physical-device protocol before changing defaults. Quiet reduces background admission;
it is not a GPU power or clock limit.

All requests retain the shared OS admission leases, reserved query residency, startup mutex,
foreground priority and one-second quiet period. An operation already submitted completes safely.
OpenVINO NPU remains single-owner; Metal keeps its existing path. Host preprocessing, storage and
similarity scoring keep their established CPU boundary, and model arithmetic stays accelerator-only.

## Optional NVIDIA device counters

Activity receives cached schema-1 telemetry with explicit source, device identity, sample time,
age, units and device scope. Sampling starts only after a verified accelerator-only CUDA receipt
and recent Activity demand. The snapshot path only reads/updates bounded memory.

On Windows, the sampler invokes the driver's nvidia-smi.exe from the Windows system directory
returned by Windows. It never searches PATH or runs a shell. It requests the exact physical GPU UUID
and rejects replies for another UUID. Each subprocess has a two-second deadline and a 4 KiB output
limit. The metrics child joins DigUp's worker job, so exit/update cleanup ends it.
Readings are at most once per second, failures retry no faster than ten seconds, and no more
than 120 successful samples are retained in memory.

The reported GPU utilization and memory are device-wide, including other applications. They are not
DigUp-only occupancy, execution verification or an estimate derived from worker duration. Unsupported
fields remain null; stale samples retain their age. Missing drivers/tools, invalid UUIDs and counter
failures do not affect indexing, search, launching or accelerator selection.

AMD counters remain unavailable: the current Vulkan identity cannot yet be proven equivalent to an
ADLX adapter identity. A later AMD provider must establish PCI/LUID correlation and use capability
checks before publishing readings. Names and enumeration ordinals are insufficient. The same honest
unavailable state applies to NPU counters and the current non-Windows provider.

Provider references:
- NVIDIA driver queries: https://docs.nvidia.com/deploy/nvidia-smi/
- AMD performance API: https://gpuopen.com/manuals/adlx/adlx-sdk-references/adlx-interfaces/performance-monitoring/iadlxgpumetrics/gpuusage/

## Validation

Native tests cover legacy/default settings, explicit limits, NPU/Metal bounds, invalid profiles,
verified-UUID admission, wrong-device replies, unsupported/nonfinite counters, response bounds,
snapshot responsiveness and stale-device suppression. Unix tests exercise actual process deadlines
and output limits without a driver or model.

Swift tests cover profile validation and effective background limits. Existing admission, foreground,
pool, CPU-rejection and index compatibility checks remain required. Hosted tests and injected
counter fixtures do not establish real vendor readings, GPU throughput, VRAM fit or NPU behavior.
Physical RX 7900 XTX, supported CUDA devices and Intel Ultra 7 258V acceptance remain open.
