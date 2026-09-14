---
name: sayit
description: Live, low-latency spoken narration for hands-free agent sessions through the sayit TTS command. Trigger immediately for commands such as “let’s use sayit,” “use sayit,” “talk me through this,” “keep me updated out loud,” “I’m AFK, speak updates,” or “give me live voice updates,” and whenever the user otherwise asks the agent to speak, narrate, or provide voice updates. Once activated, voice mode is sticky and mandatory throughout the active session—including follow-up turns, exploration, experiments, errors, recovery, and final handoffs—until the user explicitly turns it off with language such as “stop using sayit,” “turn off voice,” “no more spoken updates,” or “text only.” Prefer this skill over ad-hoc say or audio commands whenever speech output is involved.
---

# sayit — live-agent spoken narration

Use `sayit` as a live companion to the work, not as a text report reader. The
listener should hear the agent begin, explore, discover, adjust, and finish in
near real time while the underlying task continues without waiting for speech.

`sayit` owns a shared playback queue. Each invocation appends one utterance,
and queued utterances play in order without talking over one another.

## Activation is a sticky session mode

Treat a direct voice command as a mode switch, not a one-turn request. Examples
that activate the mode include:

- “Let’s use sayit.”
- “Use sayit while you work.”
- “Talk me through this.”
- “Keep me updated out loud.”
- “I’m going AFK; speak your progress.”
- “Switch on voice mode.”
- “Give me live voice updates while you work.”

After any such activation, spoken narration is mandatory throughout the active
session. Keep using it across user follow-ups, new phases of the work, errors,
retries, topic refinements, and completed subtasks. A short user message, a new
question, a topic change, a written final response, or a period of silence does
not deactivate voice mode. Do not make the user repeatedly say “use sayit.”

Only an explicit opt-out turns it off. Examples include:

- “Stop using sayit.”
- “Turn off voice.”
- “No more spoken updates.”
- “Text only from now on.”
- “You can stop talking now.”

When the user turns voice mode off, acknowledge that once in text and stop
launching new utterances. Do not infer deactivation from brevity, interruption,
task completion, or a change of subject.

Voice mode belongs to the current conversation. A separate thread, fork, or
side conversation is a new session and does not inherit voice mode unless the
user activates it there.

## Absolute rule: speech must never block the work

On this machine `sayit` only hands the text to the local sayitd service and
exits in about fifty milliseconds; the service synthesizes and plays it. So a
plain foreground call already returns instantly. Launch every utterance as:

```bash
sayit "I’m checking the current branch and its recent commits." >/dev/null 2>&1
```

Never pass `--wait` or `--replace` for narration. `--wait` blocks until the
audio finishes; `--replace` cuts off speech that is still playing. Never sleep,
poll, or check completion after speaking.

For the first utterance, check `command -v sayit` once. If the user reports
that nothing played, troubleshoot then: run `sayit status`; if the service is
down, `sayit service restart` and `sayit service logs` show what happened.
Also check the output volume (`wpctl get-volume @DEFAULT_AUDIO_SINK@`). Then
retry one short audible confirmation before resuming narration.

Use a separate, tiny shell call for speech when that gives control back sooner.
If speech precedes a shell investigation in the same call, keep it as the first
line and start the real command on the next line.

## The live narration loop

Once this skill triggers, keep voice active until the user explicitly disables
it. Repeat this small loop while working:

1. **Orient.** Speak one short sentence at the start: what you understood and
   what you are checking first.
2. **Explore.** Continue working immediately. Before a meaningful investigation
   or experiment, briefly say what question it should answer.
3. **Report the event.** As soon as a useful result lands, speak the finding and
   why it matters. Do not silently collect several findings for a later batch.
4. **Adapt.** If the result changes the plan, say what changed and where you are
   going next. If something fails, acknowledge it promptly and narrate the
   recovery.
5. **Finish.** Enqueue a complete spoken handoff, then return the written final
   response immediately without waiting for the queue.

This is event-driven narration. Speak when the listener’s mental model should
change: a step begins, evidence lands, a hypothesis is confirmed or rejected,
a decision is made, an error occurs, the plan pivots, or the work completes.
Do not narrate trivial commands, every file opened, or repetitive checks.

## Cadence and latency

The audio should feel attached to the work in progress, not delayed until the
end.

- Speak the opening before or alongside the first substantive tool action.
- During active exploration, aim for a useful update every 15–30 seconds. Do
  not let more than about 45 seconds of active work pass in silence. If a tool
  may run longer, say what is running and what result you are waiting for
  before starting it.
