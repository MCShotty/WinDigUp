# Evaluating embedding models

EmbeddingGemma 2 remains the production model. This work adds a reproducible model-only
retrieval runner and a conservative evidence comparison. It does not change model files,
dimensions, prompts, thresholds, fingerprints, indexes or accelerator selection in DigUp.
No alternative has passed physical-device acceptance.

## Candidate status

[The candidate inventory](../evals/model-candidates.json) records source links, licensing
review and known capability gaps. Pin exact revisions and check downloaded checksums before
testing any candidate.

- [EmbeddingGemma 2](https://ai.google.dev/gemma/docs/embeddinggemma/model_card_2) is the current
  Apache 2.0 baseline. Its text, vision and audio encoders share a 768-dimensional space.
- [Qwen3-VL-Embedding-2B](https://huggingface.co/Qwen/Qwen3-VL-Embedding-2B) is an Apache 2.0
  text/image/video candidate. The model card does not list audio. It is not a complete
  replacement, and its compatibility with DigUp's pinned runtime and NPU export is unvalidated.
- Omni-Embed-Nemotron and e5-omni remain excluded pending governing-license review. Model-card
  metadata alone is insufficient permission to redistribute weights or a derivative runtime.

Published benchmark scores do not establish DigUp relevance or speed. Research candidates
are never silently downloaded, enabled, or substituted for an unavailable selected model.
A candidate needs a separately implemented and tested strict worker before this runner can use it.
The current shipped helper deliberately loads only the existing model.

## Collect model-only evidence

Quit DigUp and competing neural workloads. Use installed helpers and real model files on the
same recorded physical machine. Discover the stable device ID with accelerator --list --json.
The output must be a new disposable directory, never an existing index.

For example in PowerShell:

    python scripts/evaluate-embedding-model.py --helper "C:\\DigUp-baseline\\helper\\digup.exe" --models "D:\\DigUpModels" --backend amd-vulkan --device "STABLE_DEVICE_ID" --machine-id "RX7900XTX-reference" --corpus evals/model-evaluation.example.json --output "D:\\ModelEvidence\\baseline-smoke"

The included corpus has manually authored, synthetic purpose queries against attributed public
application/settings descriptions. It is a working smoke test, not a real installed catalog,
held-out benchmark, all-modality acceptance suite, or hardware result. Its comparison remains
incomplete regardless of favorable numbers. The English/Arabic/Bengali judgments should be
reviewed by fluent readers before inclusion in a held-out acceptance corpus.

Use --backend nvidia-cuda with the selected CUDA stable ID. Intel NPU uses --backend openvino-npu,
the configured compatible NPU bundle in --models, and its verified NPU receipt. The runner forces
one inference owner for comparable worker measurements; it does not tune production concurrency.
Metal also requires an explicit verified device identity.

The runner uses the existing bounded worker protocol, rejects CPU receipts and changed devices,
checks finite normalized output, hashes model artifacts and corpus media, and times five document
passes plus warm query calls. It uses fresh processes for full and text-only contexts. Model
loading is measured separately. Queries do not use the application's query cache.

Text uses DigUp's current document/query/code-query prompts. A candidate with different documented
prompts must supply --prompt-profile path.json containing id, document, query and codeQuery.
Templates accept only {text}, plus {title} in document. Record the complete profile in the report.
This does not install the profile in DigUp. The native helper must independently support and
enforce the reported token profiles and pooling/normalization policy.

Raw stderr/native logs stay local and may contain paths. Report query text is replaced by SHA-256;
document/query IDs and judgments remain visible. Do not share a report until reviewing IDs,
machine labels, logs, and source data for sensitive information. GPU memory and utilization stay
unknown unless separately measured with a supported vendor tool.

## Corpus and report contract

Use schemaVersion 1, origin synthetic or human-judged, split test/tuning/held-out, documents,
and queries. Each document has a unique ID, modality, language, operation and input. Text inputs
are literal text. Image/audio inputs are paths relative to root (relative to the manifest file),
with mandatory SHA-256. A video document is an explicitly pre-extracted frame or audio window;
record its source path/time and extraction recipe in additional manifest fields. The runner
does not decode whole videos or extract PDF pages. Hash the exact prepared assets.

The eight evaluation groups are text, code, image, document, audio, video, application and
windows-settings. Query records contain id, q, modality, language and expected document IDs.
Empty expected lists are unrelated negative queries. Multiple relevant targets are supported;
document recall is reported separately from the fraction of queries finding an answer.

The corpus hash includes judgments, sources and preprocessing fields. Keep tuning and held-out
queries separate. Any changed judgment, input or threshold requires a new report; never rewrite
an earlier result to make a candidate pass. Existing evals/synthetic.json, multilingual.json and
code.json provide useful regression ideas and page/time/line targets, but their generated testbed
does not replace a human-judged real-world held-out corpus.

For acceptance, collect at least 100 distinct warm queries, at least ten positive and five
negative queries in each modality group, and ten positive queries each in at least two
non-English languages. Use real, attributed app metadata and Windows settings with reviewed
purposes, exact-name collisions and unrelated file-oriented queries. Pure embedding evaluation
does not test lexical matching, aliases, mixed-result placement or personalized ranking.

## Compare without adopting

Collect the candidate using the same corpus, device, machine label, threshold policy and token
profiles. Compare the retained JSON reports:

    python scripts/compare-model-evaluations.py baseline/model-evaluation.json candidate/model-evaluation.json --output model-comparison.json

The comparator rejects changed devices, corpus/judgments, machine labels, policies, duplicate
IDs, invalid values and unequal work. It recomputes metrics from ranked IDs. Raw cosine values
from different models are never compared.

Its model-only gate requires recall@10 to improve by at least one percentage point, no modality
or language recall/MRR regression beyond one percentage point, lower warm query p95 and faster
median document encoding. Purpose retrieval must retain precision >=95% and query hit@3 >=80%;
negative-query false positives must remain <=5% per group. These are evaluation gates, not
new production thresholds. The default .60/.08 policy is the existing provisional purpose
threshold applied to this controlled retrieval experiment, not a calibrated universal gate.

This tool intentionally cannot approve production adoption from worker measurements alone.
It returns exit 1 for a rejected candidate and exit 2 for incomplete evidence, always retaining
the baseline. Missing held-out coverage, numerical reference acceptance, full indexing trials
and installed-application checks remain explicit. A matching accelerator-only worker receipt is
a checked runtime assertion, not independent proof that physical hardware executed it.

Complete these additional gates before proposing a model switch:

1. Verify license, redistribution, all supported modalities, native operation coverage and
   numerical agreement against an independently validated reference for that same candidate.
   Do not compare different models' vectors to EmbeddingGemma's reference or regenerate the
   retained baseline corpus merely to pass.
2. Run five alternating paired full-indexing trials with equal completed work on the same
   RX 7900 XTX, recording extraction, I/O, commits, cold load, throughput, foreground latency,
   VRAM, driver, helper/model/runtime hashes and raw logs. Worker document speed alone is
   insufficient. The existing benchmark-index-service.py deliberately requires the same
   model identity for scheduling comparisons and must not be weakened for model comparisons.
3. Run installed file/code, app/settings purpose, alias/collision, image/audio/video, multilingual,
   preview/launch, unavailable-hardware, low-memory and accelerator-only regressions.
4. Validate NVIDIA CUDA and Intel NPU independently. A passing AMD experiment supplies no CUDA
   or NPU evidence. Keep the existing model on every backend that has not passed its gates.

## Shorter EmbeddingGemma vectors

The model card lists 512/256/128-dimensional Matryoshka profiles with a quality tradeoff.
Do not slice/normalize on the host to bypass accelerator postprocessing policy. Implement and
validate a selected-accelerator output profile separately, fingerprint its dimension/policy,
and use an isolated index before evaluating it. Shorter vectors can reduce storage and scoring
cost; they do not by themselves reduce the model's inference time.

Different models/profiles require isolated file, code, app and settings vectors and query caches.
Existing indexes must remain available. Any later switch must show measured benefits and obtain
an explicit user choice before downloading/preparing a replacement index.

## Automated evidence

Model evaluation contracts runs standard-library unit tests and command-line checks without
weights, downloads or physical accelerators. Favorable fixtures cannot become an adoption or
physical-validation claim. Physical AMD/CUDA/NPU model comparisons, real-corpus relevance,
shorter-vector quality and production adoption remain unperformed.
