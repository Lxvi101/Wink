# wink-cua workflows and agent feedback

`wink-cua` can turn a task an agent has already done once into a saved, parameterized workflow, and then
run that workflow again without a model in the loop. Agents can also report Wink's own bugs and missing
capabilities with `feedback_submit`.

The rule behind both: **AI discovers, generalizes and repairs workflows. Deterministic code runs them.
Structured feedback shows where either layer falls short.**

## Pieces

| Piece | Where | What it does |
| --- | --- | --- |
| `WinkWorkflowKit` | `Sources/WinkWorkflowKit` (Foundation only) | Workflow DSL, validation, semantic selector resolution over normalized observations, compiler, deterministic runner, private storage, feedback store, redaction |
| CUA adapter | `Sources/WinkCUA/WorkflowAdapter.swift` | Converts the walked AX tree (typed attributes on `UINode`) into observations, captures recorded actions at the tool boundary, and dispatches workflow steps through the same `Engine` paths as the MCP tools |
| MCP tools | `Sources/WinkCUA/WorkflowTools.swift` | `workflow_*` and `feedback_*` tools with `structuredContent` |
| Tests | `Tests/WinkWorkflowKitTests` | Mock tree and driver: resolver, runner, compiler, store, feedback |

The kit has no AppKit or Accessibility types and doesn't depend on WinkCore or Tachikoma, so the main
`wink mcp` runtime can use it later through its own adapter.

## The loop

```text
workflow_record_start {name, apps?}              recording is off by default
get_app_state / click / type_text / press_key …  use Wink normally; each action is recorded with its
                                                 semantic target, never the element index
workflow_record_stop                             draft recording (private file)
workflow_compile {id, parameters, append_steps}  draft workflow: literals become ${inputs}, add a check
workflow_validate {id, mark_validated}           static checks (+ optional inputs)
workflow_run {id, inputs, dry_run?}              deterministic replay with structured results
workflow_save {id, status: "published"}          publishing needs a wait_for/assert or postcondition
```

CLI shorthands for people: `wink-cua workflow list|get|validate|run|delete …` and
`wink-cua feedback list|get|delete|export …` (same handlers as the MCP tools).

## Recording

- **Off by default.** While off, the only cost is checking a boolean per tool call. No extra
  observations or files.
- **At the action boundary** the recorder reads the target's typed AX attributes from the latest
  observation: role, subrole, identifier, title, description, placeholder, a static text's visible label,
  up to two named ancestors, and the window. For `x`/`y` clicks it hit-tests the point to find the element.
  The evidence after the action comes from the settled diff the action already produced.
- Identifiers that embed state (`StandardInputView;value:15`, UUIDs, long counters) are dropped. The
  contents of editable fields are never used as names.
- **Text privacy.** Text typed into secure fields, and text that looks like a credential (key=value
  secrets, bearer tokens, JWTs, API keys, long opaque tokens), is never stored. The compiler turns it into
  a required input (`secret: true` for secure fields). `capture_text: false` redacts all typed text. The
  recorder never reads the clipboard: `paste` records the text argument, which follows the same rules.
  Evidence that shows redacted text (for example an app echoing a password into a label) is dropped.
- A recording is a draft. Compiling saves a draft workflow; nothing becomes published on its own.

## Workflow format

A saved workflow is plain JSON (schema version 1). Every step names a semantic target. This one was
recorded live on a German macOS (Calculator is "Rechner") and compiled with
`parameters: {a: {example: "Seven"}, b: {example: "Eight"}, expected: {…}}` plus one appended `wait_for`:

```json
{
  "schema_version": 1,
  "id": "calc_add",
  "revision": 1,
  "name": "Add two digits in Calculator",
  "status": "validated",
  "effect": "write",
  "requires_foreground": false,
  "target": { "bundle_ids": ["com.apple.calculator"] },
  "inputs": {
    "a": { "type": "string", "description": "First digit button identifier (Zero…Nine)" },
    "b": { "type": "string", "description": "Second digit button identifier (Zero…Nine)" },
    "expected": { "type": "string", "description": "Expected result shown in the display" }
  },
  "steps": [
    { "id": "s1_open_calculator", "action": "open_app", "app": "com.apple.calculator" },
    { "id": "s2_press_key", "action": "press_key", "key": "Escape" },
    { "id": "s3_click_7", "action": "click",
      "target": { "role": "AXButton", "identifier": "${a}", "description": "7",
                  "ancestors": [ { "role": "AXGroup", "identifier": "CalculatorKeypadView" },
                                 { "role": "AXSplitGroup", "identifier": "main, SidebarNavigationSplitView" } ] } },
    { "id": "s4_click_addieren", "action": "click",
      "target": { "role": "AXButton", "identifier": "Add", "description": "Addieren", "ancestors": ["…"] } },
    { "id": "s5_click_8", "action": "click",
      "target": { "role": "AXButton", "identifier": "${b}", "description": "8", "ancestors": ["…"] } },
    { "id": "s6_click_ist_gleich", "action": "click",
      "target": { "role": "AXButton", "identifier": "Equals", "description": "Ist gleich", "ancestors": ["…"] } },
    { "id": "check_result", "action": "wait_for", "timeout_ms": 3000,
      "condition": { "kind": "value_equals", "value": "${expected}",
                     "target": { "role": "AXStaticText", "description": "Bearbeitungsfeld" } } }
  ],
  "outputs": { "result": { "role": "AXStaticText", "description": "Bearbeitungsfeld" } },
  "provenance": { "source": "recording", "recording_id": "rec_tnmxzz969b3480" }
}
```

