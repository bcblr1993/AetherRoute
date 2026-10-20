"""Exercise shipping Swift proxy sessions using ephemeral loopback sockets only."""
import contextlib
import hashlib
import select
import socket
import socketserver
import struct
import subprocess
import sys
import threading
import time
import unittest


BINARY = sys.argv.pop(1)


def receive_exact(sock, count):
    result = bytearray()
    while len(result) < count:
        chunk = sock.recv(count - len(result))
        if not chunk:
            raise AssertionError(f"unexpected EOF: {len(result)}/{count} bytes")
        result.extend(chunk)
    return bytes(result)


class Echo(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(5)
        try:
            while data := self.request.recv(32768):
                self.request.sendall(data)
        except (OSError, TimeoutError):
            pass


class Upload(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(5)
        digest = hashlib.sha256()
        try:
            while data := self.request.recv(32768):
                digest.update(data)
            # Response must survive the client's write-side EOF.
            time.sleep(0.05)
            self.request.sendall(digest.digest())
        except (OSError, TimeoutError):
            pass


class Stall(socketserver.BaseRequestHandler):
    """Reads to EOF, then keeps its side open without answering."""
    def handle(self):
        self.request.settimeout(5)
        try:
            while self.request.recv(32768):
                pass
            time.sleep(4)
        except (OSError, TimeoutError):
            pass


class SlowStream(socketserver.BaseRequestHandler):
    """After upload EOF, streams a response for longer than the idle bound."""
    def handle(self):
        self.request.settimeout(5)
        try:
            while self.request.recv(32768):
                pass
            for index in range(6):
                self.request.sendall(bytes([index]) * 1024)
                time.sleep(0.5)
        except (OSError, TimeoutError):
            pass


class Origin(socketserver.BaseRequestHandler):
    """Answers one request with the header it received, then honours close."""
    def handle(self):
        self.request.settimeout(5)
        data = b""
        try:
            while b"\r\n\r\n" not in data and (chunk := self.request.recv(4096)):
                data += chunk
            header = data.split(b"\r\n\r\n", 1)[0] + b"\r\n\r\n"
            self.request.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n" % len(header) + header)
            if b"\r\nConnection: close\r\n" not in header:
                time.sleep(4)  # A keep-alive origin would keep the tunnel open.
        except (OSError, TimeoutError):
            pass


class ThreadedServer(socketserver.ThreadingTCPServer):
    daemon_threads = True


class IPv6Server(ThreadedServer):
    address_family = socket.AF_INET6


@contextlib.contextmanager
def target(handler=Echo, ipv6=False):
    server_type = IPv6Server if ipv6 else ThreadedServer
    with server_type(("::1" if ipv6 else "127.0.0.1", 0), handler) as server:
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.02})
        thread.start()
        try:
            yield server.server_address[1]
        finally:
            server.shutdown()
            thread.join()


class ProductionProxyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.process = subprocess.Popen([BINARY, "--serve"], stdout=subprocess.PIPE)
        cls.addClassCleanup(cls.stop_process)
        if not select.select([cls.process.stdout], [], [], 10)[0]:
            raise AssertionError("production fixture did not start")
        cls.port = int(cls.process.stdout.readline())
        cls.closed_ports = set()
        cls.closed_changed = threading.Condition()
        threading.Thread(target=cls.read_terminations, daemon=True).start()

    @classmethod
    def read_terminations(cls):
        for line in cls.process.stdout:
            kind, _, port = line.decode().partition(" ")
            if kind == "closed":
                with cls.closed_changed:
                    cls.closed_ports.add(int(port))
                    cls.closed_changed.notify_all()

    def wait_session_closed(self, sock, timeout):
        port = sock.getsockname()[1]
        with self.closed_changed:
            return self.closed_changed.wait_for(lambda: port in self.closed_ports, timeout)

    @classmethod
    def stop_process(cls):
        cls.process.terminate()
        try:
            cls.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            cls.process.kill()
            cls.process.wait(timeout=5)

    def client(self):
        sock = socket.create_connection(("127.0.0.1", self.port), timeout=3)
        self.addCleanup(sock.close)
        return sock

    def send_fragments(self, sock, parts):
        for part in parts:
            sock.sendall(part)
            time.sleep(0.03)

    def http_request(self, port, host="127.0.0.1"):
        return f"CONNECT {host}:{port} HTTP/1.1\r\nHost: {host}:{port}\r\n\r\n".encode()

    def expect_connect(self, sock):
        expected = b"HTTP/1.1 200 Connection Established\r\n\r\n"
        self.assertEqual(receive_exact(sock, len(expected)), expected)

    def socks_command(self, port, kind=1):
        if kind == 1:
            address = socket.inet_aton("127.0.0.1")
        elif kind == 4:
            address = socket.inet_pton(socket.AF_INET6, "::1")
        else:
            address = b"\x09localhost"
        return bytes([5, 1, 0, kind]) + address + struct.pack("!H", port)

    def socks_auth(self, sock):
        sock.sendall(b"\x05\x01\x00")
        self.assertEqual(receive_exact(sock, 2), b"\x05\x00")

    def test_http_connect_fragmented(self):
        with target() as port:
            sock = self.client()
            req = self.http_request(port)
            self.send_fragments(sock, [req[:3], req[3:15], req[15:-1], req[-1:]])
            self.expect_connect(sock)
            sock.sendall(b"echo")
            self.assertEqual(receive_exact(sock, 4), b"echo")

    def test_connect_coalesced_payload(self):
        with target() as port:
            sock = self.client()
            payload = bytes(range(256))
            sock.sendall(self.http_request(port) + payload)
            self.expect_connect(sock)
            self.assertEqual(receive_exact(sock, len(payload)), payload)

    def test_http_ipv6(self):
        with target(ipv6=True) as port:
            sock = self.client()
            sock.sendall(self.http_request(port, "[::1]"))
            self.expect_connect(sock)
            sock.sendall(b"IPv6")
            self.assertEqual(receive_exact(sock, 4), b"IPv6")

    def test_http_binary_body_and_split_headers(self):
        with target() as port:
            for split in (False, True):
                with self.subTest(split=split):
                    sock = self.client()
                    body = bytes(range(256)) * 24
                    header = (f"POST http://127.0.0.1:{port}/upload?x=1 HTTP/1.1\r\n"
                              f"Host: 127.0.0.1:{port}\r\nProxy-Connection: keep-alive\r\n"
                              f"Proxy-Authorization: Basic c2VjcmV0\r\n"
                              f"Content-Length: {len(body)}\r\n\r\n").encode()
                    if split:
                        self.send_fragments(sock, [header[:-2], header[-2:] + body])
                    else:
                        sock.sendall(header + body)
                    # Origin-form request line, proxy fields stripped, body intact.
                    expected = (f"POST /upload?x=1 HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n"
                                f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n").encode() + body
                    self.assertEqual(receive_exact(sock, len(expected)), expected)

    def test_http_origin_form_uses_host(self):
        with target() as port:
            sock = self.client()
            sock.sendall(f"GET /health HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n\r\n".encode())
            expected = f"GET /health HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\n\r\n".encode()
            self.assertEqual(receive_exact(sock, len(expected)), expected)

    def test_http_forward_ends_with_origin_response(self):
        # A keep-alive client must not send its next request, possibly for
        # another host, down the tunnel bound to the first origin.
        with target(Origin) as port:
            sock = self.client()
            sock.sendall(f"GET http://127.0.0.1:{port}/a HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n"
                         "Connection: keep-alive, X-Hop\r\nX-Hop: drop\r\nX-Keep: 1\r\n\r\n".encode())
            forwarded = (f"GET /a HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n"
                         "X-Keep: 1\r\nConnection: close\r\n\r\n").encode()
            response = b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n" % len(forwarded) + forwarded
            self.assertEqual(receive_exact(sock, len(response)), response)
            self.assertEqual(sock.recv(1), b"")
            # The client keeps its side open, yet the session ends at once
            # rather than after the 2 s half-close idle bound.
            self.assertTrue(self.wait_session_closed(sock, 0.8))

    def test_http_malformed_forward_rejected(self):
        for request in (b"GET /x HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n",
                        b"GET /x HTTP/1.1\r\nHost: 127.0.0.1\r\nX: a\r\n folded\r\n\r\n",
                        b"GET https://127.0.0.1/ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"):
            with self.subTest(request=request):
                sock = self.client()
                sock.sendall(request)
                self.assertEqual(sock.recv(1), b"")

    def test_socks_greeting_and_connect_fragmented(self):
        with target() as port:
            for kind in (1, 3):
                with self.subTest(kind=kind):
                    sock = self.client()
                    self.send_fragments(sock, [b"\x05", b"\x02", b"\x02", b"\x00"])
                    self.assertEqual(receive_exact(sock, 2), b"\x05\x00")
                    cmd = self.socks_command(port, kind)
                    self.send_fragments(sock, [cmd[:4], cmd[4:5], cmd[5:-1], cmd[-1:]])
                    self.assertEqual(receive_exact(sock, 10)[1], 0)
                    sock.sendall(b"SOCKS")
                    self.assertEqual(receive_exact(sock, 5), b"SOCKS")

    def test_socks_ipv6_fragmented(self):
        with target(ipv6=True) as port:
            sock = self.client()
            self.socks_auth(sock)
            cmd = self.socks_command(port, 4)
            self.send_fragments(sock, [cmd[:4], cmd[4:12], cmd[12:]])
            self.assertEqual(receive_exact(sock, 10)[1], 0)
            sock.sendall(b"IPv6")
            self.assertEqual(receive_exact(sock, 4), b"IPv6")

    def test_socks_coalesced_greeting_command_payload(self):
        with target() as port:
            sock = self.client()
            sock.sendall(b"\x05\x01\x00" + self.socks_command(port) + b"payload")
            self.assertEqual(receive_exact(sock, 2), b"\x05\x00")
            self.assertEqual(receive_exact(sock, 10)[1], 0)
            self.assertEqual(receive_exact(sock, 7), b"payload")

    def test_socks_rejects_unoffered_auth(self):
        sock = self.client()
        sock.sendall(b"\x05\x01\x02")
        self.assertEqual(receive_exact(sock, 2), b"\x05\xff")
        self.assertEqual(sock.recv(1), b"")

    def test_socks_invalid_command_and_address(self):
        for cmd, status in [(b"\x05\x02\x00\x01", 7), (b"\x05\x01\x00\x09", 8),
                            (b"\x05\x01\x00\x03\x00", 8),
                            (b"\x05\x01\x00\x01\x7f\x00\x00\x01\x00\x00", 1)]:
            with self.subTest(cmd=cmd):
                sock = self.client()
                self.socks_auth(sock)
                sock.sendall(cmd)
                self.assertEqual(receive_exact(sock, 10)[1], status)
                self.assertEqual(sock.recv(1), b"")

    def test_upload_half_close_retains_response(self):
        with target(Upload) as port:
            # Repeated fresh sockets expose a terminal state callback racing
            # the final response's outstanding forwarding completion.
            for attempt, protocol in enumerate(("http", "socks") * 10):
                with self.subTest(protocol=protocol, attempt=attempt):
                    sock = self.client()
                    if protocol == "http":
                        sock.sendall(self.http_request(port))
                        self.expect_connect(sock)
                    else:
                        self.socks_auth(sock)
                        sock.sendall(self.socks_command(port))
                        self.assertEqual(receive_exact(sock, 10)[1], 0)
                    body = bytes(range(256)) * 8192  # 2 MiB
                    sock.sendall(body)
                    sock.shutdown(socket.SHUT_WR)
                    self.assertEqual(receive_exact(sock, 32), hashlib.sha256(body).digest())
                    self.assertEqual(sock.recv(1), b"")

    def test_coalesced_payload_and_early_fin(self):
        with target(Upload) as port:
            sock = self.client()
            body = b"upload-before-handshake-response"
            sock.sendall(self.http_request(port) + body)
            sock.shutdown(socket.SHUT_WR)
            self.expect_connect(sock)
            self.assertEqual(receive_exact(sock, 32), hashlib.sha256(body).digest())

    def test_stalled_half_close_is_reclaimed(self):
        # The fixture's half-close idle bound is 2 s; without it the session
        # and its slot would stay open until the peer finally closes.
        with target(Stall) as port:
            sock = self.client()
            sock.sendall(self.http_request(port))
            self.expect_connect(sock)
            sock.sendall(b"upload")
            sock.shutdown(socket.SHUT_WR)
            started = time.monotonic()
            try:
                self.assertEqual(sock.recv(1), b"")
            except ConnectionResetError:
                pass
            self.assertLess(time.monotonic() - started, 4)
            self.assertTrue(self.wait_session_closed(sock, 1))

    def test_active_response_after_half_close_outlives_idle_bound(self):
        with target(SlowStream) as port:
            sock = self.client()
            self.socks_auth(sock)
            sock.sendall(self.socks_command(port))
            self.assertEqual(receive_exact(sock, 10)[1], 0)
            sock.sendall(b"request")
            sock.shutdown(socket.SHUT_WR)
            expected = b"".join(bytes([index]) * 1024 for index in range(6))
            self.assertEqual(receive_exact(sock, len(expected)), expected)
            self.assertEqual(sock.recv(1), b"")

    def test_truncated_handshake_eof(self):
        for data in (b"CON", b"\x05", b"\x05\x02\x00"):
            with self.subTest(data=data):
                sock = self.client()
                sock.sendall(data)
                sock.shutdown(socket.SHUT_WR)
                self.assertEqual(sock.recv(1), b"")

    def test_header_size_limit(self):
        sock = self.client()
        sock.sendall(b"GET / HTTP/1.1\r\nX: " + b"a" * 65536)
        try:
            self.assertEqual(sock.recv(1), b"")
        except ConnectionResetError:
            pass  # Rejected without draining the oversized header.


if __name__ == "__main__":
    unittest.main(verbosity=2)
