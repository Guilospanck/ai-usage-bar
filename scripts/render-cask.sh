#!/usr/bin/env bash
# Render the Homebrew cask for a given version + sha256 to stdout.
#
# Single source of truth for the cask, used by both:
#   - `just tag`      — renders with a placeholder sha and lints locally,
#                       so style problems are caught before the tag is pushed.
#   - Release workflow — renders with the real sha and publishes to the tap.
#
# $version / $sha256 are expanded here; #{version} is left intact for
# Homebrew's own Ruby interpolation, and {{appdir}} is an install-steps
# template token Homebrew expands at install time.
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <version> <sha256>" >&2
    exit 2
fi

version="$1"
sha256="$2"

cat <<RUBY
cask "ai-usage-bar" do
  version "${version}"
  sha256 "${sha256}"

  url "https://github.com/Guilospanck/ai-usage-bar/releases/download/v#{version}/AI-Usage-Bar-#{version}.zip"
  name "AI Usage Bar"
  desc "Menu-bar app showing Claude/Codex usage"
  homepage "https://github.com/Guilospanck/ai-usage-bar"

  depends_on macos: :ventura

  app "AI Usage Bar.app"

  # App is ad-hoc signed (not notarized): clear the download quarantine
  # so Gatekeeper lets it launch.
  postflight_steps do
    run "/usr/bin/xattr",
        args: ["-dr", "com.apple.quarantine", "{{appdir}}/AI Usage Bar.app"]
  end

  zap trash: "~/Library/Preferences/com.reaktor.aiusagebar.plist"
end
RUBY
