import Lean.Linter.Init

/-!
Options for the warnings of the lenient elaborators (`BuildAid.Leniency.Open`,
`BuildAid.Leniency.Example`, `BuildAid.Leniency.Variable`).

Each warning has its own option, and `linter.leniency` controls them all. An option's value is
resolved in this order:

1. the individual option (`linter.leniency.open`, `linter.leniency.example`,
   `linter.leniency.variable`), if set;
2. otherwise `linter.leniency`, if set;
3. otherwise on.

`linter.all` does not affect them: these warnings report that the build depends on leniency, not
style. For the same reason Lean's `getLinterValue` and linter sets (`register_linter_set`) are not
used: under them `linter.all` takes precedence, and a set can only turn its members on.

Disabling a warning drops every message it governs, including the errors the lenient elaborator
would otherwise have shown as warnings.
-/

register_option linter.leniency : Bool := {
  defValue := true
  descr := "warn when a lenient elaborator (`open`, `example`, `variable`/`omit`) skips something \
    that failed, since a necessary import may have been removed; sets the default for all \
    `linter.leniency.*` options"
}

register_option linter.leniency.open : Bool := {
  defValue := true
  descr := "warn when a lenient `open` skips a namespace or name that does not resolve"
}

register_option linter.leniency.example : Bool := {
  defValue := true
  descr := "warn (with its errors as warnings) when a lenient `example` fails to elaborate"
}

register_option linter.leniency.variable : Bool := {
  defValue := true
  descr := "warn (with its errors as warnings) when a lenient `variable` or `omit` skips a binder \
    or item that fails to elaborate"
}

namespace BuildAid.Leniency

open Lean

/-- Whether the leniency warning governed by `opt` is enabled (see the module docstring). -/
def enabled (opt : Lean.Option Bool) (o : Options) : Bool :=
  o.get? opt.name |>.getD <| o.get? linter.leniency.name |>.getD true

/-- Logs the leniency warning `msg` at `ref` if `opt` is enabled. -/
def warn {m : Type → Type} [Monad m] [MonadLog m] [AddMessageContext m] [MonadOptions m]
    (opt : Lean.Option Bool) (ref : Syntax) (msg : MessageData) : m Unit := do
  if enabled opt (← getOptions) then
    Lean.Linter.logLint opt ref m!"{msg}; a necessary import may have been removed"

/-- `log` without its errors (what a lenient elaborator keeps when its warning is disabled). -/
def dropErrors (log : MessageLog) : MessageLog :=
  { unreported := log.unreported.filter (·.severity != .error) }

/-- The messages a lenient elaborator keeps from a failed attempt: its errors as warnings if the
warning governed by `opt` is enabled, otherwise everything but its errors. -/
def keep (opt : Lean.Option Bool) (o : Options) (log : MessageLog) : MessageLog :=
  if enabled opt o then log.errorsToWarnings else dropErrors log

end BuildAid.Leniency
