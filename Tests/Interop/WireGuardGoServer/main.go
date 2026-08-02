package main

import (
	"context"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/netip"
	"os"
	"os/signal"
	"runtime/debug"
	"sync"
	"syscall"

	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun/netstack"
)

const (
	wireGuardGoVersion  = "v0.0.0-20250521234502-f333402bd9cb"
	wireGuardGoRevision = "f333402bd9cbe0f3eeb02507bd14e23d7d639280"

	serverPrivateKeyHex = "003ed5d73b55806c30de3f8a7bdab38af13539220533055e635690b8b87ad641"
	clientPublicKeyHex  = "f928d4f6c1b86c12f2562c10b07c555c5c57fd00f59e90c8d8d88767271cbf7c"
	serverTunnelAddress = "10.77.0.1"
	clientTunnelAddress = "10.77.0.2"
)

type options struct {
	listenPort uint16
	tcpPort    uint16
	udpPort    uint16
}

func main() {
	log.SetFlags(0)

	listenPort := flag.Uint("listen-port", 59040, "loopback UDP WireGuard endpoint port")
	tcpPort := flag.Uint("tcp-port", 59041, "TCP echo port inside the userspace netstack")
	udpPort := flag.Uint("udp-port", 59042, "UDP echo port inside the userspace netstack")
	showVersion := flag.Bool("version", false, "print the pinned wireguard-go version")
	flag.Parse()

	if *showVersion {
		if err := validatePinnedDependency(); err != nil {
			log.Fatal(err)
		}
		fmt.Printf("wireguard-go %s revision %s\n", wireGuardGoVersion, wireGuardGoRevision)
		return
	}

	opts, err := checkedOptions(*listenPort, *tcpPort, *udpPort)
	if err != nil {
		log.Fatal(err)
	}
	if err := run(opts); err != nil {
		log.Fatal(err)
	}
}

func checkedOptions(listenPort, tcpPort, udpPort uint) (options, error) {
	for name, value := range map[string]uint{
		"listen-port": listenPort,
		"tcp-port":    tcpPort,
		"udp-port":    udpPort,
	} {
		if value == 0 || value > 65535 {
			return options{}, fmt.Errorf("%s must be between 1 and 65535", name)
		}
	}
	if tcpPort == udpPort {
		return options{}, errors.New("tcp-port and udp-port must be different")
	}
	return options{
		listenPort: uint16(listenPort),
		tcpPort:    uint16(tcpPort),
		udpPort:    uint16(udpPort),
	}, nil
}

func run(opts options) error {
	if err := validatePinnedDependency(); err != nil {
		return err
	}
	if err := validatePinnedKeys(); err != nil {
		return err
	}
	tunnelAddress := netip.MustParseAddr(serverTunnelAddress)
	tunDevice, tunnelNet, err := netstack.CreateNetTUN(
		[]netip.Addr{tunnelAddress},
		nil,
		1420,
	)
	if err != nil {
		return fmt.Errorf("create userspace netstack: %w", err)
	}

	bind := &loopbackBind{}
	wgDevice := device.NewDevice(
		tunDevice,
		bind,
		device.NewLogger(device.LogLevelError, "wireguard-go: "),
	)
	defer wgDevice.Close()

	config := fmt.Sprintf(
		"private_key=%s\nlisten_port=%d\npublic_key=%s\nallowed_ip=%s/32\n",
		serverPrivateKeyHex,
		opts.listenPort,
		clientPublicKeyHex,
		clientTunnelAddress,
	)
	if err := wgDevice.IpcSet(config); err != nil {
		return fmt.Errorf("configure WireGuard device: %w", err)
	}
	if err := wgDevice.Up(); err != nil {
		return fmt.Errorf("start WireGuard device: %w", err)
	}

	tcpAddress := netip.AddrPortFrom(tunnelAddress, opts.tcpPort)
	tcpListener, err := tunnelNet.ListenTCPAddrPort(tcpAddress)
	if err != nil {
		return fmt.Errorf("listen on userspace TCP echo address: %w", err)
	}
	defer tcpListener.Close()

	udpAddress := netip.AddrPortFrom(tunnelAddress, opts.udpPort)
	udpConn, err := tunnelNet.ListenUDPAddrPort(udpAddress)
	if err != nil {
		return fmt.Errorf("listen on userspace UDP echo address: %w", err)
	}
	defer udpConn.Close()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	errCh := make(chan error, 2)
	go func() { errCh <- serveTCP(ctx, tcpListener) }()
	go func() { errCh <- serveUDP(ctx, udpConn) }()

	localAddress := bind.LocalAddr()
	if !localAddress.IsValid() || !localAddress.Addr().IsLoopback() {
		return fmt.Errorf("WireGuard bind escaped loopback: %s", localAddress)
	}
	fmt.Printf(
		"READY wireguard-go=%s endpoint=%s tcp=%s udp=%s\n",
		wireGuardGoVersion,
		localAddress,
		tcpAddress,
		udpAddress,
	)

	select {
	case <-ctx.Done():
		return nil
	case err := <-errCh:
		return err
	}
}

