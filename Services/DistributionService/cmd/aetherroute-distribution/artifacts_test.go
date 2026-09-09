package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	distribution "aetherroute.local/distributionservice"
)

const commandTestProductID = "com.aetherroute.desktop"

func TestKeygenPepperAndSignedUpdateArtifact(t *testing.T) {
	directory := commandPrivateTempDir(t)
	seedPath := filepath.Join(directory, "signing-seed.raw")
	publicKeyPath := filepath.Join(directory, "public-key.raw")
	pepperPath := filepath.Join(directory, "pepper.raw")
	if err := runKeygen([]string{"-seed", seedPath, "-public-key", publicKeyPath}); err != nil {
		t.Fatal(err)
	}
	if err := runGeneratePepper([]string{"-output", pepperPath}); err != nil {
		t.Fatal(err)
	}
	seed := commandReadPrivateFile(t, seedPath, ed25519.SeedSize)
	publicKey := commandReadPrivateFile(t, publicKeyPath, ed25519.PublicKeySize)
	commandReadPrivateFile(t, pepperPath, 32)
	expectedPublicKey := ed25519.NewKeyFromSeed(seed).Public().(ed25519.PublicKey)
	if !bytes.Equal(publicKey, expectedPublicKey) {
		t.Fatal("public key does not match generated seed")
	}

	dmgPath := filepath.Join(directory, "AetherRoute-test.dmg")
	dmgContents := bytes.Repeat([]byte("notarized-test-dmg"), 257)
	if err := os.WriteFile(dmgPath, dmgContents, 0o600); err != nil {
		t.Fatal(err)
	}
	publishedAt := time.Now().UTC().Add(-time.Minute).Truncate(time.Second)
	outputPath := filepath.Join(directory, "update-envelope.json")
	arguments := commandSignUpdateArguments(
		seedPath, dmgPath, outputPath, "1.0.1",
		"https://downloads.example.com/releases/1.0.1/AetherRoute-1.0.1-arm64.dmg",
		publishedAt,
	)
	if err := runSignUpdate(arguments); err != nil {
		t.Fatal(err)
	}
	if info, err := os.Stat(outputPath); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("update permissions = %v, %v", info, err)
	}
	envelope, err := os.ReadFile(outputPath)
	if err != nil {
		t.Fatal(err)
	}
	if err := distribution.VerifyUpdateEnvelope(
		envelope, ed25519.PublicKey(publicKey), commandTestProductID, time.Now().UTC(),
	); err != nil {
		t.Fatal(err)
	}
	payload, err := distribution.VerifyEnvelope(envelope, ed25519.PublicKey(publicKey))
	if err != nil {
		t.Fatal(err)
	}
	var manifest distribution.UpdateManifest
	if err := json.Unmarshal(payload, &manifest); err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(dmgContents)
	if manifest.SHA256 != hex.EncodeToString(digest[:]) ||
		manifest.Version != "1.0.1" || manifest.Build != 101 ||
		manifest.DownloadURL != "https://downloads.example.com/releases/1.0.1/AetherRoute-1.0.1-arm64.dmg" ||
		manifest.ReleaseNotesURL == nil ||
		*manifest.ReleaseNotesURL != "https://aetherroute.example.com/releases/1.0.1/" {
		t.Fatalf("unexpected update manifest: %+v", manifest)
	}

	seedSnapshot := append([]byte(nil), seed...)
	if err := runKeygen([]string{"-seed", seedPath, "-public-key", publicKeyPath}); err == nil {
		t.Fatal("keygen overwrote existing outputs")
	}
	if current, err := os.ReadFile(seedPath); err != nil || !bytes.Equal(current, seedSnapshot) {
		t.Fatal("failed keygen changed the existing seed")
	}
	if err := runGeneratePepper([]string{"-output", pepperPath}); err == nil {
		t.Fatal("generate-pepper overwrote an existing output")
	}
	if err := runSignUpdate(arguments); err == nil {
		t.Fatal("sign-update overwrote an existing envelope")
	}
}

