cask "autohideagent" do
  version "1.4.2"
  sha256 "19f17963a7cef9fbb6d76e911042008a3c294a0752d62643a13242ad2081e8e1"

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