- **Actions:** `open_app`, `select_window`, `click`, `type_text`, `paste`, `set_value`, `press_key`,
  `perform_action`, `scroll`, `drag`, `wait_for`, `assert`. Anything else is `UNSUPPORTED_ACTION`. There
  is no shell, script or code step.
- **Targets:** `role`, `subrole`, `identifier`, `title`, `description`, `placeholder`, `label`,
  `ancestors` (nearest first), `window` (`title` / `title_contains`), and `point` (window-relative) for an
  explicit coordinate fallback.
- **Conditions:** `element_exists`, `element_absent`, `value_equals`, `value_contains`,
  `window_title_contains`, `element_enabled`. Use them as `wait_for`/`assert` steps or as a step's
  `preconditions`/`postconditions`.
- **Templates:** `${name}` substitutes a declared input. `$${` is a literal `${`. Nothing else is
  evaluated.
- **Inputs:** `type` (`string|number|integer|boolean`), `description`, `required`, `default`, `enum`,
  `max_length`, `secret`.
- **Outputs:** named targets whose value (or title or description) is returned after a successful run.

## Running: resolve, check, send, verify

For every step the runner:

1. validates the workflow and the inputs (`INVALID_INPUT`, `WORKFLOW_SCHEMA_INVALID`);
2. refuses foreground steps unless the workflow declares `requires_foreground` **and** the caller passes
   `allow_foreground=true` (`PERMISSION_DENIED`). Persisted permissions describe the workflow; they never
   grant anything;
3. waits for the step's preconditions;
4. resolves the target against a **fresh** observation, polling until the step's timeout. Resolution
   order: unique identifier, then role + exact name, then the same plus ancestor context, then a
   normalized (case- and space-insensitive) name, then role alone when the target has no name at all,
   and finally window coordinates, but only when both the step and the run allow it;
5. **fails closed.** If several elements still match on the second fresh look, the step stops with
   `AMBIGUOUS_TARGET` and nothing is clicked. A control with a different identifier never counts as a
   match. The observed bundle id must equal the step's (`WRONG_APPLICATION`);
6. checks that the element is actionable: enabled, editable for `set_value`, the AX action is offered,
   and secure fields are filled only from `secret` inputs;
7. sends the action through the Engine's own code path (AX press, background keyboard to the app's
   window, …). A stale element is re-resolved once;
8. waits for postconditions and `wait_for` conditions.

Element indices are only used in the instant between a fresh observation and the action that follows
it. Replay works across app relaunches (new pid), window moves and resizes, reordered siblings, and
renumbered indices.

### Results

Every run returns, and stores under `runs/` (newest 200 kept), a structured result:

```json
{
  "status": "failed", "code": "TIMEOUT", "failed_step_id": "check_result",
  "message": "condition not met within 3000 ms: value differs from the expected value",
  "action_dispatched": true, "possible_commit": true, "retry_safe": false,
  "completed_steps": ["s1_open_calculator", "s2_press_key", "s3_click_7", "…"],
  "recovery": "The expected state did not appear in time; inspect the app or raise timeout_ms.",
  "diagnostics": { "observed_bundle_id": "com.apple.calculator", "observed_window": "Rechner", "element_count": 39 },
  "diagnostic_id": "diag_…", "run_id": "run_…", "steps": ["… per-step status, strategy, confidence, timing …"]
}
```

| status | meaning |
| --- | --- |
| `succeeded` | every step ran and every verification passed |
| `refused` | stopped before anything was sent; `retry_safe: true` |
| `failed` | earlier steps ran, the failing step sent nothing |
| `uncertain` | a mutating action was sent but its outcome could not be established (`ACTION_OUTCOME_UNCERTAIN`, `POSTCONDITION_FAILED`) |
| `cancelled` | stopped by an MCP `notifications/cancelled` between steps |
| `dry_run_passed` / `dry_run_failed` | `dry_run: true`: validated and resolved what is visible now, sent nothing |