- Speak a discovery immediately after the result that supports it. Do not read
  five files, run three commands, and only then narrate the combined result.
- Keep ordinary updates to one breath: usually 8–30 words or one to two short
  sentences.
- Do not flood the queue. If narration has fallen behind the work, drop stale
  low-value updates and enqueue one current-state summary. Real-time relevance
  matters more than exhaustive play-by-play.
- If the user interrupts or redirects the task, acknowledge the pivot aloud
  promptly and stop narrating the superseded work.

## What to say

Useful live updates include:

- “I found the branch’s core idea: consensus happens before any member exposes
  a signature share. I’m tracing the wallet side next.”
- “That test failed because the fixture is stale, not because the new path is
  broken. I’m regenerating the fixture and rerunning the focused case.”
- “The first approach adds a second state owner, so I’m discarding it. I’m
  checking whether the existing journal can own the transition instead.”
- “The focused checks pass. I’m doing the standalone compatibility check now.”

Speak concise conclusions and decision-relevant rationale. Do not expose hidden
chain-of-thought, sensitive data, secrets, personal information, raw logs, or
large code fragments. “This failed because the server rejected the stale
token” is useful; a private internal monologue is not.

## Final spoken handoff

The final narration is different from a progress update: it must be a complete,
self-contained summary for a listener who may have missed earlier audio.

Lead with “I’m done” or the actual terminal state, then include all important
information:

- the outcome;
- the central findings or design;
- material changes made;
- verification performed and its result;
- unresolved risks, blockers, or tests not run; and
- the most useful next step, when one exists.

Aim for roughly 120–250 spoken words. If the handoff needs more, split it into
two or three clearly ordered topical utterances. Enqueue them back-to-back and
return the written final response immediately. Never wait for the summary to
finish playing. A final handoff closes the current task, not voice mode; narrate
the next user follow-up unless they explicitly opt out.

## Write for the ear

Speech is not Markdown read aloud.

- Lead with the headline, then the detail. The listener cannot skim.
- Use ordinary sentences, not bullets, tables, headings, file paths, or code.
- Expand or space acronyms that TTS may mangle: “H T L C,” “V T X O,” “D K G,”
  or “B I P 47.”
- Translate identifiers into words. Say “the verify keys command,” not a long
  snake-case function name.
- Speak numbers and units naturally: “three of five members,” “one thousand
  sats,” or “commit c five two d f.”
- Use signposts for structure: “There are three findings. First…”

## Keep the written channel

Voice is the live experience; text is the durable record. Continue sending
normal concise commentary and a written final response. Put exact commands,
code, links, file paths, tables, and anything the user may need to copy in text.
Mirror critical conclusions in both channels, but adapt each for its medium
instead of reading the written message verbatim.

## Conversational voice mode

Treat spoken sessions as dialogue. Answer the user aloud promptly. Ask at most
one blocking question at a time and speak it as well as writing it. Interpret
dictated typos generously. When a correction contradicts the current course,
confirm the new direction aloud before pivoting.

## Shell safety

Wrap the utterance in double quotes. Inside it, avoid double quotes, backticks,
shell variables, command substitutions, and exclamation marks. Rewrite the
sentence in plain language rather than risking shell interpretation. Do not
combine a speech launch with unrelated globs or cleanup commands that could
abort the line before the utterance is queued.

## Availability and fallback

Check `command -v sayit` once when needed. If it is missing, or the service
cannot start, say so in text and continue the task without pretending audio was
delivered. Do not fall back to other audio commands.

## Voices and language

The service picks the Spanish voice automatically when an utterance is mostly
Spanish, so speak to a Spanish-speaking user in Spanish without extra flags.
Leave the voice and speed at the user’s defaults unless they ask otherwise.

## Anti-patterns

- Silent research followed by one giant spoken report.
- Waiting for playback, polling status, or passing `--wait`.
- Treating the TTS process as part of task success.
- Treating a completed task or written final response as automatic voice-mode
  deactivation.
- Narrating every command until the queue lags behind reality.
- Reading Markdown, raw diffs, logs, or paths aloud.
- Saying “still working” without naming the current question or new evidence.
- Ending with a vague “done” that omits verification, limitations, or the
  actual result.

The success test is simple: the user can look away, understand where the work
is going from short timely updates, and hear a complete trustworthy summary at
the end—while the agent never pauses its work for speech.