type tcpListener interface {
	Accept() (net.Conn, error)
	Close() error
}

func serveTCP(ctx context.Context, listener tcpListener) error {
	for {
		stream, err := listener.Accept()
		if err != nil {
			if ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
				return nil
			}
			return fmt.Errorf("accept userspace TCP connection: %w", err)
		}
		go func() {
			defer stream.Close()
			if _, err := io.Copy(stream, stream); err != nil && !errors.Is(err, net.ErrClosed) {
				log.Printf("TCP echo connection failed: %v", err)
			}
		}()
	}
}

type udpPacketConn interface {
	ReadFrom([]byte) (int, net.Addr, error)
	WriteTo([]byte, net.Addr) (int, error)
	Close() error
}

func serveUDP(ctx context.Context, packetConn udpPacketConn) error {
	buffer := make([]byte, 65535)
	for {
		length, peer, err := packetConn.ReadFrom(buffer)
		if err != nil {
			if ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
				return nil
			}
			return fmt.Errorf("read userspace UDP datagram: %w", err)
		}
		if _, err := packetConn.WriteTo(buffer[:length], peer); err != nil {
			if ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
				return nil
			}
			return fmt.Errorf("write userspace UDP datagram: %w", err)
		}
	}
}

type loopbackBind struct {
	mu   sync.Mutex
	conn *net.UDPConn
}

var _ conn.Bind = (*loopbackBind)(nil)

func (bind *loopbackBind) Open(port uint16) ([]conn.ReceiveFunc, uint16, error) {
	bind.mu.Lock()
	defer bind.mu.Unlock()

	if bind.conn != nil {
		return nil, 0, conn.ErrBindAlreadyOpen
	}
	socket, err := net.ListenUDP("udp4", &net.UDPAddr{
		IP:   net.IPv4(127, 0, 0, 1),
		Port: int(port),
	})
	if err != nil {
		return nil, 0, fmt.Errorf("bind WireGuard endpoint to IPv4 loopback: %w", err)
	}
	bind.conn = socket
	actualPort := uint16(socket.LocalAddr().(*net.UDPAddr).Port)
	return []conn.ReceiveFunc{bind.receive}, actualPort, nil
}

func (bind *loopbackBind) receive(
	packets [][]byte,
	sizes []int,
	endpoints []conn.Endpoint,
) (int, error) {
	bind.mu.Lock()
	socket := bind.conn
	bind.mu.Unlock()
	if socket == nil {
		return 0, net.ErrClosed
	}

	length, peer, err := socket.ReadFromUDPAddrPort(packets[0])
	if err != nil {
		if errors.Is(err, net.ErrClosed) {
			return 0, net.ErrClosed
		}
		return 0, err
	}
	if !peer.Addr().IsLoopback() || !peer.Addr().Is4() {
		return 0, fmt.Errorf("rejected non-loopback WireGuard peer %s", peer)
	}
	sizes[0] = length
	endpoints[0] = &loopbackEndpoint{address: peer}
	return 1, nil
}

