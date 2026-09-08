# AI Usage Bar — task runner. Run `just` to list recipes.
# Install just: `brew install just`

app_name := "AI Usage Bar"
bin      := "AIUsageBar"
bundle   := "build/" + app_name + ".app"

# Show available recipes (default).
default:
    @just --list

# --- Develop -------------------------------------------------------------

# Fetch usage once and print it — no GUI. Fastest way to verify tokens/endpoints.
probe:
    swift run {{bin}} --probe

# Print raw HTTP status + response body for each endpoint (for debugging shapes).
dump:
    swift run {{bin}} --dump

# Run the menu-bar app straight from a debug build (⌘Q or `just kill` to stop).
run:
    swift run {{bin}}

# Compile a debug build without running.
build:
    swift build

# Compile an optimized release binary.
release:
    swift build -c release

# --- Package & install ---------------------------------------------------

# Build + bundle + ad-hoc sign the .app (delegates to build.sh).
app:
    ./build.sh

# Open the bundled app (builds it first if missing).
open: _ensure-app
    open "{{bundle}}"

# Copy the app into /Applications.
install: app
    rm -rf "/Applications/{{app_name}}.app"
    cp -R "{{bundle}}" /Applications/
    @echo "✓ Installed to /Applications/{{app_name}}.app"

# Remove the app from /Applications.
uninstall:
    rm -rf "/Applications/{{app_name}}.app"
    @echo "✓ Removed /Applications/{{app_name}}.app"

_ensure-app:
    @test -d "{{bundle}}" || just app

# --- Release -------------------------------------------------------------

# Bump the version, commit, tag, and push — triggers the Release workflow.
# Usage: just tag 1.1
tag version:
    #!/usr/bin/env bash
    set -euo pipefail
    ver="{{version}}"
    if ! [[ "$ver" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        echo "✗ version must look like 1.1 or 1.1.0 (got '$ver')" >&2; exit 1
    fi
    if [[ -n "$(git status --porcelain)" ]]; then
        echo "✗ working tree not clean — commit or stash first." >&2; exit 1
    fi
    if git rev-parse "v$ver" >/dev/null 2>&1; then
        echo "✗ tag v$ver already exists." >&2; exit 1
    fi
    # Pre-flight: lint the exact cask CI will publish for this version, so
    # style/deprecation issues are caught here — before anything is tagged or
    # pushed — instead of surfacing only after users run `brew install`.
    command -v brew >/dev/null || { echo "✗ install Homebrew to lint the cask: https://brew.sh" >&2; exit 1; }
    # Render under a Casks/ dir so `brew style` recognizes it as a cask and
    # applies the cask cops (a loose .rb elsewhere gets the generic Ruby
    # ruleset instead — Sorbet sigils, frozen-string comment, etc.).
    caskdir="$(mktemp -d)/Casks"
    mkdir -p "$caskdir"
    # sha256 is unknown until CI builds the zip; a placeholder is fine for style.
    ./scripts/render-cask.sh "$ver" "$(printf '%064d' 0)" > "$caskdir/ai-usage-bar.rb"
    brew style "$caskdir/ai-usage-bar.rb"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $ver" Info.plist
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $ver" Info.plist
    git add Info.plist
    git commit -m "Release v$ver"
    git tag "v$ver"
    git push origin HEAD
    git push origin "v$ver"
    echo "✓ Pushed v$ver — CI will build, release, and update the tap."

# One-time: create a write-scoped deploy key for the tap and store its private
# half as a secret in this repo, so CI can push the cask. Needs gh (authed).
# Usage: just setup-tap-key
setup-tap-key:
    #!/usr/bin/env bash
    set -euo pipefail
    command -v gh >/dev/null || { echo "✗ install gh first: brew install gh" >&2; exit 1; }
    umask 077
    tmp="$(mktemp -d)"
    trap 'rm -rf -- "$tmp"' EXIT
    ssh-keygen -t ed25519 -N "" -C "ai-usage-bar release CI" -f "$tmp/key" >/dev/null
    gh repo deploy-key add "$tmp/key.pub" \
        -R Guilospanck/homebrew-tap \
        --title "ai-usage-bar release CI" \
        --allow-write
    if ! gh secret set HOMEBREW_TAP_DEPLOY_KEY \
        -R Guilospanck/ai-usage-bar < "$tmp/key"; then
        echo "✗ Failed to store the private key; removing the deploy key from homebrew-tap." >&2
        public_key="$(awk '{print $1 " " $2}' "$tmp/key.pub")"
        key_id="$(gh repo deploy-key list \
            -R Guilospanck/homebrew-tap \
            --json id,key \
            --jq ".[] | select(.key == \"$public_key\") | .id" || true)"
        if [[ -n "$key_id" ]] && gh repo deploy-key delete "$key_id" -R Guilospanck/homebrew-tap; then
            echo "✓ Removed the deploy key." >&2
        else
            echo "⚠ Could not remove the deploy key automatically; remove it from homebrew-tap manually." >&2
        fi
        exit 1
    fi
    echo "✓ Deploy key added to homebrew-tap (write) and stored as HOMEBREW_TAP_DEPLOY_KEY."

# --- Runtime control -----------------------------------------------------

# Stop any running instance.
kill:
    -pkill -x {{bin}}

# Rebuild the bundle and relaunch it fresh.
restart: kill app
    open "{{bundle}}"

# --- Housekeeping --------------------------------------------------------

# Check that the CLIs' credential files/keychain items exist.
creds:
    @echo "Claude file:  $(test -f ~/.claude/.credentials.json && echo present || echo 'absent (may be in Keychain)')"
    @echo "Claude keychain: $(security find-generic-password -s 'Claude Code-credentials' >/dev/null 2>&1 && echo present || echo absent)"
    @echo "Codex file:   $(test -f ~/.codex/auth.json && echo present || echo absent)"

# Print toolchain versions.
doctor:
    @swift --version
    @just --version

# Remove all build artifacts.
clean:
    rm -rf .build build
    @echo "✓ Cleaned .build and build/"
