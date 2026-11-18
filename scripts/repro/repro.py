"""Read-only ADO MCP path comparison and Foundry OAuth diagnostics."""

import argparse
from collections import Counter
import json
import ssl
import sys
from urllib.parse import urlsplit


def https_url(value):
    url = urlsplit(value)
    if (
        url.scheme != "https" or not url.hostname or url.username or url.password
        or url.query or url.fragment
    ):
        raise argparse.ArgumentTypeError("Use an HTTPS URL without credentials, query, or fragment.")
    return value.rstrip("/")


def rpc_result(text, content_type, request_id):
    """Find the matching JSON-RPC response, including multiline SSE data."""
    messages = []
    if "text/event-stream" in content_type.lower():
        data = []
        for line in text.replace("\r\n", "\n").split("\n") + [""]:
            if line == "":
                if data:
                    messages.append(json.loads("\n".join(data)))
                    data = []
            elif line.startswith("data:"):
                data.append(line[5:].removeprefix(" "))
    else:
        messages.append(json.loads(text))
    for message in messages:
        if isinstance(message, dict) and message.get("id") == request_id:
            if "error" in message:
                raise RuntimeError(f"JSON-RPC error code: {message['error'].get('code')}")
            if "result" not in message:
                raise ValueError("JSON-RPC response has no result.")
            return message["result"]
    raise ValueError("No matching JSON-RPC response was received.")


def tool_outcome(result):
    if "VS30063" in json.dumps(result):
        return "ado_unauthorized"
    if result.get("isError"):
        return "tool_error"
    if "content" not in result and "structuredContent" not in result:
        return "invalid_tool_result"
    return "success"


def test_endpoint(client, endpoint, token):
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json, text/event-stream",
        "X-MCP-Readonly": "true",
        "X-MCP-Toolsets": "core",
    }
    request_id = 0
    stage = "initialize"

    def request(method, params):
        nonlocal request_id
        request_id += 1
        response = client.post(
            endpoint, headers=headers,
            json={"jsonrpc": "2.0", "id": request_id, "method": method, "params": params},
        )
        response.raise_for_status()
        if response.headers.get("mcp-session-id"):
            headers["Mcp-Session-Id"] = response.headers["mcp-session-id"]
        return rpc_result(response.text, response.headers.get("content-type", ""), request_id)

    try:
        initialized = request("initialize", {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "ado-foundry-repro", "version": "1.0"},
        })
        headers["MCP-Protocol-Version"] = initialized["protocolVersion"]
        stage = "notifications/initialized"
        notification = client.post(
            endpoint, headers=headers,
            json={"jsonrpc": "2.0", "method": "notifications/initialized"},
        )
        notification.raise_for_status()
        stage = "tools/list"
        catalog = request("tools/list", {})
        seen_cursors = set()
        while not any(tool["name"] == "core_list_projects" for tool in catalog["tools"]):
            cursor = catalog.get("nextCursor")
            if not cursor or cursor in seen_cursors:
                return {"stage": stage, "outcome": "core_list_projects_missing"}
            seen_cursors.add(cursor)
            catalog = request("tools/list", {"cursor": cursor})
        stage = "tools/call"
        result = request("tools/call", {"name": "core_list_projects", "arguments": {}})
        return {"stage": stage, "outcome": tool_outcome(result)}
    except (RuntimeError, ValueError, KeyError) as error:
        return {
            "stage": stage, "outcome": "protocol_error",
            "error_type": type(error).__name__, "detail": str(error),
        }