func (bind *loopbackBind) Close() error {
	bind.mu.Lock()
	defer bind.mu.Unlock()
	if bind.conn == nil {
		return nil
	}
	err := bind.conn.Close()
	bind.conn = nil
	return err
}

func (bind *loopbackBind) SetMark(mark uint32) error {
	if mark != 0 {
		return fmt.Errorf("socket mark %d is forbidden by the loopback-only test bind", mark)
	}
	return nil
}

func (bind *loopbackBind) Send(buffers [][]byte, endpoint conn.Endpoint) error {
	peer, ok := endpoint.(*loopbackEndpoint)
	if !ok {
		return conn.ErrWrongEndpointType
	}
	if !peer.address.Addr().IsLoopback() || !peer.address.Addr().Is4() {
		return fmt.Errorf("rejected non-loopback WireGuard destination %s", peer.address)
	}

	bind.mu.Lock()
	socket := bind.conn
	bind.mu.Unlock()
	if socket == nil {
		return net.ErrClosed
	}
	for _, buffer := range buffers {
		if _, err := socket.WriteToUDPAddrPort(buffer, peer.address); err != nil {
			if errors.Is(err, net.ErrClosed) {
				return net.ErrClosed
			}
			return err
		}
	}
	return nil
}

func (bind *loopbackBind) ParseEndpoint(value string) (conn.Endpoint, error) {
	address, err := netip.ParseAddrPort(value)
	if err != nil {
		return nil, err
	}
	if !address.Addr().IsLoopback() || !address.Addr().Is4() {
		return nil, fmt.Errorf("WireGuard endpoint must be IPv4 loopback: %s", address)
	}
	return &loopbackEndpoint{address: address}, nil
}

func (*loopbackBind) BatchSize() int {
	return 1
}

func (bind *loopbackBind) LocalAddr() netip.AddrPort {
	bind.mu.Lock()
	defer bind.mu.Unlock()
	if bind.conn == nil {
		return netip.AddrPort{}
	}
	return bind.conn.LocalAddr().(*net.UDPAddr).AddrPort()
}

type loopbackEndpoint struct {
	address netip.AddrPort
}

var _ conn.Endpoint = (*loopbackEndpoint)(nil)

func (*loopbackEndpoint) ClearSrc() {}

func (*loopbackEndpoint) SrcToString() string { return "" }

func (endpoint *loopbackEndpoint) DstToString() string {
	return endpoint.address.String()
}

func (endpoint *loopbackEndpoint) DstToBytes() []byte {
	encoded, _ := endpoint.address.MarshalBinary()
	return encoded
}

func (endpoint *loopbackEndpoint) DstIP() netip.Addr {
	return endpoint.address.Addr()
}

func (*loopbackEndpoint) SrcIP() netip.Addr { return netip.Addr{} }

func validatePinnedKeys() error {
	for name, value := range map[string]string{
		"server private key": serverPrivateKeyHex,
		"client public key":  clientPublicKeyHex,
	} {
		decoded, err := hex.DecodeString(value)
		if err != nil || len(decoded) != 32 {
			return fmt.Errorf("invalid pinned %s", name)
		}
	}
	return nil
}

func validatePinnedDependency() error {
	buildInfo, ok := debug.ReadBuildInfo()
	if !ok {
		return errors.New("Go build information is unavailable")
	}
	for _, dependency := range buildInfo.Deps {
		if dependency.Path == "golang.zx2c4.com/wireguard" {
			if dependency.Replace != nil {
				return errors.New("wireguard-go dependency replacement is forbidden")
			}
			if dependency.Version != wireGuardGoVersion {
				return fmt.Errorf(
					"wireguard-go dependency is %s, expected %s",
					dependency.Version,
					wireGuardGoVersion,
				)
			}
			return nil
		}
	}
	return errors.New("wireguard-go dependency is missing from build information")
}
