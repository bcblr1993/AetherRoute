def component:
  {
    name: .package.name,
    version: .package.version,
    license: .license,
    repository: (.package.repository // "")
  };

def component_id:
  "\(.crate.name)@\(.crate.version)";

def license_block:
  {
    id: .id,
    name: .name,
    text: .text,
    components: ([.used_by[] | component_id] | unique | sort)
  };

def compact_report:
  {
    components: ([.crates[] | component]
      | unique_by([.name, .version, .repository])
      | sort_by([.name, .version, .repository])),
    licenses: ([.licenses[] | license_block]
      | sort_by([.id, .name, .text]))
  };

if length == 1 then
  .[0] | compact_report
else
  (.[0] | compact_report) as $transparentProxy |
  (.[1] | compact_report) as $packetTunnel |
  {
    components: (($transparentProxy.components + $packetTunnel.components)
      | unique_by([.name, .version, .repository])
      | sort_by([.name, .version, .repository])),
    licenses: (($transparentProxy.licenses + $packetTunnel.licenses)
      | group_by([.id, .name, .text])
      | map({
          id: .[0].id,
          name: .[0].name,
          text: .[0].text,
          components: ([.[].components[]] | unique | sort)
        })
      | sort_by([.id, .name, .text]))
  }
end
| {
    schemaVersion: 1,
    surface: $surface,
    coreArtifacts: {
      transparentProxy: $transparentProxyHash,
      packetTunnel: $packetTunnelHash
    },
    components,
    licenses
  }