def run_mcp(args):
    import httpx
    from azure.identity import DeviceCodeCredential

    context = ssl.create_default_context()
    if args.ca_bundle:
        context.load_verify_locations(cafile=args.ca_bundle)
    with DeviceCodeCredential(tenant_id=args.tenant_id, client_id=args.client_id) as credential:
        token = credential.get_token("https://mcp.dev.azure.com/.default").token
        with httpx.Client(verify=context, timeout=90, follow_redirects=False) as client:
            results = {}
            for name, endpoint in (
                ("direct", args.direct_url),
                ("http_proxy", args.proxy_url),
                ("native_mcp", args.native_url),
            ):
                try:
                    results[name] = test_endpoint(client, endpoint, token)
                except httpx.HTTPStatusError as error:
                    results[name] = {
                        "outcome": "http_error",
                        "http_status": error.response.status_code,
                    }
                except httpx.RequestError as error:
                    results[name] = {
                        "outcome": "transport_error",
                        "error_type": type(error).__name__,
                        "tls_verification_failed": "CERTIFICATE_VERIFY_FAILED" in str(error),
                    }
            print(json.dumps(results, indent=2))
            return 0 if all(value["outcome"] == "success" for value in results.values()) else 1


def summarize_foundry(response):
    calls = [item for item in response.output if item.type == "mcp_call"]
    return {
        "response_id": response.id,
        "status": response.status,
        "response_error": response.error is not None,
        "item_types": dict(Counter(item.type for item in response.output)),
        "mcp_calls": [
            {
                "name": item.name,
                "status": item.status,
                "has_error": item.error is not None,
                "ado_unauthorized": "VS30063" in (item.output or ""),
            }
            for item in calls
        ],
    }


def run_foundry(args):
    from azure.ai.projects import AIProjectClient
    from azure.identity import DeviceCodeCredential

    print("Foundry sign-in is separate from the MCP connection's OAuth consent.", file=sys.stderr)
    with DeviceCodeCredential(tenant_id=args.tenant_id) as credential:
        credential.authenticate(scopes=["https://ai.azure.com/.default"])
        with AIProjectClient(
            endpoint=args.project_endpoint, credential=credential, allow_preview=True,
        ) as project:
            client = project.get_openai_client(agent_name=args.agent_name)
            prompt = "Use the Azure DevOps MCP tool to list projects I can access. Do not modify anything."
            response = client.responses.create(input=prompt, tool_choice="required")
            print(json.dumps(summarize_foundry(response), indent=2))
            consent = [item for item in response.output if item.type == "oauth_consent_request"]
            if consent:
                print("Keep these consent links private. Open them manually to authorize.")
                for item in consent:
                    print(item.consent_link)
                if input("After successful consent, type yes to continue: ").strip().lower() != "yes":
                    print("Consent not confirmed; the tool test is incomplete.", file=sys.stderr)
                    return 2
                response = client.responses.create(
                    previous_response_id=response.id, input=prompt, tool_choice="required",
                )
                print(json.dumps(summarize_foundry(response), indent=2))
            summary = summarize_foundry(response)
            if any(item.type == "mcp_approval_request" for item in response.output):
                print("Tool approval is required; this script never auto-approves tools.", file=sys.stderr)
                return 2
            if not summary["mcp_calls"]:
                print("No MCP call completed; do not treat this as successful ADO access.", file=sys.stderr)
                return 2
            return 0 if (
                summary["status"] == "completed" and not summary["response_error"]
                and all(
                    call["status"] == "completed" and not call["has_error"]
                    and not call["ado_unauthorized"] for call in summary["mcp_calls"]
                )
            ) else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_subparsers(dest="mode", required=True)
    mcp = modes.add_parser("mcp", help="Compare three endpoints using the same delegated MCP token.")
    mcp.add_argument("--tenant-id", required=True)
    mcp.add_argument("--client-id", required=True, help="Your public-client app with Ado.Mcp.Tools consent.")
    mcp.add_argument("--direct-url", required=True, type=https_url)
    mcp.add_argument("--proxy-url", required=True, type=https_url)
    mcp.add_argument("--native-url", required=True, type=https_url)
    mcp.add_argument("--ca-bundle", help="Public CA PEM to add to normal TLS trust; never disables verification.")
    foundry = modes.add_parser("foundry", help="Inspect a single agent's MCP consent and tool calls.")
    foundry.add_argument("--tenant-id", required=True)
    foundry.add_argument("--project-endpoint", required=True, type=https_url)
    foundry.add_argument("--agent-name", required=True)
    args = parser.parse_args()
    return run_mcp(args) if args.mode == "mcp" else run_foundry(args)


if __name__ == "__main__":
    sys.exit(main())
