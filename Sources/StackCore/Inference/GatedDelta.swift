import MLX
import MLXNN

// Gated delta-rule update used by Qwen3.5's linear-attention ("Gated DeltaNet") layers.
//
// Ported from mlx-lm (`mlx_lm/models/gated_delta.py`) as carried in mlx-swift-lm's
// `MLXLLM/Models/GatedDelta.swift` (MIT). Differences: the recurrent state has its own dtype
// (the model config declares `mamba_ssm_dtype: float32`) instead of following the activations,
// and the reference operations are kept alongside the kernel so the two can be cross-checked.
//
// Per token and value head:
//     S ← g · S                       (decay, g = exp(−exp(A_log) · softplus(a + dt_bias)))
//     Δ ← (v − S·k) · β               (β = sigmoid(b))
//     S ← S + k ⊗ Δ                   (delta rule: erase what k predicts, write the correction)
//     y ← S · q
// State layout is [B, Hv, Dv, Dk]; q and k have Hk heads and are shared by Hv/Hk value heads.
public enum GatedDelta {

    /// Per-head, per-token decay in (0, 1), computed in float32.
    public static func decay(aLog: MLXArray, a: MLXArray, dtBias: MLXArray) -> MLXArray {
        exp(-exp(aLog.asType(.float32)) * softplus(a.asType(.float32) + dtBias.asType(.float32)))
    }

    // MARK: Metal kernel

    private final class KernelBox: Sendable {
        static let shared = KernelBox()
        let kernel: MLXFast.MLXFastKernel

        private init() {
            let source = """
                auto n = thread_position_in_grid.z;
                auto b_idx = n / Hv;
                auto hv_idx = n % Hv;
                auto hk_idx = hv_idx / (Hv / Hk);
                constexpr int n_per_t = Dk / 32;

                // q, k: [B, T, Hk, Dk]
                auto q_ = q + b_idx * T * Hk * Dk + hk_idx * Dk;
                auto k_ = k + b_idx * T * Hk * Dk + hk_idx * Dk;

                // v, y: [B, T, Hv, Dv]
                auto v_ = v + b_idx * T * Hv * Dv + hv_idx * Dv;
                y += b_idx * T * Hv * Dv + hv_idx * Dv;

                auto dk_idx = thread_position_in_threadgroup.x;
                auto dv_idx = thread_position_in_grid.y;

                // g, beta: [B, T, Hv]
                auto g_ = g + b_idx * T * Hv;
                auto beta_ = beta + b_idx * T * Hv;

                // state_in, state_out: [B, Hv, Dv, Dk]
                auto i_state = state_in + (n * Dv + dv_idx) * Dk;
                auto o_state = state_out + (n * Dv + dv_idx) * Dk;

                float state[n_per_t];
                for (int i = 0; i < n_per_t; ++i) {
                  auto s_idx = n_per_t * dk_idx + i;
                  state[i] = static_cast<float>(i_state[s_idx]);
                }

                for (int t = 0; t < T; ++t) {
                  float kv_mem = 0.0f;
                  for (int i = 0; i < n_per_t; ++i) {
                    auto s_idx = n_per_t * dk_idx + i;
                    state[i] = state[i] * static_cast<float>(g_[hv_idx]);
                    kv_mem += state[i] * static_cast<float>(k_[s_idx]);
                  }
                  kv_mem = simd_sum(kv_mem);

                  float delta = (static_cast<float>(v_[dv_idx]) - kv_mem) * static_cast<float>(beta_[hv_idx]);

                  float out = 0.0f;
                  for (int i = 0; i < n_per_t; ++i) {
                    auto s_idx = n_per_t * dk_idx + i;
                    state[i] = state[i] + static_cast<float>(k_[s_idx]) * delta;
                    out += state[i] * static_cast<float>(q_[s_idx]);
                  }
                  out = simd_sum(out);
                  if (thread_index_in_simdgroup == 0) {
                    y[dv_idx] = static_cast<InT>(out);
                  }
                  // Next time step
                  q_ += Hk * Dk;
                  k_ += Hk * Dk;
                  v_ += Hv * Dv;
                  y += Hv * Dv;
                  g_ += Hv;
                  beta_ += Hv;
                }
                for (int i = 0; i < n_per_t; ++i) {
                  auto s_idx = n_per_t * dk_idx + i;
                  o_state[s_idx] = static_cast<StT>(state[i]);
                }
                """
            kernel = MLXFast.metalKernel(
                name: "gated_delta_step_f32state",
                inputNames: ["q", "k", "v", "g", "beta", "state_in", "T"],
                outputNames: ["y", "state_out"],
                source: source)
        }
    }

    /// One dispatch over all `T` tokens. Requires `Dk` to be a multiple of 32.
    /// - q, k: `[B, T, Hk, Dk]`; v: `[B, T, Hv, Dv]`; g, beta: `[B, T, Hv]`; state: `[B, Hv, Dv, Dk]`.
    public static func update(
        q: MLXArray, k: MLXArray, v: MLXArray, g: MLXArray, beta: MLXArray, state: MLXArray
    ) -> (y: MLXArray, state: MLXArray) {
        let B = k.dim(0), T = k.dim(1), Hk = k.dim(2), Dk = k.dim(3)
        let Hv = v.dim(2), Dv = v.dim(3)
        precondition(Dk % 32 == 0 && Hv % Hk == 0, "unsupported gated-delta head shape")
        let outputs = KernelBox.shared.kernel(
            [q, k, v, g, beta, state, MLXArray(T)],
            template: [("InT", q.dtype), ("StT", state.dtype), ("Dk", Dk), ("Dv", Dv), ("Hk", Hk), ("Hv", Hv)],
            grid: (32, Dv, B * Hv),
            threadGroup: (32, 4, 1),
            outputShapes: [[B, T, Hv, Dv], state.shape],
            outputDTypes: [q.dtype, state.dtype])
        return (outputs[0], outputs[1])
    }

    // MARK: Reference operations (slow; used to validate the kernel)

    public static func updateOps(
        q: MLXArray, k: MLXArray, v: MLXArray, g: MLXArray, beta: MLXArray, state: MLXArray
    ) -> (y: MLXArray, state: MLXArray) {
        let T = q.dim(1), Hk = q.dim(2), Hv = v.dim(2)
        var q = q, k = k
        if Hv > Hk {
            q = repeated(q, count: Hv / Hk, axis: -2)
            k = repeated(k, count: Hv / Hk, axis: -2)
        }
        var s = state.asType(.float32)
        var ys: [MLXArray] = []
        for t in 0 ..< T {
            let qT = q[0..., t].asType(.float32), kT = k[0..., t].asType(.float32)
            let vT = v[0..., t].asType(.float32)
            let gT = g[0..., t].asType(.float32), bT = beta[0..., t].asType(.float32)
            s = s * expandedDimensions(gT, axes: [2, 3])
            let kvMem = (s * expandedDimensions(kT, axis: -2)).sum(axis: -1)
            let delta = (vT - kvMem) * expandedDimensions(bT, axis: -1)
            s = s + expandedDimensions(kT, axis: -2) * expandedDimensions(delta, axis: -1)
            ys.append((s * expandedDimensions(qT, axis: -2)).sum(axis: -1).asType(v.dtype))
        }
        return (MLX.stacked(ys, axis: 1), s.asType(state.dtype))
    }
}
