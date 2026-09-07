import json
import ssl
import urllib.request

BASE_URL = "https://erlite.example:8443"
TOKEN = "replace-with-service-token"
DATABASE_ID = "merchant-100"


def request(path, payload):
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        BASE_URL + path,
        data=body,
        method="POST",
        headers={
            "Authorization": f"Bearer {TOKEN}",
            "Content-Type": "application/json",
        },
    )
    context = ssl.create_default_context()  # verifies the server certificate
    with urllib.request.urlopen(req, context=context, timeout=20) as response:
        return json.load(response)


result = request(
    f"/v1/databases/{DATABASE_ID}/query",
    {"sql": "SELECT name FROM products WHERE sku = ?", "params": ["A1"]},
)
print(result)
