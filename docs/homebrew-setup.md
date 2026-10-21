---
summary: 'Maintain the Wink formula in openclaw/homebrew-tap'
read_when:
  - 'publishing or repairing the Wink Homebrew formula'
  - 'testing a release archive through Homebrew'
---

# Setting Up Homebrew Tap for Wink

This guide explains how the shipped universal CLI archive reaches the Wink formula in [github.com/openclaw/homebrew-tap](https://github.com/openclaw/homebrew-tap).

## Repository Structure

The tap owns the installable `Formula/wink.rb`. This repository keeps `homebrew/wink.rb` as the formula template and includes:

- `scripts/update-homebrew-formula.sh` for a manual version/SHA update.
- `.github/workflows/update-homebrew.yml`, which dispatches the tap's `update-formula.yml` workflow after a GitHub Release is published.
- `wink-macos-universal.tar.gz` as the release artifact consumed by the formula.

## Usage

### Installing Wink via Homebrew

```bash
brew install openclaw/tap/peekaboo
```

### Updating Wink

```bash
brew update
brew upgrade openclaw/tap/peekaboo
```

## Release Process

### Automated (Recommended)

Publishing a GitHub Release runs `.github/workflows/update-homebrew.yml`. The workflow:

1. Resolves the published `v<version>` tag.
2. Dispatches `openclaw/homebrew-tap`'s `update-formula.yml` with the source repository, tag, formula name, and `wink-macos-universal.tar.gz` asset.
3. Locates the exact dispatched run and waits for it to finish.

`HOMEBREW_TAP_TOKEN` must have workflow access to `openclaw/homebrew-tap`.

### Manual Update

If the dispatch needs repair, calculate the SHA-256 of the final universal archive and update the template:

```bash
VERSION="$(node -p "require('./package.json').version")"
ARCHIVE=build/release/wink-macos-universal.tar.gz
SHA256="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
./scripts/update-homebrew-formula.sh "$VERSION" "$SHA256"
```

The helper updates the formula URL, `sha256`, and `version` for the current package version. Review the diff, then copy the resulting `homebrew/wink.rb` to `Formula/wink.rb` in the tap and commit it there.

## Testing

### Test Installation

```bash
brew uninstall wink 2>/dev/null || true
brew install --verbose --debug openclaw/tap/peekaboo
brew test openclaw/tap/peekaboo
wink --version
```

### Test Formula Locally

```bash
brew install --build-from-source ./homebrew/wink.rb
```

## Troubleshooting

### SHA256 Mismatch

- Hash the exact `wink-macos-universal.tar.gz` uploaded to the published release.
- Confirm the formula URL and version point at the same tag.

### Download Failures

- Confirm the release is published rather than draft.
- Confirm the release contains `wink-macos-universal.tar.gz`.

### Debugging

```bash
brew tap-info openclaw/tap
brew audit --strict openclaw/tap/peekaboo
```

## Maintenance

The checked-in formula currently requires macOS Sequoia or later:

```ruby
depends_on macos: :sequoia
```

When the minimum changes, update both the formula and the public platform documentation, then test the release archive on every supported architecture.

## References

- [Homebrew Formula Cookbook](https://docs.brew.sh/Formula-Cookbook)
- [Homebrew Taps](https://docs.brew.sh/Taps)
