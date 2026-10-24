---
description: Toggle vibe-cop advisor mode (read-only, advise-only). Usage: /vibe-cop on|off|status
argument-hint: on|off|status
disable-model-invocation: true
---

Run exactly this with the Bash tool, then do what its output says:

```
"${CLAUDE_PLUGIN_ROOT}/scripts/vibe-cop-toggle.sh" $ARGUMENTS
```

This is the vibe-cop mode control. It only reads and writes a small state marker
under the temp directory, and the plugin's hook auto-approves it, so it will not
prompt. If the output shows the mode is now ON, adopt the advisor role it
describes for the rest of this session until `/vibe-cop off`.
