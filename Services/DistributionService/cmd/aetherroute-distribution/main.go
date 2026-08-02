package main

import (
	"context"
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"syscall"
	"time"

	distribution "aetherroute.local/distributionservice"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		_, _ = fmt.Fprintln(os.Stderr, "aetherroute-distribution:", err)
		os.Exit(1)
	}
}

func run(arguments []string) error {
	if len(arguments) == 0 {
		return errors.New("expected signer, serve, issue, set-state, or list")
	}
	switch arguments[0] {
	case "signer":
		return runSigner(arguments[1:])
	case "serve":
		return runServer(arguments[1:])
	case "issue":
		return runIssue(arguments[1:])
	case "set-state":
		return runSetState(arguments[1:])
	case "list":
		return runList(arguments[1:])
	default:
		return errors.New("unknown command")
	}
}

func runSigner(arguments []string) error {
	flags := newFlags("signer")
	productID := flags.String("product-id", "", "stable product identifier")
	seedPath := flags.String("seed", "", "absolute raw Ed25519 seed path")
	socketPath := flags.String("socket", "", "absolute signer socket path")
	if err := flags.Parse(arguments); err != nil || flags.NArg() != 0 {
		return errors.New("invalid signer arguments")
	}
	seed, err := distribution.ReadSecretFile(*seedPath, ed25519.SeedSize)
	if err != nil {
		return fmt.Errorf("read signing seed: %w", err)
	}
	server, err := distribution.NewSignerServer(*socketPath, *productID, seed)
	zero(seed)
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	return server.Serve(ctx)
}

