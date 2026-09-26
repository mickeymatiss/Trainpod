# Bounded reverse patches

These patches were prepared against combined production head a7dc7a9 and apply to the final campaign state; subsequent F13 work adds only separate tests/reports. Each removes one production pass and its dedicated test without rewinding shared reports or deleting later unrelated registrations.

Use a clean checkout, first run `git apply --check docs/engineering-passes/rollback/F01.patch` (substitute the finding), then apply that patch and inspect the diff. Run the full host suite and relevant target/manual verification before committing the rollback. Do not also revert the same original commit. Future source edits can require review and patch adjustment.

F01 preserves later F02 active-peer and F03 disconnect guards. F09 removes its cross-session dependency in the later F10 fixture but preserves F10 render-certainty behavior. Existing defects return when their fix is removed. Cumulative reports intentionally stay as historical evidence and should receive a new rollback note.

All ten individual reversed combinations passed remaining standard host harnesses. Native builds and hardware were not repeated for each reverse combination. verification.json records exact counts. These are alternatives to conflicted raw git reverts, not claims of automatic conflict-free rollback on arbitrary future branches.
