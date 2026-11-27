# Acme Notes pricing page (demo app)

A small, static pricing page that had never used Flagsmith. It exists so a coding agent can run
the [`prove-it-works`](https://github.com/faizydroid/prove-it-works) skill on a real codebase,
from the first question to the archived flag. The run is recorded in this repo's pull requests.

Run it locally:

```
python -m http.server 8000
# open http://localhost:8000
```

`flagsmith.json` binds this folder to the `toggle-wars` project's **Development** environment on
Flagsmith Cloud. Development only ever gets scripted traffic.

The skill is vendored at `.claude/skills/prove-it-works/` so Claude Code picks it up when started
in this folder. It's a copy of `skills/prove-it-works` from the main repo.
