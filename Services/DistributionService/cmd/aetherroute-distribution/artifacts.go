package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"syscall"
	"time"

	distribution "aetherroute.local/distributionservice"
)

func runKeygen(arguments []string) error {
	flags := newFlags("keygen")
	seedPath := flags.String("seed", "", "absolute output path for the raw Ed25519 seed")
	publicKeyPath := flags.String("public-key", "", "absolute output path for the raw Ed25519 public key")
	if err := flags.Parse(arguments); err != nil || flags.NArg() != 0 {
		return errors.New("invalid keygen arguments")
	}
	seedOutput, err := resolveNewPrivateOutput(*seedPath)
	if err != nil {
		return fmt.Errorf("seed output: %w", err)
	}
	publicOutput, err := resolveNewPrivateOutput(*publicKeyPath)
	if err != nil {
		return fmt.Errorf("public-key output: %w", err)
	}
	if seedOutput == publicOutput {
		return errors.New("seed and public-key outputs must differ")
	}
	seed := make([]byte, ed25519.SeedSize)
	defer zero(seed)
	if _, err := rand.Read(seed); err != nil {
		return errors.New("generate signing seed")
	}
	privateKey := ed25519.NewKeyFromSeed(seed)
	defer zero(privateKey)
	publicKey := append([]byte(nil), privateKey.Public().(ed25519.PublicKey)...)
	defer zero(publicKey)
	if err := writeExclusiveFile(seedOutput, seed, 0o600); err != nil {
		return fmt.Errorf("write signing seed: %w", err)
	}
	if err := writeExclusiveFile(publicOutput, publicKey, 0o600); err != nil {
		_ = os.Remove(seedOutput)
		return fmt.Errorf("write public key: %w", err)
	}
	return nil
}

func runGeneratePepper(arguments []string) error {
	flags := newFlags("generate-pepper")
	outputPath := flags.String("output", "", "absolute output path for a raw 32-byte pepper")
	if err := flags.Parse(arguments); err != nil || flags.NArg() != 0 {
		return errors.New("invalid generate-pepper arguments")
	}
	output, err := resolveNewPrivateOutput(*outputPath)
	if err != nil {
		return fmt.Errorf("pepper output: %w", err)
	}
	pepper := make([]byte, 32)
	defer zero(pepper)
	if _, err := rand.Read(pepper); err != nil {
		return errors.New("generate license pepper")
	}
	if err := writeExclusiveFile(output, pepper, 0o600); err != nil {
		return fmt.Errorf("write license pepper: %w", err)
	}
	return nil
}

