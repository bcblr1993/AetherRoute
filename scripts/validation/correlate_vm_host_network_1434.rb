#!/usr/bin/ruby
# frozen_string_literal: true

require "csv"
require "set"
require "time"

unless [2, 3].include?(ARGV.length)
  abort "usage: #{$PROGRAM_NAME} vm-samples.tsv host-samples.tsv [maximum-delta-seconds]"
end

vm_path, host_path = ARGV.take(2)
maximum_delta = Integer(ARGV[2] || "45", 10)
abort "maximum delta must be positive" unless maximum_delta.positive?
[vm_path, host_path].each do |path|
  abort "missing regular input: #{path}" unless File.file?(path) && !File.symlink?(path)
end

legacy_vm_header = %w[
  sample utc app_pid app_rss_kb app_fds app_cpu_pct tun_pid tun_rss_kb
  tun_fds tun_cpu_pct vpn_status stub_interface host_interface fixture_a
  fixture_b ipv4_https ipv4_attempt_pattern ipv4_successes
  ipv4_transaction_failures ipv6_https ipv6_attempt_pattern ipv6_successes
  ipv6_transaction_failures dns_udp dns_tcp stun_udp stun_attempt_pattern
  stun_successes stun_datagram_failures stun_min_response_bytes
  stun_max_latency_ms robots_https robots_attempt_pattern robots_successes
  robots_transaction_failures running_tun_sha256
].freeze
raw_vm_header = %w[
  sample utc app_pid app_rss_kb app_fds tun_pid tun_rss_kb tun_fds
  vpn_status stub_interface default_interface google_v4_exit google_v4_http
  google_v4_remote google_v4_dns_s google_v4_connect_s google_v4_tls_s
  google_v4_total_s google_v6_exit google_v6_http google_v6_remote
  google_v6_dns_s google_v6_connect_s google_v6_tls_s google_v6_total_s
  cloudflare_v4_exit cloudflare_v4_http cloudflare_v6_exit cloudflare_v6_http
  dns_udp_exit dns_udp_answers dns_tcp_exit dns_tcp_answers
  profile_catalog_sha256 active_profile_sha256 selection_store_sha256
].freeze
host_header = %w[
  sample utc default_interface google_v4_exit google_v4_http google_v4_remote
  google_v4_dns_s google_v4_connect_s google_v4_tls_s google_v4_total_s
  google_v6_exit google_v6_http google_v6_remote google_v6_dns_s
  google_v6_connect_s google_v6_tls_s google_v6_total_s cloudflare_v4_exit
  cloudflare_v4_http cloudflare_v6_exit cloudflare_v6_http dns_udp_exit
  dns_udp_answers dns_tcp_exit dns_tcp_answers
].freeze

def read_table(path, expected_headers)
  table = CSV.read(path, col_sep: "\t", headers: true)
  matched_header = expected_headers.find { |candidate| table.headers == candidate }
  abort "unexpected TSV schema: #{path}" unless matched_header
  table.each_with_index do |row, index|
    abort "invalid row width in #{path} sample #{index + 1}" unless row.fields.length == matched_header.length
    abort "invalid sequence in #{path}" unless row["sample"] == (index + 1).to_s
    Time.iso8601(row.fetch("utc"))
  rescue ArgumentError, KeyError
    abort "invalid timestamp in #{path} sample #{index + 1}"
  end
  [table, matched_header]
end

def endpoint_failed?(row, prefix)
  row.fetch("#{prefix}_exit") != "0" || row.fetch("#{prefix}_http") != "204"
end

def dns_failed?(row, prefix)
  row.fetch("#{prefix}_exit") != "0" || row.fetch("#{prefix}_answers").to_i < 1
end

def legacy_vm_failures(row)
  failures = []
  {
    "fixture-a" => "fixture_a",
    "fixture-b" => "fixture_b",
    "google-v4" => "ipv4_https",
    "google-v6" => "ipv6_https",
    "dns-udp" => "dns_udp",
    "dns-tcp" => "dns_tcp",
  }.each { |label, field| failures << label unless row[field] == "passed" }
  { "stun-udp" => "stun_udp", "robots" => "robots_https" }.each do |label, field|
    failures << label unless ["-", "passed"].include?(row[field])
  end
  failures << "vpn-state" unless row["vpn_status"] == "Connected"
  failures << "app-process" unless row["app_pid"].match?(/\A[1-9][0-9]*\z/)
  failures << "tun-process" unless row["tun_pid"].match?(/\A[1-9][0-9]*\z/)
  failures << "stub-interface" if [nil, "", "-"].include?(row["stub_interface"])
  failures
end

def raw_vm_failures(row)
  failures = []
  %w[google_v4 google_v6 cloudflare_v4 cloudflare_v6].each do |prefix|
    failures << prefix.tr("_", "-") if endpoint_failed?(row, prefix)
  end
  %w[dns_udp dns_tcp].each do |prefix|
    failures << prefix.tr("_", "-") if dns_failed?(row, prefix)
  end
  failures << "vpn-state" unless row["vpn_status"] == "Connected"
  failures << "app-process" unless row["app_pid"].match?(/\A[1-9][0-9]*\z/)
  failures << "tun-process" unless row["tun_pid"].match?(/\A[1-9][0-9]*\z/)
  failures << "stub-interface" if [nil, "", "-"].include?(row["stub_interface"])
  failures
