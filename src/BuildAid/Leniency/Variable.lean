import Lean.Elab.BuiltinCommand
import BuildAid.Leniency.Basic

/-!
`variable` and `omit` that skip what fails, with a warning.

`variable` elaborates its binders only as a check; it stores their syntax in the scope, and every
later declaration elaborates them again, including only the variables it uses. A binder that no
declaration uses therefore leaves no trace in the olean, so import minimization can drop the module
its type needs. The binder then fails, and since it stays in the scope, so does everything after it.
An `omit` naming such a binder fails too.

A skipped binder is always one that no declaration uses: a declaration that used it would mention
its type, and the import would have been kept. (`include` needs no special handling for the same
reason: an included variable is part of every later declaration.)

These elaborators take precedence over the builtin ones (`Lean.Elab.Command.elabVariable`,
`Lean.Elab.Command.elabOmit`). They first run the whole command through the builtin elaborator, so
a command that works behaves exactly as before. Only if it fails do they run it one binder or one
`omit` item at a time, in order, through the builtin elaborator. That is what the builtin
elaborators store anyway: the binder syntax, one by one, which each declaration elaborates together
(`runTermElabM`). Splitting changes only the check `variable` makes when it runs, which elaborates
the command's binders together. An item that fails is undone: the scope is restored, its errors are
reported as warnings, and a warning says that a necessary import may have been removed. The
warnings are governed by `linter.leniency.variable` (see `BuildAid.Leniency.Basic`); when it is off, the
errors are dropped.
-/

namespace BuildAid.Leniency.Variable

open Lean Elab Command

/--
Runs `x`. If it succeeds without errors, keeps its effects and messages and returns `true`.
Otherwise undoes its effect on the scope and returns `false`; with `report? := some (what, ref)`
its errors are kept as warnings and a warning is added at `ref`, otherwise its messages are dropped.
-/
def trial (report? : Option (String × Syntax)) (x : CommandElabM Unit) : CommandElabM Bool := do
  let savedScope ← getScope
  let savedMsgs := (← get).messages
  modify fun s => { s with messages := {} }
  let ok ← try x; pure true catch ex => logException ex; pure false
  let new := (← get).messages
  if ok && !new.hasErrors then
    modify fun s => { s with messages := savedMsgs ++ new }
    return true
  modifyScope fun _ => savedScope
  match report? with
  | none => modify fun s => { s with messages := savedMsgs }
  | some (what, ref) =>
    let opt := linter.leniency.variable
    let kept := BuildAid.Leniency.keep opt (← getOptions) new
    modify fun s => { s with messages := savedMsgs ++ kept }
    BuildAid.Leniency.warn opt ref
      m!"skipped this {what}, which failed to elaborate (its errors are shown as warnings)"
  return false

/-- `variable` through the builtin `elabVariable`: the whole command if it succeeds (exactly the
builtin behavior), otherwise one binder at a time, skipping binders that fail. -/
@[command_elab Lean.Parser.Command.variable]
def elabVariable : CommandElab
  | stx@`(variable $binders*) => do
    if ← trial none (Lean.Elab.Command.elabVariable stx) then return
    for binder in binders do
      discard <| trial (some ("binder", binder)) do
        Lean.Elab.Command.elabVariable (← `(variable $binder))
  | _ => throwUnsupportedSyntax

/-- `omit` through the builtin `elabOmit`: the whole command if it succeeds, otherwise one item at
a time, skipping items that fail. -/
@[command_elab Lean.Parser.Command.omit]
def elabOmit : CommandElab
  | stx@`(Lean.Parser.Command.omit| omit $omits*) => do
    if ← trial none (Lean.Elab.Command.elabOmit stx) then return
    for o in omits do
      discard <| trial (some ("`omit` item", o)) do
        Lean.Elab.Command.elabOmit (← `(Lean.Parser.Command.omit| omit $o))
  | _ => throwUnsupportedSyntax

end BuildAid.Leniency.Variable
