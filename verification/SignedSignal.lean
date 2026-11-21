import Formalism.SizeWindowBrackets.ChainSlopeWindows.LipschitzWeightAndMinimum

/-!
# A one-sided estimate for the finite-group signal

Alpöge's `CR.signal_term` estimates the three nontrivial terms of `Gsig` separately.
Their signs allow one to use an upper bound on their real combination at the base point.
Taking `A = x * y` in `lipschitz_weight_all` cancels the linear term `z * ell ψ`
before moving to a nearby node. The resulting additive cost is uniform in `D` and `ell`.
-/

noncomputable section

namespace Verification.SignedSignal

open Formalism Formalism.D5 Formalism.LogFactorialMertensBounds
open Formalism.LFunctionChainParameters.characterSumData
open Formalism.LFunctionChainParameters.ThickSetMeanBounds

variable {H : Type} [AddCommGroup H] [Fintype H] [DecidableEq H]
variable (D : ArithData H) (ell : AddChar (E0 × H) ℂ → ℂ)

/-- The ordinary zeta term minus the real part of the signal. -/
def correction (z : ℝ) : ℝ :=
  (GPsi D ell chC z).re + (GPsi D ell chpsC z).re - (GPsi D ell psC z).re

private theorem signal_eq (z : ℝ) : (Gsig D ell z).re = Gz z - correction D ell z := by
  have h : GPsi D ell 0 z = (Gz z : ℂ) := by simp [GPsi]
  simp only [Gsig, h, Complex.add_re, Complex.sub_re, Complex.ofReal_re, correction]
  ring

private theorem rescaled (ψ : AddChar (E0 × H) ℂ) {x y : ℝ} (hx : 3 ≤ x) (hy : |y - x| ≤ 1) :
    |x * (GPsi D ell ψ y).re - y * (GPsi D ell ψ x).re| ≤ 4 * x := by
  obtain ⟨hlo, hhi⟩ := abs_le.mp hy
  have hx₀ : 0 < x := by linarith
  have hy₀ : 0 < y := by linarith
  have scale : 3 * (x * y) / min x y = 3 * max x y := by
    rcases le_total x y with h | h
    · rw [min_eq_left h, max_eq_right h]
      field_simp
    · rw [min_eq_right h, max_eq_left h]
      field_simp
  have h := lipschitz_weight_all H D ell ψ (x * y) x y (mul_pos hx₀ hy₀) hx₀ hy₀
  rw [show x * y / x = y by field_simp, show x * y / y = x by field_simp, scale, abs_sub_comm x y] at h
  have hmax : max x y ≤ x + 1 := max_le (by linarith) (by linarith)
  have hc : 0 ≤ 3 * max x y := by linarith [le_max_left x y]
  have hr := (Complex.abs_re_le_norm _).trans (h.trans (mul_le_mul_of_nonneg_left hy hc))
  simp only [Complex.sub_re, Complex.mul_re, Complex.ofReal_re, Complex.ofReal_im,
    zero_mul, sub_zero, mul_one] at hr
  linarith

private theorem correction_near {x y B θ : ℝ} (hx : 3 ≤ x) (hy : |y - x| ≤ 1)
    (hB : 0 ≤ B) (hθ : θ ≤ 1) (h : correction D ell x ≤ B * x ^ θ) :
    correction D ell y ≤ B * x ^ θ + B + 12 := by
  obtain ⟨hlo, hhi⟩ := abs_le.mp hy
  have hx₀ : 0 < x := by linarith
  have hy₀ : 0 ≤ y := by linarith
  have hd := (abs_le.mp (rescaled D ell chC hx hy)).2
  have hqd := (abs_le.mp (rescaled D ell chpsC hx hy)).2
  have hq := (abs_le.mp (rescaled D ell psC hx hy)).1
  have signed : x * correction D ell y ≤ y * correction D ell x + 12 * x := by
    unfold correction
    linarith only [hd, hqd, hq]
  have hp : x ^ θ ≤ x := by
    simpa only [Real.rpow_one] using Real.rpow_le_rpow_of_exponent_le (by linarith : 1 ≤ x) hθ
  have hpos : 0 ≤ B * x ^ θ := mul_nonneg hB (Real.rpow_nonneg hx₀.le _)
  apply (mul_le_mul_iff_right₀ hx₀).mp
  nlinarith only [signed, mul_le_mul_of_nonneg_left h hy₀,
    mul_le_mul_of_nonneg_right (show y ≤ x + 1 by linarith) hpos, mul_le_mul_of_nonneg_left hp hB]

