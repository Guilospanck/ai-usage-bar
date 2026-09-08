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
