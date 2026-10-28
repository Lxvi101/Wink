import Foundation

/// Stable, machine-readable failure codes shared by the recorder, store, runner and feedback tools.
/// Agents branch on these; the strings are part of the tool contract and must not change.
public enum WorkflowErrorCode: String, Codable, Sendable, CaseIterable {
    case targetNotFound = "TARGET_NOT_FOUND"
    case ambiguousTarget = "AMBIGUOUS_TARGET"
    case targetNotActionable = "TARGET_NOT_ACTIONABLE"
    case wrongApplication = "WRONG_APPLICATION"
    case wrongWindow = "WRONG_WINDOW"
    case appNotRunning = "APP_NOT_RUNNING"
    case permissionDenied = "PERMISSION_DENIED"
    case unsupportedAction = "UNSUPPORTED_ACTION"
    case staleObservation = "STALE_OBSERVATION"
    case preconditionFailed = "PRECONDITION_FAILED"
    case postconditionFailed = "POSTCONDITION_FAILED"
    case assertionFailed = "ASSERTION_FAILED"
    case timeout = "TIMEOUT"
    case outcomeUncertain = "ACTION_OUTCOME_UNCERTAIN"
    case schemaInvalid = "WORKFLOW_SCHEMA_INVALID"
    case invalidInput = "INVALID_INPUT"
    case requiresUserInteraction = "REQUIRES_USER_INTERACTION"
    case cancelled = "CANCELLED"
    case workflowDisabled = "WORKFLOW_DISABLED"
    case notFound = "NOT_FOUND"
    case revisionConflict = "REVISION_CONFLICT"
    case scopeChangeNeedsApproval = "SCOPE_CHANGE_NEEDS_APPROVAL"
    case recordingState = "RECORDING_STATE"
    case rateLimited = "RATE_LIMITED"
    case dispatchFailed = "DISPATCH_FAILED"
    case storage = "STORAGE_ERROR"
    case invalidArgument = "INVALID_ARGUMENT"

    /// What an agent should do next. Short, actionable, and never "just retry" after a possible write.
    public var recovery: String {
        switch self {
        case .targetNotFound:
            "Call get_app_state on the app, find the control, and save a repaired revision with an updated target."
        case .ambiguousTarget:
            "Several elements match. Add identifier, title/description or ancestors to the target so exactly one matches."
        case .targetNotActionable: "The element is disabled or not editable right now; check the app's state first."
        case .wrongApplication: "The frontmost process for this step is not the workflow's app; check target.bundle_ids."
        case .wrongWindow: "Open or select the expected window (or relax the step's window matcher) and run again."
        case .appNotRunning: "Launch the app (a non-dry run with an open_app step does this) and retry."
        case .permissionDenied:
            "Grant the missing permission or pass the explicit run option (allow_foreground / allow_coordinate_fallback)."
        case .unsupportedAction: "Use one of the supported step actions; see workflow_validate errors."
        case .staleObservation: "The UI changed under the step. Retry is safe because nothing was dispatched."
        case .preconditionFailed: "Bring the app into the state the step expects, or repair the precondition."
        case .postconditionFailed, .outcomeUncertain:
            "The action was sent but its result is unverified. Inspect the app before doing anything; do not blindly rerun."
        case .assertionFailed: "The app is not in the asserted state; inspect it with get_app_state."
        case .timeout: "The expected state did not appear in time; inspect the app or raise timeout_ms."
        case .schemaInvalid: "Fix the workflow definition (see errors) and save a new revision."
        case .invalidInput: "Pass inputs that match the workflow's input definitions."
        case .requiresUserInteraction: "A person must act first (unlock the screen, answer a dialog, grant access)."
        case .cancelled: "The run was cancelled; check possible_commit before running again."
        case .workflowDisabled: "Enable the workflow (workflow_save status) before running it."
        case .notFound: "Use workflow_list / feedback_list to find valid ids."
        case .revisionConflict: "Reload with workflow_get and reapply your change on the latest revision."
        case .scopeChangeNeedsApproval:
            "The change widens the workflow's apps, effect or authority. Ask the user, then pass allow_scope_change=true."
        case .recordingState: "Check whether a recording is active (workflow_record_start / workflow_record_stop)."
        case .rateLimited: "Too many reports in a short time. Report a limitation once, with a good reproduction."
        case .dispatchFailed: "The action could not be sent; nothing changed. Inspect the app and retry if appropriate."
        case .storage: "Wink could not read or write its private workflow store; check disk space and permissions."
        case .invalidArgument: "Fix the tool arguments and call again."
        }
    }
}

public struct WorkflowError: Error, CustomStringConvertible, Sendable {
    public var code: WorkflowErrorCode
    public var message: String
    /// True when some input may already have reached the app before the failure.
    public var dispatched: Bool

    public init(_ code: WorkflowErrorCode, _ message: String, dispatched: Bool = false) {
        self.code = code
        self.message = message
        self.dispatched = dispatched
    }

    public var description: String { "\(self.code.rawValue): \(self.message)" }
}