func runServer(arguments []string) error {
	flags := newFlags("serve")
	productID := flags.String("product-id", "", "stable product identifier")
	statePath := flags.String("state", "", "absolute license state JSON path")
	pepperPath := flags.String("pepper", "", "absolute raw 32-byte pepper path")
	publicKeyPath := flags.String("public-key", "", "absolute raw Ed25519 public-key path")
	updatePath := flags.String("update-envelope", "", "absolute signed update envelope path")
	socketPath := flags.String("signer-socket", "", "absolute signer socket path")
	listenAddress := flags.String("listen", "127.0.0.1:9080", "loopback listen address")
	trustForwardedFor := flags.Bool(
		"trust-forwarded-for", false,
		"trust one X-Forwarded-For IP overwritten by the loopback TLS proxy",
	)
	if err := flags.Parse(arguments); err != nil || flags.NArg() != 0 {
		return errors.New("invalid serve arguments")
	}
	if err := validateLoopbackAddress(*listenAddress); err != nil {
		return err
	}
	pepper, err := distribution.ReadSecretFile(*pepperPath, 32)
	if err != nil {
		return fmt.Errorf("read pepper: %w", err)
	}
	defer zero(pepper)
	publicKey, err := readRegularFile(*publicKeyPath, ed25519.PublicKeySize)
	if err != nil {
		return fmt.Errorf("read public key: %w", err)
	}
	updateEnvelope, err := readRegularFile(*updatePath, distribution.MaximumUpdateFileBytes)
	if err != nil {
		return fmt.Errorf("read update envelope: %w", err)
	}
	store, err := distribution.NewStore(*statePath, *productID, pepper)
	if err != nil {
		return err
	}
	signer, err := distribution.NewSocketSigner(*socketPath, *productID, 5*time.Second)
	if err != nil {
		return err
	}
	service, err := distribution.NewService(
		*productID, store, signer, ed25519.PublicKey(publicKey), updateEnvelope,
	)
	if err != nil {
		return err
	}
	service.TrustForwardedFor(*trustForwardedFor)
	listener, err := net.Listen("tcp", *listenAddress)
	if err != nil {
		return err
	}
	defer listener.Close()
	httpServer := &http.Server{
		Handler: service.Handler(), ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout: 10 * time.Second, WriteTimeout: 10 * time.Second,
		IdleTimeout: 30 * time.Second, MaxHeaderBytes: 16 * 1024,
		ErrorLog: log.New(io.Discard, "", 0),
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	done := make(chan error, 1)
	go func() { done <- httpServer.Serve(listener) }()
	select {
	case err := <-done:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	case <-ctx.Done():
		shutdownContext, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := httpServer.Shutdown(shutdownContext); err != nil {
			return err
		}
		err := <-done
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	}
}

func runIssue(arguments []string) error {
	flags, productID, statePath, pepperPath := storeFlags("issue")
	maxDevices := flags.Int("max-devices", 1, "maximum concurrent devices")
	expires := flags.String("expires-at", "", "optional RFC3339 UTC expiry")
	if err := flags.Parse(arguments); err != nil || flags.NArg() != 0 {
		return errors.New("invalid issue arguments")
	}
	store, pepper, err := openStore(*statePath, *productID, *pepperPath)
	if err != nil {
		return err
	}
	defer zero(pepper)
	var expiresAt *time.Time
	if *expires != "" {
		parsed, parseErr := time.Parse(time.RFC3339, *expires)
		if parseErr != nil || parsed.Location() != time.UTC || !parsed.After(time.Now()) {
			return errors.New("expires-at must be a future UTC RFC3339 timestamp")
		}
		parsed = parsed.UTC()
		expiresAt = &parsed
	}
	key, summary, err := store.Issue(*maxDevices, expiresAt, time.Now().UTC())
	if err != nil {
		return err
	}
	output := struct {
		ActivationKey string                      `json:"activationKey"`
		License       distribution.LicenseSummary `json:"license"`
	}{ActivationKey: key, License: summary}
	return writeJSON(os.Stdout, output)
}

func runSetState(arguments []string) error {
	flags, productID, statePath, pepperPath := storeFlags("set-state")
	licenseID := flags.String("license-id", "", "non-secret license identifier")
	state := flags.String("new-state", "", "active or revoked")
	if err := flags.Parse(arguments); err != nil || flags.NArg() != 0 {
		return errors.New("invalid set-state arguments")
	}
	store, pepper, err := openStore(*statePath, *productID, *pepperPath)
	if err != nil {
		return err
	}
	defer zero(pepper)
	return store.SetState(*licenseID, distribution.LicenseState(*state))
}

func runList(arguments []string) error {
	flags, productID, statePath, pepperPath := storeFlags("list")
	if err := flags.Parse(arguments); err != nil || flags.NArg() != 0 {
		return errors.New("invalid list arguments")
	}
	store, pepper, err := openStore(*statePath, *productID, *pepperPath)
	if err != nil {
		return err
	}
	defer zero(pepper)
	licenses, err := store.List()
	if err != nil {
		return err
	}
	return writeJSON(os.Stdout, licenses)
}

func storeFlags(name string) (*flag.FlagSet, *string, *string, *string) {
	flags := newFlags(name)
	return flags,
		flags.String("product-id", "", "stable product identifier"),
		flags.String("state", "", "absolute license state JSON path"),
		flags.String("pepper", "", "absolute raw 32-byte pepper path")
}

func openStore(statePath, productID, pepperPath string) (*distribution.Store, []byte, error) {
	pepper, err := distribution.ReadSecretFile(pepperPath, 32)
	if err != nil {
		return nil, nil, fmt.Errorf("read pepper: %w", err)
	}
	store, err := distribution.NewStore(statePath, productID, pepper)
	if err != nil {
		zero(pepper)
		return nil, nil, err
	}
	return store, pepper, nil
}

func newFlags(name string) *flag.FlagSet {
	flags := flag.NewFlagSet(name, flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	return flags
}

func validateLoopbackAddress(address string) error {
	host, port, err := net.SplitHostPort(address)
	if err != nil || port == "" {
		return errors.New("listen must be a loopback host:port")
	}
	ip := net.ParseIP(host)
	if ip == nil || !ip.IsLoopback() {
		return errors.New("service may listen only on an explicit loopback IP")
	}
	value, err := strconv.Atoi(port)
	if err != nil || value < 1 || value > 65535 {
		return errors.New("invalid listen port")
	}
	return nil
}

func readRegularFile(path string, maximum int) ([]byte, error) {
	if !filepath.IsAbs(path) {
		return nil, errors.New("path must be absolute")
	}
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() || info.Size() < 1 || info.Size() > int64(maximum) {
		return nil, errors.New("file must be non-empty, regular, and within size limit")
	}
	return os.ReadFile(path)
}

func writeJSON(destination io.Writer, value any) error {
	encoder := json.NewEncoder(destination)
	encoder.SetEscapeHTML(true)
	return encoder.Encode(value)
}

func zero(data []byte) {
	for index := range data {
		data[index] = 0
	}
}
