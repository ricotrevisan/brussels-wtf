# Issue 53 legal-entity registered-feed blocker

The legal-entity browser leg remains fail-closed because issue #49 has not delivered a source-specific public projection for a verified management or contract fact.

`BrusselsWtf.Follow.PublicUpdates` deliberately returns no legal-entity updates. `BrusselsWtf.Identity.PublicProjection` currently exposes verified person mandates and management facts, but the registered-feed projection cannot prove that a management fact targets the followed CBE enterprise number with the required source-specific public evidence and privacy gate. The existing issue #30 public profile relationship view is not a safe substitute: its rendered relationship does not establish a new persisted qualifying event after the follow timestamp.

No legal-entity fact, relationship, or feed delivery is synthesized. A browser acceptance test must be restored only after #49 adds an authoritative verifier action whose persisted output can be looked up by exact fact id and CBE enterprise number. That action must pass the public privacy projection and run strictly after the UI follow action.
