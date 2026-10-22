# Problem annotation for errors and slowdowns

A Dynatrace workflow that asks the Dynatrace Intelligence agentic AI to explain a Davis problem, then writes the answer back onto the problem as an annotation. It runs twice per problem: once 10 minutes after the problem opens, and again when it closes.

## How it works

```
Davis problem (error, slowdown or availability; opened or closed)
        │
        ▼
check_for_closure ── on open: waits 10 min, then checks with DQL whether the problem already closed
        │
        ├── still open ─────► get_problem_explanation ───► comment_on_problem
        │                     (agentic AI)                  "based on data after 10 minutes"
        │
        └── problem closed ─► get_problem_explanation_1 ─► comment_on_problem_1
                              (agentic AI)                  "built on closure of the problem"
```

| Task | Action | Runs when |
|---|---|---|
| `check_for_closure` | `dynatrace.automations:execute-dql-query` | The problem opened. Waits 600 s, then counts `CLOSED` events for the problem's `display_id` in the last 15 minutes. Skipped on close. |
| `get_problem_explanation` | `dynatrace.davis.workflow.actions:prompt-agentic-ai` | The problem is still open after the wait (`closedcount == "0"`). |
| `comment_on_problem` | `dynatrace.davis.problems:annotate-and-link` | The open-problem explanation succeeded. |
| `get_problem_explanation_1` | `dynatrace.davis.workflow.actions:prompt-agentic-ai` | The problem was resolved (`event.status_transition == "RESOLVED"`). |
| `comment_on_problem_1` | `dynatrace.davis.problems:annotate-and-link` | The closed-problem explanation succeeded. |

### Trigger

- Davis problem trigger on open and close, for the error, slowdown and availability categories.
- Waits until the problem's analysis is ready (`analysisReady: true`), with a severity threshold of 3.
- Skips "Out-of-memory kills" and "backoff" problems:

  ```
  not (matchesPhrase(event.name,"Out-of-memory kills")) and
  not (matchesPhrase(event.name,"backoff"))
  ```

- At most 1,000 runs an hour.

### The prompt

Both AI tasks use the same prompt. It asks for an explanation of the problem as a senior application support engineer would write it, covering the impact, the root-cause entity, the impacted services, infrastructure and network context, end-user impact (only when a frontend is affected) and next steps (only when the evidence supports them). The full text is in [`workflow/problem-annotation.workflow.json`](workflow/problem-annotation.workflow.json). It ends with "Keep the response within 2000 characters." so the annotation stays readable.

## Requirements

- A Dynatrace SaaS environment with these apps installed:
  - **Workflows** (`dynatrace.automations`)
  - **Dynatrace Intelligence** (`dynatrace.davis.workflow.actions`). This app provides `prompt-agentic-ai`.
  - **Problems** (`dynatrace.davis.problems`). This app provides `annotate-and-link`.
- Dynatrace Intelligence and agentic AI enabled for the environment.
- A workflow actor with permission to query Grail events, run the agentic AI and annotate problems.

To check what your environment has, run [`scripts/list-ai-actions.sh`](scripts/list-ai-actions.sh) (needs [dtctl](https://github.com/dynatrace-oss/dtctl)):

```bash
scripts/list-ai-actions.sh my-context
```

## Install

**In the Workflows app:** choose **Upload**, then select `workflow/problem-annotation.workflow.json`. Open the new workflow and save it once so it gets an actor.

**With dtctl:**

```bash
dtctl apply -f workflow/problem-annotation.workflow.json --context my-context
```

The file has no `id`, so either way this creates a new workflow. To update an existing one, add its `id` to the file before running `apply`.

## Fixing "App not found"

The workflow was first built with an older agentic AI action:

| | Before | After |
|---|---|---|
| Action | `dynatrace.davis.copilot.workflow.actions:agent-operator` | `dynatrace.davis.workflow.actions:prompt-agentic-ai` |
| App | Davis CoPilot workflow actions | Dynatrace Intelligence |
| Inputs | `prompt`, `instruction`, `selectedTools`, `selectedServers`, `outputFormat`, `supplementary`, `conversationId` | `prompt` |

Environments that don't have the older app fail both AI tasks with **App not found**. The fix, in commit `e18c2f1`:

1. Point both AI tasks at `dynatrace.davis.workflow.actions:prompt-agentic-ai`.
2. Send only `prompt`. The old `instruction` ("keep the response within 2000 characters") becomes the prompt's last line.
3. Drop `selectedTools` and `selectedServers`. The new action doesn't take an explicit tool list in the form the old one did.
4. Leave the annotation tasks as they are. The new action still returns its answer in `.text`, so `{{result("get_problem_explanation")["text"]}}` works unchanged.

To see both versions side by side:

```bash
git diff 82d5ba8 e18c2f1 -- workflow/problem-annotation.workflow.json
```

If your environment still has the old app and you want the old tool selection back, use the workflow from commit `82d5ba8`.

## Testing

**Don't test with the Run button.** A manual run has no problem attached (`event: {}`), so the conditions that read `event()["event.status_transition"]` fail with:

```
Error evaluating custom condition. Undefined variables: event.status_transition.
```

That error means "no problem attached", not that the workflow is broken. Wait for a real problem that matches the trigger instead, then check the run:

```bash
scripts/watch-event-runs.sh <workflow-id> my-context
```

The script waits for the next problem-triggered run to finish and prints its task log. In a good run:

- `get_problem_explanation` (open problem) or `get_problem_explanation_1` (closed problem) ends in `SUCCESS`.
- The matching `comment_on_problem` task posts the annotation, which shows on the problem in the Problems app.

The open-problem path waits 10 minutes before its AI task starts, so expect at least that long.

## Customizing

| To change | Edit |
|---|---|
| Which problems trigger it | `trigger.eventTrigger.triggerConfiguration.value`: `categories`, `customFilter`, `severityThreshold`, `entityTags` |
| How long to wait before the first explanation | `tasks.check_for_closure.waitBefore` (seconds), and the `from: -15m` window in its query |
| What the AI writes | `tasks.get_problem_explanation.input.prompt` and `tasks.get_problem_explanation_1.input.prompt` |
| The annotation's title and source | `eventName` and `annotationSource` in the `comment_on_problem` tasks |

## Repository layout

```
workflow/problem-annotation.workflow.json   the workflow, with environment-specific IDs removed
scripts/list-ai-actions.sh                  lists the Dynatrace Intelligence actions on an environment
scripts/watch-event-runs.sh                 waits for the next problem-triggered run and prints its log
```
