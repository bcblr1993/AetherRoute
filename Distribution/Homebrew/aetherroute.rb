cask "aetherroute" do
  arch arm: "arm64"

  version "3.2.1,2026112501"
  sha256 "abcf1f8a51a3def41f712f6cf70c62ef9f113be5a487de8e474742fd79026306"

  url "https://github.com/bcblr1993/AetherRoute/releases/download/v#{version.csv.first}/AetherRoute-#{version.csv.first}-build-#{version.csv.second}-#{arch}.dmg"
  name "AetherRoute"
  desc "Native, private routing client engineered exclusively for Apple silicon macOS"
  homepage "https://www.aethernative.com/"

  livecheck do
    url "https://aethernative.com/apps/aetherroute/appcast.xml"
    strategy :sparkle
  end

  auto_updates true
  depends_on macos: ">= :sequoia"
  depends_on arch: :arm64

  app "AetherRoute.app"

  uninstall quit: [
              "com.aetherroute.desktop",
              "com.aetherroute.desktop.tunnel",
              "com.aetherroute.desktop.transparent-proxy",
            ]

  zap trash: [
    "~/Library/Application Support/AetherRoute",
    "~/Library/Caches/com.aetherroute.desktop",
    "~/Library/Containers/com.aetherroute.desktop",
    "~/Library/Group Containers/group.com.aetherroute.desktop",
    "~/Library/HTTPStorages/com.aetherroute.desktop",
    "~/Library/Preferences/com.aetherroute.desktop.plist",
    "~/Library/Saved Application State/com.aetherroute.desktop.savedState",
  ]
end
