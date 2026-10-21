---
summary: 'Review pblog - Wink Log Viewer guidance'
read_when:
  - 'planning work related to pblog - wink log viewer'
  - 'debugging or extending features described here'
---

# pblog - Wink Log Viewer

pblog is a powerful log viewer for monitoring all Wink applications and services through macOS's unified logging system.

## Quick Start

```bash
# View recent logs (last 50 lines from past 5 minutes)
./scripts/pblog.sh

# Stream logs continuously
./scripts/pblog.sh -f

# Show only errors
./scripts/pblog.sh -e

# Debug specific service
./scripts/pblog.sh -c ClickService -d
```

## The Privacy Problem

By default, macOS redacts dynamic values in logs, showing `<private>` instead:

```
Wink: Clicked element <private> at coordinates <private>
```

This makes debugging difficult. See [logging-profiles/README.md](logging-profiles/README.md) for the solution.

## Options

| Flag | Long Option | Description | Default |
|------|-------------|-------------|---------|
| `-n` | `--lines` | Number of lines to show | 50 |
| `-l` | `--last` | Time range to search | 5m |
| `-c` | `--category` | Filter by category | all |
| `-s` | `--search` | Search for specific text | none |
| `-o` | `--output` | Output to file | stdout |
| `-d` | `--debug` | Show debug level logs | info only |
| `-f` | `--follow` | Stream logs continuously | show once |
| `-e` | `--errors` | Show only errors | all levels |
| `--all` | | Show all logs without tail limit | last 50 |
| `--json` | | Output in JSON format | text |
| `--subsystem` | | Filter by specific subsystem | all Wink |

## Wink Subsystems

pblog monitors these subsystems by default:
- `boo.wink.core` - Core services and automation
- `boo.wink.app` - Mac app
- `boo.wink.inspector` - Inspector app
- `boo.wink.playground` - Playground test app
- `boo.wink.axorcist` - AXorcist accessibility library
- `boo.wink` - General components

## Common Usage Patterns

### Debug Element Detection Issues
```bash
./scripts/pblog.sh -c ElementDetectionService -d
```

### Monitor Click Operations
```bash
./scripts/pblog.sh -c ClickService -f
```

### Find Errors in Last Hour
```bash
./scripts/pblog.sh -e -l 1h --all
```

### Search for Specific Text
```bash
./scripts/pblog.sh -s "session" -n 100
```

### Save Logs to File
```bash
./scripts/pblog.sh -l 30m --all -o debug-logs.txt
```

### Monitor Specific App
```bash
./scripts/pblog.sh --subsystem boo.wink.playground -f
```

## Advanced Usage

### Combine Multiple Filters
```bash
# Debug logs from ClickService containing "error"
./scripts/pblog.sh -d -c ClickService -s "error" -f
```

### JSON Output for Processing
```bash
# Export last hour of logs as JSON
./scripts/pblog.sh -l 1h --all --json -o logs.json
```

### Direct Log Commands

If you need more control, you can use the macOS `log` command directly:

```bash
# Show logs with custom predicate
log show --predicate 'subsystem BEGINSWITH "boo.wink" AND eventMessage CONTAINS "click"' --last 5m

# Stream logs with debug level
log stream --predicate 'subsystem == "boo.wink.core"' --level debug
```

## Troubleshooting

### Seeing `<private>` in Logs?

This is macOS's privacy protection. To see the actual values:

1. **Quick Fix**: Use sudo (requires password each time)
   ```bash
   sudo log show --predicate 'subsystem == "boo.wink.core"' --info --last 5m
   ```

2. **Better Solution**: Configure passwordless sudo for the log command.
   See [logging-profiles/README.md](logging-profiles/README.md) for instructions.

### No Logs Appearing?

1. Check if the app is running
2. Verify the subsystem name is correct
3. Try with debug level: `./scripts/pblog.sh -d`
4. Check time range: `./scripts/pblog.sh -l 1h`

### Performance Issues

For large log volumes:
- Use specific time ranges (`-l 5m` instead of `-l 1h`)
- Filter by category (`-c ServiceName`)
- Use search to narrow results (`-s "specific text"`)

## Implementation Details

pblog is a bash script that wraps the macOS `log` command with:
- Predefined predicates for Wink subsystems
- Convenient shortcuts for common operations
- Automatic formatting and tail limiting
- Support for both streaming and historical logs

The script is located at `./scripts/pblog.sh` and can be customized for your needs.