cask "autohideagent" do
  version "1.0.0"
  sha256 "acfaff73aade1c9cb0cf093e180eec8ee0a6918ec66f8f1d4effbb3045bcdf71"

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
