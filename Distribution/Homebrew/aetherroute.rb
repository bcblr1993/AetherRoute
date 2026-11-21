cask "aetherroute" do
  arch arm: "arm64"

  version "3.1.2,2026112104"
  sha256 "00ae7224ed7377dfbf1d2ef99964f3aff6884e6464c24ba50add80485b336f1f"

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