func TestArtifactCommandsRejectUnsafePathsAndMetadata(t *testing.T) {
	directory := commandPrivateTempDir(t)
	seedPath := filepath.Join(directory, "seed.raw")
	publicKeyPath := filepath.Join(directory, "public.raw")
	if err := runKeygen([]string{"-seed", seedPath, "-public-key", publicKeyPath}); err != nil {
		t.Fatal(err)
	}
	if err := runKeygen([]string{"-seed", "relative.raw", "-public-key", filepath.Join(directory, "other.raw")}); err == nil {
		t.Fatal("relative key output was accepted")
	}
	linkTarget := filepath.Join(directory, "existing.raw")
	if err := os.WriteFile(linkTarget, []byte("target"), 0o600); err != nil {
		t.Fatal(err)
	}
	linkPath := filepath.Join(directory, "linked.raw")
	if err := os.Symlink(linkTarget, linkPath); err != nil {
		t.Fatal(err)
	}
	if err := runGeneratePepper([]string{"-output", linkPath}); err == nil {
		t.Fatal("symbolic-link output was accepted")
	}
	publicDirectory := filepath.Join(directory, "public-parent")
	if err := os.Mkdir(publicDirectory, 0o755); err != nil {
		t.Fatal(err)
	}
	// Establish the rejected permissions even when the test runner uses umask 077.
	if err := os.Chmod(publicDirectory, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := runGeneratePepper([]string{"-output", filepath.Join(publicDirectory, "pepper.raw")}); err == nil {
		t.Fatal("non-private parent directory was accepted")
	}

	dmgPath := filepath.Join(directory, "candidate.dmg")
	if err := os.WriteFile(dmgPath, []byte("candidate"), 0o600); err != nil {
		t.Fatal(err)
	}
	publishedAt := time.Now().UTC().Add(-time.Minute).Truncate(time.Second)
	for name, mutate := range map[string]func([]string) []string{
		"relative DMG": func(arguments []string) []string {
			return commandReplaceFlag(arguments, "-dmg", "candidate.dmg")
		},
		"insecure URL": func(arguments []string) []string {
			return commandReplaceFlag(arguments, "-download-url", "http://downloads.example.com/app.dmg")
		},
		"invalid version": func(arguments []string) []string {
			return commandReplaceFlag(arguments, "-version", "1.0-beta")
		},
		"relative output": func(arguments []string) []string {
			return commandReplaceFlag(arguments, "-output", "update.json")
		},
	} {
		t.Run(name, func(t *testing.T) {
			output := filepath.Join(directory, "invalid-"+name+".json")
			arguments := commandSignUpdateArguments(
				seedPath, dmgPath, output, "1.0.1",
				"https://downloads.example.com/app.dmg", publishedAt,
			)
			if err := runSignUpdate(mutate(arguments)); err == nil {
				t.Fatal("unsafe sign-update input was accepted")
			}
			if _, err := os.Lstat(output); !os.IsNotExist(err) {
				t.Fatal("failed sign-update left an output file")
			}
		})
	}
}

func commandPrivateTempDir(t *testing.T) string {
	t.Helper()
	directory := t.TempDir()
	if err := os.Chmod(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	return directory
}

func commandReadPrivateFile(t *testing.T, path string, expectedSize int) []byte {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil || info.Mode().Perm() != 0o600 || info.Size() != int64(expectedSize) {
		t.Fatalf("private artifact %s: info=%v err=%v", path, info, err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func commandSignUpdateArguments(
	seedPath, dmgPath, outputPath, version, downloadURL string, publishedAt time.Time,
) []string {
	return []string{
		"-product-id", commandTestProductID,
		"-seed", seedPath,
		"-dmg", dmgPath,
		"-version", version,
		"-build", "101",
		"-published-at", publishedAt.Format(time.RFC3339),
		"-minimum-system", "15.0",
		"-download-url", downloadURL,
		"-release-notes-url", "https://aetherroute.example.com/releases/1.0.1/",
		"-output", outputPath,
	}
}

func commandReplaceFlag(arguments []string, name, value string) []string {
	replaced := append([]string(nil), arguments...)
	for index := 0; index+1 < len(replaced); index++ {
		if replaced[index] == name {
			replaced[index+1] = value
			return replaced
		}
	}
	return replaced
}