/-- An upper bound on the signed correction at `x` gives a lower bound on the signal
at every nearby `y`. The cost `B + 12 + K0` is independent of the character data. -/
theorem signal_lower {x y B θ : ℝ} (hx : 3 ≤ x) (hy : |y - x| ≤ 1)
    (hB : 0 ≤ B) (hθ : θ ≤ 1) (h : correction D ell x ≤ B * x ^ θ) :
    Gz x - B * x ^ θ - (B + 12 + K0) ≤ (Gsig D ell y).re := by
  have hy₁ := (abs_le.mp hy).1
  have hl : |Gz y - Gz x| ≤ K0 * |y - x| :=
    lip_upto (⌊x⌋₊ + ⌊y⌋₊) x y (by linarith)
      (by push_cast; linarith [Nat.lt_floor_add_one x, Nat.cast_nonneg (α := ℝ) ⌊y⌋₊])
      (by linarith)
      (by push_cast; linarith [Nat.lt_floor_add_one y, Nat.cast_nonneg (α := ℝ) ⌊x⌋₊])
  have hz := (abs_le.mp (hl.trans (mul_le_mul_of_nonneg_left hy lipschitzConst_nonneg))).1
  rw [signal_eq]
  linarith [correction_near D ell hx hy hB hθ h]

/-- The three value bounds in `ValuesAtX` imply the single signed hypothesis. -/
theorem of_values {x ε CL : ℝ} (h : ValuesAtX D ell x ε CL) :
    correction D ell x ≤ 3 * x ^ (1 / 2 + ε) := by
  have r (z : ℂ) : |z.re| ≤ ‖z‖ := Complex.abs_re_le_norm _
  have hd := (abs_le.mp ((r _).trans (h chC (Or.inr (Or.inl rfl))).1)).2
  have hqd := (abs_le.mp ((r _).trans (h chpsC (Or.inr (Or.inr rfl))).1)).2
  have hq := (abs_le.mp ((r _).trans (h psC (Or.inl rfl)).1)).1
  unfold correction
  linarith

/-- The last inequality in the submitted `SizeWindows` already absorbs the transport
cost `15 + K0 = 22 + log 4` when the signed coefficient is three. -/
theorem signal_lower_of_sizeWindows {C ε x y b k aE Err : ℝ} {n nT nT2 m : ℕ}
    (sizes : SizeWindows C ε x n nT nT2 m b k aE Err) (hε : ε ≤ 1 / 2) (hy : |y - x| ≤ 1)
    (h : correction D ell x ≤ 3 * x ^ (1 / 2 + ε)) :
    Gz x - 4 * x ^ (1 / 2 + ε) ≤ (Gsig D ell y).re := by
  obtain ⟨hx, he, _, _, _, _, _, _, _, _, _, _, _, _, _, hbig⟩ := sizes
  have hk : 15 + K0 ≤ 26 := by
    unfold K0
    linarith [Real.log_le_sub_one_of_pos (by norm_num : (0 : ℝ) < 4)]
  have absorb : 15 + K0 ≤ x ^ (1 / 2 + ε) :=
    hk.trans (hbig.trans (Real.rpow_le_rpow_of_exponent_le (by linarith) (by linarith)))
  have hs := signal_lower D ell hx hy (by norm_num : (0 : ℝ) ≤ 3) (show 1 / 2 + ε ≤ 1 by linarith) h
  linarith only [absorb, hs]

end Verification.SignedSignal
end

#print axioms Verification.SignedSignal.signal_lower
#print axioms Verification.SignedSignal.of_values
#print axioms Verification.SignedSignal.signal_lower_of_sizeWindows