end

def host_failures(row)
  failures = []
  %w[google_v4 google_v6 cloudflare_v4 cloudflare_v6].each do |prefix|
    failures << prefix.tr("_", "-") if endpoint_failed?(row, prefix)
  end
  %w[dns_udp dns_tcp].each do |prefix|
    failures << prefix.tr("_", "-") if dns_failed?(row, prefix)
  end
  failures
end

def vm_failure_details(row, schema)
  if schema == "raw-v1"
    [
      row["google_v4_exit"], row["google_v4_http"], row["google_v6_exit"],
      row["google_v6_http"], row["cloudflare_v4_exit"],
      row["cloudflare_v4_http"], row["cloudflare_v6_exit"],
      row["cloudflare_v6_http"], row["dns_udp_exit"],
      row["dns_udp_answers"], row["dns_tcp_exit"], row["dns_tcp_answers"],
    ]
  else
    [
      row["ipv4_attempt_pattern"], row["ipv4_https"],
      row["ipv6_attempt_pattern"], row["ipv6_https"], "-", "-", "-", "-",
      row["dns_udp"], "-", row["dns_tcp"], "-",
    ]
  end
end

vm_rows, matched_vm_header = read_table(vm_path, [raw_vm_header, legacy_vm_header])
host_rows, = read_table(host_path, [host_header])
abort "host control contains no samples" if host_rows.empty?

vm_schema = matched_vm_header == raw_vm_header ? "raw-v1" : "legacy-v1"
failure_method = vm_schema == "raw-v1" ? method(:raw_vm_failures) : method(:legacy_vm_failures)
host_timeline = host_rows.map { |row| [Time.iso8601(row.fetch("utc")), row] }
failures = vm_rows.each_with_object([]) do |row, selected|
  targets = failure_method.call(row)
  selected << [row, targets] unless targets.empty?
end

output_header = %w[
  vm_sample vm_utc vm_schema vm_failure_targets vm_vpn vm_stub
  vm_google_v4_exit_or_pattern vm_google_v4_http_or_status
  vm_google_v6_exit_or_pattern vm_google_v6_http_or_status
  vm_cloudflare_v4_exit vm_cloudflare_v4_http vm_cloudflare_v6_exit
  vm_cloudflare_v6_http vm_dns_udp_exit_or_status vm_dns_udp_answers
  vm_dns_tcp_exit_or_status vm_dns_tcp_answers host_sample host_utc
  absolute_delta_seconds correlation_status host_control_status
  host_failure_targets shared_failure_targets classification
  host_google_v4_exit host_google_v4_http host_google_v6_exit
  host_google_v6_http host_cloudflare_v4_exit host_cloudflare_v4_http
  host_cloudflare_v6_exit host_cloudflare_v6_http host_dns_udp_exit
  host_dns_udp_answers host_dns_tcp_exit host_dns_tcp_answers
]
puts output_header.join("\t")

classification_counts = Hash.new(0)
failures.each do |vm_row, vm_targets|
  vm_time = Time.iso8601(vm_row.fetch("utc"))
  host_time, host_row = host_timeline.min_by { |time, _row| (time - vm_time).abs }
  delta = (host_time - vm_time).abs.round
  host_targets = host_failures(host_row)
  shared_targets = Set.new(vm_targets) & Set.new(host_targets)
  correlation_status = delta <= maximum_delta ? "in-window" : "out-of-window"
  classification = if correlation_status == "out-of-window"
                     "out-of-window"
                   elsif shared_targets.any?
                     "shared-target-failure"
                   elsif host_targets.any?
                     "host-other-failure"
                   else
                     "vm-path-only"
                   end
  classification_counts[classification] += 1
  values = [
    vm_row["sample"], vm_row["utc"], vm_schema, vm_targets.join(","),
    vm_row["vpn_status"], vm_row["stub_interface"],
    *vm_failure_details(vm_row, vm_schema),
    host_row["sample"], host_row["utc"], delta, correlation_status,
    host_targets.empty? ? "passed" : "failed", host_targets.join(","),
    shared_targets.to_a.sort.join(","), classification,
    host_row["google_v4_exit"], host_row["google_v4_http"],
    host_row["google_v6_exit"], host_row["google_v6_http"],
    host_row["cloudflare_v4_exit"], host_row["cloudflare_v4_http"],
    host_row["cloudflare_v6_exit"], host_row["cloudflare_v6_http"],
    host_row["dns_udp_exit"], host_row["dns_udp_answers"],
    host_row["dns_tcp_exit"], host_row["dns_tcp_answers"],
  ]
  puts values.join("\t")
end

warn "vm_schema=#{vm_schema}"
warn "vm_failure_rows=#{failures.length}"
warn "host_samples=#{host_rows.length}"
%w[shared-target-failure host-other-failure vm-path-only out-of-window].each do |classification|
  warn "#{classification.tr('-', '_')}=#{classification_counts[classification]}"
end
