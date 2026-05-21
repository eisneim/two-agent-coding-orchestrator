---
name: checkpoint-worker
description: Worker-side protocol for projects driven by the tmux-orchestrator. Use when YOU (Claude Code) are the worker running inside a tmux pane being supervised by another Claude (the orchestrator). Triggers include phrases like "you are the worker", "follow the checkpoint protocol", "read .orch/todo.md", "the orchestrator will drive you", "decompose T1", "READY_FOR_SPEC_REVIEW".
---

# checkpoint-worker

You are the **worker**. Another Claude in a separate terminal (the
**orchestrator**) is supervising you. You do the actual coding work.
The orchestrator only watches your tmux pane and reads `.orch/dev_log.md`.

## Hard Rules

1. **Always work in `.orch/`-aware mode.** When asked to do a task, read
   `.orch/todo.md` and `.orch/spec.md` first.
2. **Append to `.orch/dev_log.md` as you work.** This is your only channel
   to the orchestrator besides the screen. Use it.
3. **Use exact completion markers.** When you finish a TODO `T<N>`, write
   exactly `[T<N> DONE]` on its own line in `dev_log.md`. The orchestrator
   detects task completion by grepping for this string. If the form is
   wrong, the orchestrator hangs.
4. **Stop after each TODO.** Do not chain `T1` straight into `T2`. After
   `[T<N> DONE]`, finish your turn and wait. The orchestrator will send
   you the next prompt.
5. **`READY_FOR_SPEC_REVIEW` halts you for human review.** Use it after
   drafting `spec.md` for the FIRST todo only.

## Files you work with

| File                | Who writes      | When                           |
| ------------------- | --------------- | ------------------------------ |
| `.orch/todo.md`     | orchestrator    | created at start; you mark [x] when done |
| `.orch/spec.md`     | you             | first task: detailed plan; subsequent tasks: append a section per task |
| `.orch/dev_log.md`  | you (append)    | progress journal — see format below |
| `.orch/checkpoint.md` | you           | dump on `[PRE_COMPACT]` signal (Phase 4 — not yet active) |

## Phase 0 — first task only: spec review

When you receive: *"Read .orch/todo.md and decompose T1 into a detailed
spec at .orch/spec.md..."*

1. Read `.orch/todo.md`
2. Read `CLAUDE.md` if present
3. Examine relevant code (use Read / Grep liberally — context budget for
   spec writing is fine; the worry is mid-execution)
4. Write `.orch/spec.md` with this structure:

```markdown
# Spec for T1: <T1 label>

## Approach
<1-paragraph plan>

## Subtasks
- [ ] S1.1: <concrete step>
- [ ] S1.2: <concrete step>
- ...

## Files to touch
- path/to/file.x — <what changes>
- ...

## Tests / verification
<how we know each subtask works>

## Open questions
<anything ambiguous from todo.md — keep this short>
```

5. Append to `.orch/dev_log.md`:
   ```
   [SPEC_DRAFTED T1] subtasks: S1.1, S1.2, S1.3, ...
   ```
6. Print `READY_FOR_SPEC_REVIEW` on its own line in your final response
7. **Stop**. Do not start coding. Wait for the next prompt.

## Phase 1 — steady-state work cycle

When you receive *"Begin T<N>: ... Append [T<N> DONE] when complete."*:

1. If `T<N>` is the first task: spec.md already exists from phase 0,
   proceed.
2. If `T<N>` > 1: silently decompose into subtasks (style/scope already
   calibrated by T1 review). You may *append* a `## Spec for T<N>`
   section to `spec.md`, but no human review needed.
3. Append a start marker to `dev_log.md`:
   ```
   [T<N> START] <one-line summary>
   ```
4. Do the work. Use TDD if appropriate (see `superpowers:test-driven-development`).
5. As subtasks complete, append progress lines:
   ```
   [T<N>] S<N>.<i> done
   [T<N>] S<N>.<j> skipped — <reason>
   [T<N>] S<N>.<k> added — <reason>
   ```
6. When the milestone is fully done, mark it in `todo.md`:
   - Replace `- [ ] T<N>: ...` with `- [x] T<N>: ...`
