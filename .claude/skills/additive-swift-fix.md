---
name: additive-swift-fix
description: Additive-only rule for Tween Swift fixes — new code with nil defaults, never edit working methods
---

# Additive-only Swift fixes (Tween)

New behavior goes in new methods, new structs, or optional-closure properties
with `nil` defaults. Never edit an existing working method. Never modify
`effectiveReceived` or `decodeAndCache`. If a fix seems to require editing a
working method, STOP and flag it — do not proceed.
