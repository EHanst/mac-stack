// Kokoro Metal compute kernels
// Compiled at build time: xcrun metal Kernels.metal -o default.air && xcrun metallib default.air -o default.metallib
// The .metallib is bundled in Contents/Resources — source is never shipped.

#include <metal_stdlib>
using namespace metal;

// Placeholder kernel: cosine similarity for embedding distance computation.
// The primary similarity search runs in sqlite-vec; this kernel is available
// for future bulk re-ranking passes over large candidate sets.
kernel void cosineSimilarity(
    device const float* queryVec   [[ buffer(0) ]],
    device const float* corpusVecs [[ buffer(1) ]],
    device float*       distances  [[ buffer(2) ]],
    constant uint&      dimension  [[ buffer(3) ]],
    constant uint&      corpusSize [[ buffer(4) ]],
    uint                gid        [[ thread_position_in_grid ]]
) {
    if (gid >= corpusSize) return;

    float dot = 0.0f, qNorm = 0.0f, cNorm = 0.0f;
    for (uint i = 0; i < dimension; i++) {
        float q = queryVec[i];
        float c = corpusVecs[gid * dimension + i];
        dot   += q * c;
        qNorm += q * q;
        cNorm += c * c;
    }
    float denom = sqrt(qNorm) * sqrt(cNorm);
    distances[gid] = (denom > 1e-9f) ? (1.0f - dot / denom) : 1.0f;
}