7. Append to `dev_log.md`:
   ```
   [T<N> DONE] subtasks: S<N>.1✓ S<N>.2✓ S<N>.3 skipped(legacy) S<N>.4✓
   ```
8. **Stop and wait.** Do not start the next task on your own.

## dev_log.md format

Append-only. Each line is one event. Keep entries terse — orchestrator
reads only the tail. Format conventions:

```
[T1 START] implementing login backend
[T1] S1.1 done
[T1] S1.2 wrote AuthController + JWT util
[T1] tests passing — 12/12
[T1 DONE] subtasks: S1.1✓ S1.2✓ S1.3 skipped(no migration needed) S1.4✓

[T2 START] login frontend component
[T2] S2.1 LoginForm renders
[T2] S2.2 dispatch on submit
[T2 DONE] subtasks: S2.1✓ S2.2✓
```

Avoid:
- Multi-line entries (orchestrator's tail may cut you mid-paragraph)
- Verbose explanations (this isn't a chat log, it's a status feed)
- Internal tool output (don't paste full test results — write `tests passing — 12/12`)

## Subtask delta reporting

When you skip or add subtasks, the orchestrator should know. The format
in step 7 above (`subtasks: ✓ skipped(reason) added(reason)`) is the
contract. If everything went exactly to plan, `subtasks: S1.1✓ S1.2✓` is
fine — symmetric simplicity.

## Errors and unknowns

If you hit something that requires human judgment (architectural
decision, conflicting requirements, missing information), stop and
write to `dev_log.md`:

```
[T<N> BLOCKED] reason: <one line>
```

Then in your final message, ask the user the specific question. The
orchestrator will surface this to the user.

## Performance / context discipline

You will be running for a long time. Help yourself stay coherent:

- Don't re-read `spec.md` cover-to-cover every turn. Keep a short
  working summary in your head and trust the file.
- Don't `cat` huge files when `head` / `tail` / specific line ranges
  will do.
- When unsure, lean on TDD: tests force concrete decisions and let you
  recover state from code rather than memory.

## Phase 4 — context compaction protocol (active)

The orchestrator monitors your context pressure. Before you risk overflow
it will run `orch-compact`, which drives you through three phases:

### 4.1 PRE_COMPACT signal

You receive a prompt starting with `[PRE_COMPACT]`. Procedure:

1. **Pause** any in-progress work. Do not start new tools.
2. **Update `.orch/checkpoint.md`** so a *fresh you* (post-compact, with
   no memory) can resume work from `checkpoint.md` + `spec.md` +
   `dev_log.md` alone. See format below.
3. **Append `READY_FOR_COMPACT`** to `.orch/dev_log.md` on its own line.
4. **Stop** your turn. Wait. The orchestrator will issue `/compact` next.

### 4.2 checkpoint.md format

Overwrite the whole file each time (not append). Aim for ≤200 lines.

```markdown
# Checkpoint — <ISO timestamp>

## Current task
T<N>: <label> — status: <in-progress | blocked | done>

## What's been done in this T<N> so far
- S<N>.1 ✓ <short outcome>
- S<N>.2 ✓ <short outcome>
- S<N>.3 in-progress — <state>

## What remains for T<N>
- S<N>.4: <next concrete step>
- S<N>.5: <step after that>

## Working context (mental model)
<3-8 bullets of facts the post-compact you will need: file paths,
function names being modified, constraints, design decisions, test
status. Be specific. No prose.>

## Open questions / known issues
<short list, or "none">

## Resume hint
First action post-compact: <one concrete step>
```

The post-compact you will read this verbatim. Be the post-compact you's
best friend.

### 4.3 /compact

The orchestrator runs `/compact` directly. You don't need to do anything
— Claude Code handles its own compaction. The conversation history will
be summarized down to a compact form. Your skill, files, and tool access
remain.

### 4.4 RESUME prompt (after compact)

You will receive: *"Read .orch/checkpoint.md and the most recent few
lines of .orch/dev_log.md, then append 'RESUMED_OK <one-line summary of
where we are>' to .orch/dev_log.md and stop."*

Do exactly that. Don't start coding yet. The orchestrator verifies the
`RESUMED_OK` marker before sending the next real task.

If the checkpoint is unclear or stale, append `RESUMED_BLOCKED <reason>`
instead and ask the user via your final message.
