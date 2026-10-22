# Problem annotation for errors and slowdowns

A Dynatrace workflow that asks the Dynatrace Intelligence incident agent to explain a Davis problem, then writes the answer back onto the problem as an annotation. It runs twice per problem: once 10 minutes after the problem opens, and again when it closes.

Originally written by Sam Bernardy, Solutions Architect at Dynatrace. See [Credits](#credits).

> **Status:** the [changes from the original](#changes-from-the-original) are applied and saved on a test environment, but the latest two (the `run-agent` switch and the trigger fixes) haven't been confirmed by a live problem-triggered run yet. This note will be updated once they have.

## How it works

```
Davis problem (error, slowdown or availability; opened or closed)
        │
        ▼
check_for_closure ── on open: waits 10 min, then checks with DQL whether the problem already closed
        │
        ├── still open ─────► get_problem_explanation ───► comment_on_problem
        │                     (incident agent)              "based on data after 10 minutes"
        │
        └── problem closed ─► get_problem_explanation_1 ─► comment_on_problem_1
                              (incident agent)              "built on closure of the problem"
```

| Task | Action | Runs when |
|---|---|---|
| `check_for_closure` | `dynatrace.automations:execute-dql-query` | The problem opened. Waits 600 s, then counts `CLOSED` events for the problem's `display_id` in the last 15 minutes. Skipped when the trigger is a close (`event.status_transition` is `CLOSED` or `RESOLVED`). |
| `get_problem_explanation` | `dynatrace.davis.workflow.actions:run-agent` | The problem is still open after the wait (`closedcount == "0"`). |
| `comment_on_problem` | `dynatrace.davis.problems:annotate-and-link` | The open-problem explanation succeeded. |
| `get_problem_explanation_1` | `dynatrace.davis.workflow.actions:run-agent` | The problem closed (`event.status_transition` is `CLOSED` or `RESOLVED`). |
| `comment_on_problem_1` | `dynatrace.davis.problems:annotate-and-link` | The closed-problem explanation succeeded. |

Both AI tasks run Dynatrace's built-in incident agent:

```json
"action": "dynatrace.davis.workflow.actions:run-agent",
"input": {
  "agent": "dt-system-incident-agent",
  "agentTemplate": "dt-system-incident-agent",
  "agentType": "incident-agent",
  "builtIn": true,
  "prompt": "...",
  "supplementary": ""
}
```

The agent brings its own Dynatrace data tools (DQL, problems, entities, logs), so the task doesn't list tools. These settings come from the **SRE Agent** workflow template that ships with the Dynatrace Intelligence app.

### Trigger

- Davis problem trigger on open and close, for the error, slowdown and availability categories.
- Waits until the problem's analysis is ready (`analysisReady: true`).
- No severity threshold. Many problems carry no `event.severity`, and a threshold filters all of those out (see [Changes from the original](#changes-from-the-original)).
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
  - **Dynatrace Intelligence** (`dynatrace.davis.workflow.actions`). This app provides `run-agent` and the built-in incident agent.
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

## Changes from the original

The original workflow is in commit `82d5ba8`. Each problem below was found by running the workflow on a test environment, and each fix is its own commit.

| # | Symptom | Cause | Fix | Commit |
|---|---|---|---|---|
| 1 | Both AI tasks fail with **App not found** | They used `dynatrace.davis.copilot.workflow.actions:agent-operator`, from an older app that isn't installed everywhere | Switched to `dynatrace.davis.workflow.actions:prompt-agentic-ai` | `e18c2f1` |
| 2 | The run succeeds, but the annotation says the AI "cannot retrieve live data" and lists DQL to run by hand | `prompt-agentic-ai` names no agent, so the AI answers without any Dynatrace tools. It has no tool-selection option to turn on. | Switched to `run-agent` with the built-in `dt-system-incident-agent`, which has its own tools | `b068742` |
| 3 | The workflow almost never fires | A severity threshold of 3 becomes the filter `event.severity <= 3`. Problems without a severity never pass it; on the test environment that was 1,233 of 1,235 problems in a week. | Removed the severity threshold | `2146611` |
| 4 | Nothing is posted when a problem closes | The close checks looked for `event.status_transition == "RESOLVED"`, but closed problems mostly report `CLOSED` (1,229 vs 1 in the same week) | All three conditions now accept `CLOSED` or `RESOLVED` | `2146611` |

Fixes 3 and 4 were already in the original workflow, so they likely affect it on other environments too.

**Details of each fix:**

1. **App not found.** The old action's `instruction` field ("keep the response within 2000 characters") became the prompt's last line. Its `selectedTools` and `selectedServers` fields were dropped because the replacement action doesn't take them.
2. **No tools.** The only inputs are the agent settings shown under [How it works](#how-it-works) plus the unchanged prompt. The agent still returns its answer in `.text`, so the annotation tasks' `{{result("get_problem_explanation")["text"]}}` works unchanged.
3. **Severity threshold.** In the export this is `triggerConfiguration.value.severityThreshold`, now `null`. To filter by severity on an environment where problems do carry one, set it back in the trigger settings.
4. **Close detection.** The three conditions now read:

   ```
   check_for_closure          {{event()["event.status_transition"] not in ["RESOLVED", "CLOSED"]}}
   get_problem_explanation    {{event()["event.status_transition"] not in ["RESOLVED", "CLOSED"] and result("check_for_closure")["records"][0]["closedcount"] == "0"}}
   get_problem_explanation_1  {{event()["event.status_transition"] in ["RESOLVED", "CLOSED"]}}
   ```

To see any change in full:

```bash
git log --oneline -- workflow/problem-annotation.workflow.json
git diff 82d5ba8 HEAD -- workflow/problem-annotation.workflow.json
```

If your environment still has the old `agent-operator` app and you want its explicit tool selection back, start from commit `82d5ba8` and apply fixes 3 and 4 by hand.

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
- **The annotation cites real data**: entity names, log lines, metric values. If it says it can't query the environment, the agent has no tools; see fix 2 under [Changes from the original](#changes-from-the-original).

The open-problem path waits 10 minutes before its AI task starts, so expect at least that long.

A step that ends `DISCARDED` isn't an error. On an open problem only the open branch runs, and on a close only the close branch runs. The agent task cycling between `RUNNING` and `SUSPENDED` is also normal: it's a long-running action that checks back about every 30 seconds.

If the workflow never fires, look at whether matching problems carry the fields your trigger filters on. For example, query `fetch dt.davis.problems, from:now()-7d | summarize count(), by:{isNotNull(event.severity)}` before setting a severity threshold.

## Customizing

| To change | Edit |
|---|---|
| Which problems trigger it | `trigger.eventTrigger.triggerConfiguration.value`: `categories`, `customFilter`, `entityTags`, or `severityThreshold` (only if your problems carry `event.severity`) |
| How long to wait before the first explanation | `tasks.check_for_closure.waitBefore` (seconds), and the `from: -15m` window in its query |
| What the AI writes | `tasks.get_problem_explanation.input.prompt` and `tasks.get_problem_explanation_1.input.prompt` |
| The annotation's title and source | `eventName` and `annotationSource` in the `comment_on_problem` tasks |

## Repository layout

```
workflow/problem-annotation.workflow.json   the workflow, with environment-specific IDs removed
scripts/list-ai-actions.sh                  lists the Dynatrace Intelligence actions on an environment
scripts/watch-event-runs.sh                 waits for the next problem-triggered run and prints its log
```

## Credits

The workflow, its trigger design and the root-cause prompt were originally written by **Sam Bernardy**, Solutions Architect at Dynatrace. This repository adds the fixes listed under [Changes from the original](#changes-from-the-original), the documentation and the helper scripts.

The `run-agent` incident-agent settings come from the **SRE Agent** workflow template that ships with the Dynatrace Intelligence app.

## License

Apache License 2.0. See [LICENSE](LICENSE).
