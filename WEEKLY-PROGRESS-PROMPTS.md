# Weekly Progress Prompts

The weekly progress pipeline replays the successful interaction from Codex session
**019f630d-5663-7722-bc65-5fd298a497ec**. The five user instructions below are copied
byte for byte from that session. Tests pin their SHA256 hashes so they cannot be silently
paraphrased later.

Prompt revision: **reference-session-019f630d-v1**

## Original user instruction 1

Purpose: research reconstruction

SHA256: **6c78705e7d780d39fddf39fd0f2ffead9185d171cf34f3cc1e3de6002be56d3d**

~~~text
So the idea is that this is logs of all the tmux sessions that I've been using for the last few days. There are different
  categories for what is the message from an AI agent. Most of this is tmux sessions with an AI agent.

  There are different categories. Utterance means if I typed something. Oftentimes there is a bug where even partial things
  have been typed. The basic idea is that this is a log of every interaction that I've had with Claude or Codex agent over the
  last few days.

  Emphasis on the word interaction because it is possible that the agent says something and that was not captured. There are
  two things. One is regular capturing, and the other is whenever I type in something, then it's captured. Basically, there is
  this panel called LSD, and I want you to go through it in a temporal manner and try to understand what results we had, what I
  said, what the methodology was, what the observations were, and those kinds of things. Think about it as the history of my
  research work while working with an AI agent. It has all the things like results tables, important things, and everything.

  In research, you get some results, you change them, you get newer ones, maybe the agent was lying or maybe it made a mistake,
  I clarified it. Usually, my speaking becomes really important and those kinds of things. Keeping that in mind, please go
  through the whole conversations and all the data that is available for that specific panel and try to create a report of all
  the things that have been done over the last week. Right now your goal is just having all the information digested as to what
  things we did, what were the results, what experiments were done, what different settings, and those things. Basically,
  create a big research report as to what happened over the last week."
 actually last 2 weeks
~~~

## Original user instruction 2

Purpose: first slide deck

SHA256: **229d5eca6b577fa1e987e807e75e2155e091a1864572df545cde79fe0a1252b2**

~~~text
cool! now if you were to create a set of presentation slides for say a student presenting in their weekly meeting, how
  you will create it? remember this is for professional PhD student in top university such as stanford or cmu, and is
  presenting their weekly updates to their PI. obviously few obvious things such as it should not be daily notes, but in proper
  order, etc. i hope it makes sense, what i mean by thise setting?? please think properly, and create the slides!"

and remember as a student presenting to PI, engineering details, bugs fixed etc dont matter. those are minor things. keep slides research focussed not engineering focussed
~~~

## Original user instruction 3

Purpose: discard the first deck and rebuild it as a self readable progress report

SHA256: **44244854b85cbb48af480cca01726e9fe14b241e2336e72c19c0df27ba87867e**

~~~text
alright, few language instructions: never use em-dashes (--) or colons (:) or semi colons (-), write proper sentences. never use the style of "x, not y". always give proper context. i understand you had created the slides as one would present to their advisor, but think of it more progress report. massive violations, and missing details are there. massive context is missing before each slide. overall just think about it, are these slides self readable??? not at all. someone would just throw these away, reading the second slide. total marketing shitty language, no context, tons of missing experiments, and inferences, unscientific. so delete the slides now. and redo from scratch
~~~

## Original user instruction 4

Purpose: correct unreadable typography

SHA256: **cc79ebc6d591859af30dcc826e9a9a90c1ef5239088ac9efaf6698d684f54d15**

~~~text
font size is too small. it is basically unreadable
~~~

## Original user instruction 5

Purpose: correct the remaining language problems

SHA256: **b16cea0e433ca4654c2a9d6af1fb59d4b249a737315d979c3501c677ebf73960**

~~~text
So I was going through the slides, and definitely there are big improvements, but the language is still shit. The language is still unscientific. The language is still marketing. The language uses lots of terms that are unexplained or unintroduced and unnecessary. I don't even know who the fuck uses those kinds of terms. Random words just pop out. I'm at loss of words right now for how pathetic the language is.

That's not how you make slides. That's not how you fucking write anything, in fact. That's not how you write human-like writing. That's not how it works. Terrible, man. I mean, I don't know what kind of language is that. For example, randomly you will come up with some words like contrasting trajectories, conditioning, student gains, spending. These half phrases, these random words, I don't really understand, man. This is pathetic language. Pathetic. I mean, I don't know. If I could shout pathetic, that would also be underselling how bad your whole writing is.
~~~

## Runtime composition

Argus does not rewrite the five instructions. It adds only the operational information needed
to run them for another project and to exchange durable files between turns.

### Research turn

Before original instruction 1:

~~~text
This run is for the Argus project named {{PROJECT_NAME}} and the reporting period
{{REPORTING_PERIOD}}. request.json identifies its panels, machines, and workspace roots.
evidence/journal.jsonl contains the matching captured history. In the original instruction
below, "LSD" means this selected project, and every relative date reference means the
reporting period above.

The following is the original user instruction from Codex session
019f630d-5663-7722-bc65-5fd298a497ec. It is copied without rewriting.
~~~

After original instruction 1:

~~~text
Write the resulting report to research-report.md. Write evidence-ledger.json with the journal
or workspace source for each material claim. Do not create slides in this turn.
~~~

### First slide turn

Before original instruction 2:

~~~text
The completed research-report.md and evidence-ledger.json describe the {{PROJECT_NAME}}
project for {{REPORTING_PERIOD}}. Use them and their underlying evidence.

The following is the original user instruction from Codex session
019f630d-5663-7722-bc65-5fd298a497ec. It is copied without rewriting.
~~~

After original instruction 2:

~~~text
Use the installed presentation tooling. Save the editable first version as draft.pptx.
Do not create weekly-progress.pptx yet because the original correction turns follow.
~~~

### Original correction turns

Argus sends original instructions 3, 4, and 5 as three separate turns in their original
order. Each turn also repeats the earlier correction instructions so a restored Codex
conversation cannot lose them. Argus adds this file contract:

~~~text
Edit the PowerPoint itself rather than merely discussing it. Read draft.pptx on the first
correction turn and weekly-progress.pptx on later turns. Save the corrected editable deck as
weekly-progress.pptx. Replace render/final/ with a complete render of that deck. Write
audit.json with this shape:
{
  "passed": true,
  "checks": [{"name": "...", "passed": true, "evidence": "..."}],
  "issues": []
}
Set passed to true only after checking the actual deck and complete render against every
original instruction above.
~~~

### Validation repair

This prompt runs only if the resulting PowerPoint fails Argus's independent checks. The
three original correction instructions are included verbatim before the final paragraph.

~~~text
The deck still failed an objective validation after the original correction sequence. This
is repair pass {{PASS_NUMBER}}. Read audit.json and the Argus-generated language-audit.json.
Fix every recorded issue in weekly-progress.pptx while continuing to follow the three
original correction instructions below.

{{ORIGINAL_INSTRUCTIONS_3_4_AND_5}}

Replace weekly-progress.pptx and render/final/ with the corrected editable deck and its
complete render. Replace audit.json with a truthful result. Do not merely describe the
changes.
~~~

### Restored generation prefix

Argus prepends this only when it must continue a current prompt revision without its previous
Codex conversation identifier.

~~~text
This is a restored weekly-progress generation. Read the existing request, evidence, report,
ledger, deck, and audit files in this directory before continuing.

{{CURRENT_TURN_PROMPT}}
~~~
