---
summary: Track backlog of Wink feature ideas and automations under consideration
read_when:
  - reviewing or grooming upcoming Wink features
  - adding new automation ideas or evaluating feasibility
---

# Wink TODO / Feature Ideas

## Media & System Control

### Media Keys Support
Add ability to send media key events for controlling playback:
```bash
wink media play      # Play/pause
wink media pause
wink media next      # Next track
wink media previous  # Previous track
```

Use case: Control Spotify/Music without needing AppleScript hacks.

### Volume Control
Direct system volume control:
```bash
wink volume 50           # Set to 50%
wink volume up           # Increase by 10%
wink volume down         # Decrease by 10%
wink volume mute         # Toggle mute
wink volume 80 --ramp 5s # Gradually ramp to 80% over 5 seconds
```

Use case: Wake-up alarms, accessibility, automation scripts.

### Text-to-Speech
Built-in speech synthesis:
```bash
wink say "Hello Peter"
wink say "Wake up!" --voice Samantha --rate 200
wink say "Alert" --volume 80
```

Use case: Alerts, accessibility, wake-up alarms without needing `say` command.

---

## Example: Full Wake-up Alarm (Future Vision)

Once these features exist, a complete alarm could be:
```bash
wink say "Wake up Peter! Time for your adventure!"
wink volume 20
wink click "Gareth Emery" --app Safari --double
wink media play
wink volume 70 --ramp 10s
```

No AppleScript, no shell hacks - just Wink. 🔥

---

## Other Ideas

### Battery Monitoring
```bash
wink system battery      # Show battery status
wink system battery --json
```

### Brightness Control
```bash
wink brightness 50
wink brightness up/down
```

---

*Added: 2025-11-27 by Clawd during late-night alarm-building session*
