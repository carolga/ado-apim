import importlib.util
import json
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]


def load_script(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / "repro" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


repro = load_script("repro")


class ReproTests(unittest.TestCase):
    def test_sse_matches_response_after_notification_and_multiline_data(self):
        body = (
            ': ping\n\ndata: {"jsonrpc":"2.0","method":"notifications/message"}\n\n'
            'event: message\r\ndata: {"jsonrpc":"2.0",\r\n'
            'data: "id":4,"result":{"tools":[]}}\r\n\r\n'
        )
        self.assertEqual(repro.rpc_result(body, "text/event-stream; charset=utf-8", 4), {"tools": []})

    def test_rpc_errors_are_not_successful_tool_results(self):
        body = '{"jsonrpc":"2.0","id":4,"error":{"code":-32602,"message":"invalid"}}'
        with self.assertRaisesRegex(RuntimeError, "-32602"):
            repro.rpc_result(body, "application/json", 4)
        with self.assertRaisesRegex(ValueError, "No matching"):
            repro.rpc_result('{"id":5,"result":{}}', "application/json", 4)

    def test_tool_error_in_successful_http_response_is_failure(self):
        self.assertEqual(
            repro.tool_outcome({"content": [{"text": "VS30063: Not authorized"}]}),
            "ado_unauthorized",
        )
        self.assertEqual(repro.tool_outcome({"isError": True, "content": []}), "tool_error")
        self.assertEqual(repro.tool_outcome({}), "invalid_tool_result")
        self.assertEqual(repro.tool_outcome({"content": []}), "success")

    def test_path_comparison_invokes_only_read_only_tool_after_discovery(self):
        class FakeResponse:
            headers = {"content-type": "application/json"}

            def __init__(self, value):
                self.text = json.dumps(value)

            def raise_for_status(self):
                pass

        class FakeClient:
            def __init__(self):
                self.requests = []

            def post(self, url, *, headers, json):
                self.requests.append(json)
                self_test.assertEqual(headers["X-MCP-Readonly"], "true")
                method = json["method"]
                if method == "initialize":
                    result = {"protocolVersion": "2025-06-18"}
                elif method == "notifications/initialized":
                    return FakeResponse({})
                elif method == "tools/list":
                    if "cursor" not in json["params"]:
                        result = {"tools": [], "nextCursor": "page2"}
                    else:
                        result = {"tools": [{"name": "core_list_projects"}]}
                else:
                    self_test.assertEqual(json["params"], {"name": "core_list_projects", "arguments": {}})
                    result = {"content": [{"type": "text", "text": "VS30063"}]}
                return FakeResponse({"id": json["id"], "result": result})

        self_test = self
        client = FakeClient()
        result = repro.test_endpoint(client, "https://example.test/mcp", "test-token")
        self.assertEqual(result, {"stage": "tools/call", "outcome": "ado_unauthorized"})
        self.assertEqual(client.requests[-1]["method"], "tools/call")

    def test_foundry_client_targets_agent_without_authenticating(self):
        from azure.ai.projects import AIProjectClient
        from azure.identity import DeviceCodeCredential

        with DeviceCodeCredential(tenant_id="organizations") as credential:
            with AIProjectClient(
                endpoint="https://example.services.ai.azure.com/api/projects/test",
                credential=credential, allow_preview=True,
            ) as project:
                with project.get_openai_client(agent_name="ado-demo") as client:
                    self.assertIn("/agents/ado-demo/endpoint/protocols/openai", str(client.base_url))

    def test_generated_chain_and_trust_merge_without_azure_calls(self):
        from cryptography import x509
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.serialization import pkcs12
        from cryptography.x509.oid import ExtensionOID

        generator = load_script("create_certificates")
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(sys, "argv", ["create_certificates.py", "--output-directory", directory]):
                with patch.object(generator, "getpass", return_value="disposable-test-passphrase"):
                    generator.main()
            ca_path = Path(directory) / "ca.pem"
            pem = ca_path.read_bytes()
            self.assertNotIn(b"PRIVATE KEY", pem)
            ca = x509.load_pem_x509_certificate(pem)
            ca.verify_directly_issued_by(ca)
            key, leaf, chain = pkcs12.load_key_and_certificates(
                (Path(directory) / "gateway.pfx").read_bytes(),
                b"disposable-test-passphrase",
            )
            self.assertIsNotNone(key)
            self.assertEqual(len(chain), 1)
            leaf.verify_directly_issued_by(ca)
            self.assertEqual(
                leaf.extensions.get_extension_for_oid(ExtensionOID.SUBJECT_ALTERNATIVE_NAME)
                .value.get_values_for_type(x509.DNSName),
                ["mcp.repro.test"],
            )
            self.assertIsNotNone(ca.extensions.get_extension_for_oid(ExtensionOID.AUTHORITY_KEY_IDENTIFIER))
            self.assertIsNotNone(leaf.extensions.get_extension_for_oid(ExtensionOID.SUBJECT_KEY_IDENTIFIER))
            leaf_path = Path(directory) / "leaf.pem"
            key_path = Path(directory) / "leaf.key"
            leaf_path.write_bytes(leaf.public_bytes(serialization.Encoding.PEM))
            key_path.write_bytes(key.private_bytes(
                serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                serialization.BestAvailableEncryption(b"disposable-test-passphrase"),
            ))
            server_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            server_context.load_cert_chain(leaf_path, key_path, "disposable-test-passphrase")
            client_context = ssl.create_default_context(cafile=str(ca_path))
            client_context.verify_flags |= ssl.VERIFY_X509_STRICT
            server_errors = []
            with socket.socket() as listener:
                listener.bind(("127.0.0.1", 0))
                listener.listen(1)
                listener.settimeout(5)

                def serve():
                    try:
                        connection, _ = listener.accept()
                        connection.settimeout(5)
                        with server_context.wrap_socket(connection, server_side=True) as tls:
                            if tls.recv(1) != b"x":
                                raise ValueError("Unexpected local TLS test payload.")
                            tls.sendall(b"y")
                    except (OSError, ssl.SSLError) as error:
                        server_errors.append(error)

                server = threading.Thread(target=serve)
                server.start()
                try:
                    with socket.create_connection(listener.getsockname(), timeout=5) as connection:
                        with client_context.wrap_socket(connection, server_hostname="mcp.repro.test") as tls:
                            self.assertIsNotNone(tls.cipher())
                            tls.sendall(b"x")
                            self.assertEqual(tls.recv(1), b"y")
                finally:
                    server.join(timeout=10)
                self.assertFalse(server.is_alive())
                self.assertEqual(server_errors, [])
            subprocess.run(
                ["pwsh", "-NoLogo", "-NoProfile", "-File", str(ROOT / "tests" / "Test-ReproTrust.ps1"),
                 "-PublicCaPem", str(ca_path)],
                check=True,
            )


if __name__ == "__main__":
    unittest.main()
