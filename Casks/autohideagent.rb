cask "autohideagent" do
  version "1.1.0"
  sha256 "8d40991e83c36f02a7e2a13704f1aeadb7b105d29cddb91ee7cbbc85738a5e63"

  url "https://github.com/msynthnova/AutoHideAgent/releases/download/v#{version}/AutoHideAgent-macOS-v#{version}.zip"
  name "AutoHideAgent"
  desc "Automatic background window cleaner and memory optimizer for macOS"
  homepage "https://github.com/msynthnova/AutoHideAgent"

  auto_updates true
  depends_on macos: :sonoma

  app "AutoHideAgent.app"

  zap trash: [
    "~/Library/Application Support/AutoHideAgent",
    "~/Library/Caches/com.systems.autohideagent",
    "~/Library/Logs/AutoHideAgent",
    "~/Library/Preferences/com.systems.autohideagent.plist",
  ]
end
