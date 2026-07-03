<!-- SPDX-License-Identifier: MIT -->
# Development

```
uv run pytest
```

Core modules are near-fully covered with a fake clock, an in-memory store, and a
fake LLM returning canned JSON. Adapters get thin smoke tests. CI runs the suite
on every push and pull request.

The unit suite uses a fake LLM. To check the interpreter against the *real*
model (after tuning the prompt or changing `HOB_MODEL`), run the eval, which
feeds representative messages through Ollama and asserts the resulting plan:

```
HOB_MODEL=qwen2.5:14b-instruct uv run python evals/interpreter_eval.py
```

On Windows, a `tzdata` package is installed under a platform marker so the
standard-library `zoneinfo` has a timezone database; on the macOS target the OS
provides it and the marker keeps it off that environment.
