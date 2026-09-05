#!/bin/sh
set -eu
umask 077

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# Run the actual inline sanitizer, without compiling cores or starting engines.
ruby - "$ROOT/scripts/test_external_profiles.sh" <<'RUBY'
require "yaml"
require "open3"
require "tmpdir"

script = File.read(ARGV.fetch(0))
program = script[/ruby -r yaml -e '\n(.*?)\n  ' "\$profile" "\$TEMP_DIR\/profile-\$index.yaml"/m, 1]
abort("could not locate the external-profile sanitizer") unless program

common = <<~YAML
  port: 7890
  socks-port: 7891
  redir-port: 7892
  tproxy-port: 7893
  mixed-port: 7894
  allow-lan: true
  bind-address: 0.0.0.0
  secret: dummy-fixture-only
  interface-name: en0
  ipv6: true
  tun: {enable: true}
  dns: {enable: true}
  profile: {store-selected: true, store-fake-ip: true}
  address: &address 127.0.0.1
  proxies:
    - name: :fixture
      type: socks5
      server: *address
      port: 1080
YAML

cases = [
  ["plain colon listener and proxy name", "external-controller: :9095\n", true],
  ["quoted colon listener", "external-controller: \":9095\"\n", true],
  ["explicit YAML string tag", "external-controller: :9095\nlabel: !!str :tagged\n", true],
  ["explicit Ruby symbol", "external-controller: :9095\nlabel: !ruby/symbol fixture\n", false],
  ["explicit Ruby object", "external-controller: :9095\nlabel: !ruby/object:Object {}\n", false],
  ["invalid YAML", "external-controller: [\n", false],
]

Dir.mktmpdir("aetherroute-sanitizer-regression.") do |work|
  cases.each_with_index do |(name, extra, accepted), index|
    input = File.join(work, "input-#{index}.yaml")
    output = File.join(work, "output-#{index}.yaml")
    File.write(input, common + extra)
    _stdout, stderr, status = Open3.capture3("ruby", "-r", "yaml", "-e", program, input, output)
    if accepted
      abort("#{name}: sanitizer failed: #{stderr}") unless status.success?
      data = YAML.safe_load(File.read(output), permitted_classes: [], permitted_symbols: [], aliases: true)
      proxy = data.fetch("proxies").fetch(0)
      checks = [
        %w[port socks-port redir-port tproxy-port mixed-port].all? { |key| data[key] == 0 },
        data["allow-lan"] == false, data["bind-address"] == "127.0.0.1",
        data["external-controller"] == "", !data.key?("secret"), !data.key?("interface-name"),
        data["tun"] == {"enable" => false}, data["dns"] == {"enable" => false},
        data["profile"] == {"store-selected" => false, "store-fake-ip" => false},
        data["ipv6"] == true, proxy["name"] == ":fixture", proxy["port"] == 1080,
        proxy["server"] == "127.0.0.1",
      ]
      checks << (data["label"] == ":tagged") if name == "explicit YAML string tag"
      abort("#{name}: scalar semantics or isolation overrides changed") unless checks.all?
    else
      abort("#{name}: unsafe or invalid YAML was accepted") if status.success? || File.exist?(output)
      expected_error = name == "invalid YAML" ? "Psych::SyntaxError" : "Psych::DisallowedClass"
      abort("#{name}: unexpected rejection") unless stderr.include?(expected_error)
    end
    puts "PASS #{name}"
  end
end
puts "External-profile sanitizer regression passed (6 cases)."
RUBY
