# Vision

Wink makes computer use on macOS more capable, reliable, and inspectable.

We land focused bug fixes and practical improvements for screen understanding, native UI automation, and agent-driven computer use. We favor deep integration with macOS frameworks and behavior over broad platform abstractions.

## Platform scope

Wink is deliberately macOS-only. No cross-platform port is planned, and portability layers are out of scope when they dilute the quality of the macOS implementation. Independent platform-specific projects can evolve separately.

## Reliability contract

Successful automation must prove the artifact or state it promises; empty or unreadable results are failures, not successful captures. Once a non-idempotent action may have been delivered, cleanup failures must stay observable without turning delivery into a retryable error. Preserve user state such as the clipboard whenever possible, and clearly warn when restoration cannot be confirmed.
