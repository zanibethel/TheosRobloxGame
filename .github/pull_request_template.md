## Summary

<!-- What does this PR do and why? One to three sentences. -->

## Scope

<!-- What files and systems are in scope? What is explicitly out of scope? -->

## Architecture review

<!-- Client/server boundaries, module responsibilities, and any design decisions worth noting. -->

## Security review

<!-- Remote validation, trust boundaries, and any client-provided values that were audited. -->

## Validation

<!-- Which checks were run and whether they passed. -->

- Static checks (StyLua, Selene, JSON/TOML, Rojo build):
- Automated tests (InteractionTests or other harnesses):
- GitHub Actions status:

> Do not mark GitHub Actions as passing until the workflow has executed and the run link is recorded here.

## Roblox Studio testing

<!-- List each Studio test performed and its outcome. Use "pending" for tests not yet run. -->

- [ ] Solo play — bootstrap lifecycle
- [ ] Two-player local server
- [ ] Relevant interaction or system test (describe below)

**Studio test notes:**

## Known limitations

<!-- Anything that is not covered by this PR but is acceptable for merge. -->

## Follow-up work

<!-- Unrelated findings or deferred improvements discovered during this PR. -->

## Merge recommendation

<!-- Ready / Not ready — and why. -->

---

## Checklist

- [ ] Focused scope
- [ ] No unrelated refactors
- [ ] Server-authoritative gameplay preserved
- [ ] Remote input validated
- [ ] Cleanup and reset paths reviewed
- [ ] Multiplayer behavior considered
- [ ] StyLua passes
- [ ] Selene passes
- [ ] Rojo build passes
- [ ] Automated tests pass or are clearly marked unavailable
- [ ] Roblox Studio tests listed
- [ ] Documentation remains accurate
- [ ] No unresolved review threads
- [ ] GitHub Actions are green
