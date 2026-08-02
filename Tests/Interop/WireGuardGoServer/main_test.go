package main

import (
	"errors"
	"net"
	"testing"
	"time"

	"golang.zx2c4.com/wireguard/conn"
)

func TestLoopbackBindRejectsNonLoopbackEndpoints(t *testing.T) {
	bind := &loopbackBind{}
	if _, err := bind.ParseEndpoint("192.0.2.1:51820"); err == nil {
		t.Fatal("non-loopback endpoint unexpectedly accepted")
	}
	if _, err := bind.ParseEndpoint("[::1]:51820"); err == nil {
		t.Fatal("IPv6 endpoint unexpectedly accepted by IPv4-only bind")
	}
	if _, err := bind.ParseEndpoint("127.0.0.1:51820"); err != nil {
		t.Fatalf("IPv4 loopback endpoint rejected: %v", err)
	}
}

func TestLoopbackBindUsesOnlyIPv4Loopback(t *testing.T) {
	bind := &loopbackBind{}
	receivers, port, err := bind.Open(0)
	if err != nil {
		t.Fatalf("open loopback bind: %v", err)
	}
	if len(receivers) != 1 || port == 0 {
		t.Fatalf("unexpected bind result: receivers=%d port=%d", len(receivers), port)
	}
	t.Cleanup(func() { _ = bind.Close() })

	local := bind.LocalAddr()
	if !local.Addr().Is4() || !local.Addr().IsLoopback() {
		t.Fatalf("bind escaped IPv4 loopback: %s", local)
	}

	received := make(chan error, 1)
	go func() {
		packets := [][]byte{make([]byte, 64)}
		sizes := make([]int, 1)
		endpoints := make([]conn.Endpoint, 1)
		count, err := receivers[0](packets, sizes, endpoints)
		if err == nil && (count != 1 || sizes[0] != 4) {
			err = errors.New("received datagram metadata changed")
		}
		received <- err
	}()

	client, err := net.DialUDP("udp4", nil, net.UDPAddrFromAddrPort(local))
	if err != nil {
		t.Fatalf("dial loopback bind: %v", err)
	}
	defer client.Close()
	if _, err := client.Write([]byte("test")); err != nil {
		t.Fatalf("write loopback datagram: %v", err)
	}

	select {
	case err := <-received:
		if err != nil {
			t.Fatalf("receive loopback datagram: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("loopback receive timed out")
	}
}

func TestPinnedWireGuardKeysAreExactly32Bytes(t *testing.T) {
	if err := validatePinnedKeys(); err != nil {
		t.Fatal(err)
	}
}

func TestWireGuardGoDependencyIsPinned(t *testing.T) {
	if err := validatePinnedDependency(); err != nil {
		t.Fatal(err)
	}
}
