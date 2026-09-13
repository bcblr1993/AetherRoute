cask "aetherroute" do
  arch arm: "arm64"

  version "1.0.1"
  sha256 "58608a9674d141f86e09083bd701c3aeeef93bbdd9cbfa693f43ab1e931e3a30"

  url "https://github.com/bcblr1993/AetherRoute/releases/download/v1.0.1-build-2026091301/AetherRoute-1.0.1-build-2026091301-#{arch}-Notarized-Test-Normal-Core.dmg"
  name "AetherRoute"
  desc "Native, private routing client engineered exclusively for Apple silicon macOS"
  homepage "https://aetherroute.pages.dev/"

  livecheck do
    url "https://aetherroute.pages.dev/releases/"
    regex(/AetherRoute\s+v?(\d+(?:\.\d+)+)/i)
  end

  auto_updates true
  depends_on macos: ">= :sequoia"
  depends_on arch: :arm64

  app "AetherRoute.app"

  uninstall quit: [
              "com.aetherroute.desktop",
              "com.aetherroute.desktop.packet-tunnel",
              "com.aetherroute.desktop.transparent-proxy",
            ]

  zap trash: [
    "~/Library/Application Support/AetherRoute",
    "~/Library/Caches/com.aetherroute.desktop",
    "~/Library/HTTPStorages/com.aetherroute.desktop",
    "~/Library/Preferences/com.aetherroute.desktop.plist",
    "~/Library/Saved Application State/com.aetherroute.desktop.savedState",
  ]
end