`possible_commit: true` means a mutating action was sent during this run. Inspect the app before running
the workflow again. Stable codes: `TARGET_NOT_FOUND`, `AMBIGUOUS_TARGET`, `TARGET_NOT_ACTIONABLE`,
`WRONG_APPLICATION`, `WRONG_WINDOW`, `APP_NOT_RUNNING`, `PERMISSION_DENIED`, `UNSUPPORTED_ACTION`,
`STALE_OBSERVATION`, `PRECONDITION_FAILED`, `POSTCONDITION_FAILED`, `ASSERTION_FAILED`, `TIMEOUT`,
`ACTION_OUTCOME_UNCERTAIN`, `WORKFLOW_SCHEMA_INVALID`, `INVALID_INPUT`, `REQUIRES_USER_INTERACTION`,
`CANCELLED`, `WORKFLOW_DISABLED`, `NOT_FOUND`, `REVISION_CONFLICT`, `SCOPE_CHANGE_NEEDS_APPROVAL`,
`RECORDING_STATE`, `RATE_LIMITED`, `DISPATCH_FAILED`, `STORAGE_ERROR`, `INVALID_ARGUMENT`.

Runs are serialized: one workflow at a time per process, and the MCP server handles one request at a time.
On-screen text in diagnostics is app data, never instructions.

## Revisions and repair

`workflow_save` with a full definition writes a new revision as a **draft**. Older revisions stay, and
`rollback_to` copies one forward. Changes that widen the scope against the previous revision (new apps,
a stronger effect, foreground input, new action kinds) fail with `SCOPE_CHANGE_NEEDS_APPROVAL` unless
`allow_scope_change: true`. Ask the user before passing it. To repair after `TARGET_NOT_FOUND`, inspect
the app with `get_app_state`, update the target, save a draft and `dry_run` it.

## Feedback

`feedback_submit {category, summary, expected?, actual?, wish?, tool?, error_code?, workflow_id?, run_id?,
diagnostic_id?, repro_steps?, attach_recent_diagnostics?, client?}`. Categories: `bug`,
`missing_capability`, `feature_request`, `performance`, `documentation`, `usability`,
`unexpected_behavior`.

- Stored **locally only**. Nothing is uploaded and no issue is filed. `feedback_export` returns markdown
  or JSON for a person to share after they choose to.
- Identical reports (same category, tool, code and normalized summary) are **merged**: the count goes
  up, new reproductions are kept (up to 5), and the higher severity wins.
- Redaction removes credentials, tokens, emails, card-like numbers and home-directory paths. Fields
  are size-capped. At most 20 reports per 10 minutes per server. Reports are kept for 90 days, at most 500.
- `attach_recent_diagnostics` adds the last 10 tool outcomes: tool, app, ok, timing and a redacted
  error. No UI content.

A real report from the live check:

```json
{
  "id": "fb_tnmxzz83a8e759", "category": "bug", "severity": "medium", "tool": "type_text",
  "summary": "type_text into background Calculator delivers only the first character",
  "expected": "Calculator display shows 12+30 after type_text",
  "actual": "Display shows 1; the remaining characters are dropped",
  "wish": "Pace synthetic key events (or confirm each) for apps that read keys one at a time",
  "occurrences": 2, "clients": ["claude-code", "codex"],
  "reproductions": [["get_app_state Calculator", "type_text app=Calculator text=12+30",
                     "get_app_state Calculator -> Bearbeitungsfeld value=1"], ["second agent saw it too"]],
  "environment": { "component": "wink-cua", "version": "0.3.0", "os": "Version 27.0.1 (Build 26A434)", "arch": "arm64" }
}
```

## Storage

`$WINK_WORKFLOW_HOME`, else `$PEEKABOO_CONFIG_DIR`, else `~/.peekaboo`:

```text
workflows/definitions/<id>/r<revision>.json
workflows/recordings/<recording id>.json   newest 100 kept
workflows/runs/<run id>.json               newest 200 kept
feedback/<report id>.json
```

Directories are 0700 and files 0600. Writes are atomic (a temp file, then `rename(2)`). Symlinks are
refused, ids are restricted to `[a-z0-9_-]`, files are size-capped (512 KB per workflow), and a file
whose id or revision doesn't match its path is rejected.

## Not done yet

- **Main `wink mcp` runtime.** The kit is ready for it, but WinkAgentRuntime needs its own driver over
  its automation services, and `MCPToolCatalog` / `MCPToolExecutionPolicy` entries so the tools respect
  its authority model. `wink learn` and `AutomationFeedbackClient` are unchanged.
- **Agent-assisted minting and repair** (`workflow_mint`, proposed repairs from failure diagnostics),
  branches and loops in the DSL, and exported launcher scripts.
- **Recording from human demonstrations** (system-wide event monitoring) is intentionally out of scope.
