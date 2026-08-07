package distributionservice

import (
	"bufio"
	"context"
	"crypto/ed25519"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"time"
)

const signerRequestLimit = MaximumSignedPayload

type Signer interface {
	SignEntitlement(context.Context, Entitlement) ([]byte, error)
}

type LocalSigner struct {
	privateKey ed25519.PrivateKey
}

func NewLocalSigner(seed []byte) (*LocalSigner, error) {
	if len(seed) != ed25519.SeedSize {
		return nil, errors.New("signing seed must contain exactly 32 bytes")
	}
	return &LocalSigner{privateKey: ed25519.NewKeyFromSeed(seed)}, nil
}

func (signer *LocalSigner) SignEntitlement(_ context.Context, entitlement Entitlement) ([]byte, error) {
	if err := ValidateProductID(entitlement.ProductID); err != nil {
		return nil, err
	}
	if err := entitlement.Validate(entitlement.ProductID, time.Now().UTC()); err != nil {
		return nil, err
	}
	payload, err := MarshalEntitlement(entitlement)
	if err != nil {
		return nil, err
	}
	return SignPayload(signer.privateKey, payload)
}

type SocketSigner struct {
	path      string
	productID string
	timeout   time.Duration
}

func NewSocketSigner(path, productID string, timeout time.Duration) (*SocketSigner, error) {
	if !filepath.IsAbs(path) || filepath.Ext(path) != ".sock" || timeout <= 0 {
		return nil, errors.New("invalid signer client configuration")
	}
	if err := ValidateProductID(productID); err != nil {
		return nil, err
	}
	canonicalPath, err := canonicalSignerSocketPath(path)
	if err != nil {
		return nil, err
	}
	return &SocketSigner{path: canonicalPath, productID: productID, timeout: timeout}, nil
}

func (signer *SocketSigner) SignEntitlement(ctx context.Context, entitlement Entitlement) ([]byte, error) {
	if entitlement.ProductID != signer.productID {
		return nil, errors.New("invalid entitlement product")
	}
	payload, err := MarshalEntitlement(entitlement)
	if err != nil {
		return nil, err
	}
	dialer := net.Dialer{Timeout: signer.timeout}
	connection, err := dialer.DialContext(ctx, "unix", signer.path)
	if err != nil {
		return nil, errors.New("signer unavailable")
	}
	defer connection.Close()
	deadline := time.Now().Add(signer.timeout)
	_ = connection.SetDeadline(deadline)
	if err := writeFrame(connection, payload); err != nil {
		return nil, errors.New("signer request failed")
	}
	response, err := readFrame(connection, MaximumResponseBytes)
	if err != nil {
		return nil, errors.New("signer response failed")
	}
	return response, nil
}

type SignerServer struct {
	path       string
	productID  string
	privateKey ed25519.PrivateKey
	listener   net.Listener
	socketGID  int
}

func NewSignerServer(path, productID string, seed []byte) (*SignerServer, error) {
	if !filepath.IsAbs(path) || filepath.Ext(path) != ".sock" || len(seed) != ed25519.SeedSize {
		return nil, errors.New("invalid signer server configuration")
	}
	if err := ValidateProductID(productID); err != nil {
		return nil, err
	}
	canonicalPath, err := canonicalSignerSocketPath(path)
	if err != nil {
		return nil, err
	}
	if _, err := os.Lstat(canonicalPath); err == nil || !errors.Is(err, os.ErrNotExist) {
		return nil, errors.New("signer socket path already exists")
	}
	return &SignerServer{
		path: canonicalPath, productID: productID,
		privateKey: ed25519.NewKeyFromSeed(seed), socketGID: -1,
	}, nil
}

func (server *SignerServer) SetSocketGroup(groupID int) error {
	if groupID < 0 || server.listener != nil {
		return errors.New("invalid signer socket group")
	}
	server.socketGID = groupID
	return nil
}

func (server *SignerServer) Serve(ctx context.Context) error {
	listener, err := net.Listen("unix", server.path)
	if err != nil {
		return err
	}
	server.listener = listener
	defer func() {
		_ = listener.Close()
		_ = os.Remove(server.path)
	}()
	if server.socketGID >= 0 {
		if err := os.Chown(server.path, -1, server.socketGID); err != nil {
			return err
		}
		if err := os.Chmod(server.path, 0o660); err != nil {
			return err
		}
	} else if err := os.Chmod(server.path, 0o600); err != nil {
		return err
	}
	go func() {
		<-ctx.Done()
		_ = listener.Close()
	}()
	for {
		connection, acceptErr := listener.Accept()
		if acceptErr != nil {
			if ctx.Err() != nil {
				return nil
			}
			return acceptErr
		}
		go server.handle(connection)
	}
}

func (server *SignerServer) handle(connection net.Conn) {
	defer connection.Close()
	_ = connection.SetDeadline(time.Now().Add(5 * time.Second))
	payload, err := readFrame(connection, signerRequestLimit)
	if err != nil {
		return
	}
	var entitlement Entitlement
	if err := decodeExactJSON(payload, &entitlement); err != nil ||
		entitlement.ProductID != server.productID ||
		entitlement.Validate(server.productID, time.Now().UTC()) != nil {
		return
	}
	canonical, err := json.Marshal(entitlement)
	if err != nil || string(canonical) != string(payload) {
		return
	}
	envelope, err := SignPayload(server.privateKey, payload)
	if err != nil {
		return
	}
	_ = writeFrame(connection, envelope)
}

func writeFrame(destination io.Writer, payload []byte) error {
	if len(payload) == 0 || len(payload) > MaximumResponseBytes {
		return errors.New("invalid frame")
	}
	var length [4]byte
	binary.BigEndian.PutUint32(length[:], uint32(len(payload)))
	writer := bufio.NewWriter(destination)
	if _, err := writer.Write(length[:]); err != nil {
		return err
	}
	if _, err := writer.Write(payload); err != nil {
		return err
	}
	return writer.Flush()
}

func readFrame(source io.Reader, limit int) ([]byte, error) {
	var length [4]byte
	if _, err := io.ReadFull(source, length[:]); err != nil {
		return nil, err
	}
	size := int(binary.BigEndian.Uint32(length[:]))
	if size < 1 || size > limit {
		return nil, errors.New("invalid frame size")
	}
	payload := make([]byte, size)
	if _, err := io.ReadFull(source, payload); err != nil {
		return nil, err
	}
	return payload, nil
}