func runSignUpdate(arguments []string) error {
	flags := newFlags("sign-update")
	productID := flags.String("product-id", "", "stable product identifier")
	seedPath := flags.String("seed", "", "absolute raw Ed25519 seed path")
	dmgPath := flags.String("dmg", "", "absolute notarized DMG path")
	version := flags.String("version", "", "semantic release version")
	build := flags.Int("build", 0, "positive release build number")
	publishedAtValue := flags.String("published-at", "", "UTC RFC3339 publication timestamp")
	minimumSystem := flags.String("minimum-system", "", "minimum macOS version")
	downloadURL := flags.String("download-url", "", "final HTTPS DMG URL")
	releaseNotesURL := flags.String("release-notes-url", "", "optional final HTTPS release-notes URL")
	outputPath := flags.String("output", "", "absolute new signed-envelope path")
	if err := flags.Parse(arguments); err != nil || flags.NArg() != 0 {
		return errors.New("invalid sign-update arguments")
	}
	if err := distribution.ValidateProductID(*productID); err != nil {
		return err
	}
	publishedAt, err := time.Parse(time.RFC3339, *publishedAtValue)
	if err != nil || publishedAt.Location() != time.UTC {
		return errors.New("published-at must be a UTC RFC3339 timestamp")
	}
	output, err := resolveNewPrivateOutput(*outputPath)
	if err != nil {
		return fmt.Errorf("update output: %w", err)
	}
	seed, err := distribution.ReadSecretFile(*seedPath, ed25519.SeedSize)
	if err != nil {
		return fmt.Errorf("read signing seed: %w", err)
	}
	defer zero(seed)
	digest, err := digestRegularFile(*dmgPath)
	if err != nil {
		return fmt.Errorf("hash DMG: %w", err)
	}
	var notes *string
	if *releaseNotesURL != "" {
		value := *releaseNotesURL
		notes = &value
	}
	manifest := distribution.UpdateManifest{
		SchemaVersion: distribution.SchemaVersion,
		ProductID:     *productID, Version: *version, Build: *build,
		PublishedAt: publishedAt.UTC(), MinimumSystem: *minimumSystem,
		Architecture: "arm64", DownloadURL: *downloadURL,
		SHA256: digest, ReleaseNotesURL: notes,
	}
	if err := manifest.Validate(*productID, time.Now().UTC()); err != nil {
		return err
	}
	payload, err := json.Marshal(manifest)
	if err != nil {
		return errors.New("encode update manifest")
	}
	privateKey := ed25519.NewKeyFromSeed(seed)
	defer zero(privateKey)
	envelope, err := distribution.SignPayload(privateKey, payload)
	if err != nil {
		return err
	}
	publicKey := privateKey.Public().(ed25519.PublicKey)
	if err := distribution.VerifyUpdateEnvelope(envelope, publicKey, *productID, time.Now().UTC()); err != nil {
		return errors.New("signed update envelope failed verification")
	}
	if err := writeExclusiveFile(output, append(envelope, '\n'), 0o600); err != nil {
		return fmt.Errorf("write update envelope: %w", err)
	}
	return nil
}

func resolveNewPrivateOutput(path string) (string, error) {
	if !filepath.IsAbs(path) || filepath.Base(filepath.Clean(path)) == "." {
		return "", errors.New("output path must be absolute")
	}
	directory := filepath.Dir(filepath.Clean(path))
	resolvedDirectory, err := filepath.EvalSymlinks(directory)
	if err != nil {
		return "", errors.New("output parent directory must already exist")
	}
	info, err := os.Stat(resolvedDirectory)
	if err != nil || !info.IsDir() || info.Mode().Perm()&0o077 != 0 {
		return "", errors.New("output parent directory must be mode 700")
	}
	output := filepath.Join(resolvedDirectory, filepath.Base(path))
	if _, err := os.Lstat(output); err == nil || !errors.Is(err, os.ErrNotExist) {
		return "", errors.New("output already exists")
	}
	return output, nil
}

func writeExclusiveFile(path string, data []byte, mode os.FileMode) (writeErr error) {
	file, err := os.OpenFile(
		path, os.O_WRONLY|os.O_CREATE|os.O_EXCL|syscall.O_NOFOLLOW, mode,
	)
	if err != nil {
		return err
	}
	completed := false
	defer func() {
		if closeErr := file.Close(); writeErr == nil && closeErr != nil {
			writeErr = closeErr
		}
		if !completed || writeErr != nil {
			_ = os.Remove(path)
		}
	}()
	if err := file.Chmod(mode); err != nil {
		return err
	}
	if written, err := file.Write(data); err != nil || written != len(data) {
		if err != nil {
			return err
		}
		return io.ErrShortWrite
	}
	if err := file.Sync(); err != nil {
		return err
	}
	completed = true
	return nil
}

func digestRegularFile(path string) (string, error) {
	if !filepath.IsAbs(path) {
		return "", errors.New("DMG path must be absolute")
	}
	file, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return "", err
	}
	defer file.Close()
	before, err := file.Stat()
	if err != nil || !before.Mode().IsRegular() || before.Size() < 1 {
		return "", errors.New("DMG must be a non-empty regular file")
	}
	hash := sha256.New()
	written, err := io.Copy(hash, file)
	if err != nil || written != before.Size() {
		return "", errors.New("DMG changed while hashing")
	}
	after, err := file.Stat()
	if err != nil || after.Size() != before.Size() || !after.ModTime().Equal(before.ModTime()) {
		return "", errors.New("DMG changed while hashing")
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}
