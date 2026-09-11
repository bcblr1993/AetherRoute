cask "aetherroute" do
  arch arm: "arm64"

  version "1.0.0"
  sha256 "e9c411a54b8fd694583a94cfc49ead4d1d23057fd5251ec969eff3dcfc575065"

  url "https://downloads.baizhiedu.xin/releases/#{version}/AetherRoute-#{version}-#{arch}.dmg"
  name "AetherRoute"
  desc "Native, private routing client engineered exclusively for Apple silicon macOS"
  homepage "https://aetherroute.baizhiedu.xin/"

  livecheck do
    url "https://aetherroute.baizhiedu.xin/releases/"
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
