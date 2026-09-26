#!/usr/bin/env python3
"""A small App Store Connect API client for CopyWell releases.

Authentication uses the team's API key in ~/.appstoreconnect/private_keys
(the place Xcode's tools look), its key id and the issuer id from the
environment: ASC_KEY_ID, ASC_ISSUER_ID. The key is read, used to sign a
short-lived token, and never printed.
"""
import hashlib
import json
import os
import sys
import time

import jwt
import requests

API = "https://api.appstoreconnect.apple.com"


class ASC:
    def __init__(self):
        self.key_id = os.environ["ASC_KEY_ID"]
        self.issuer = os.environ["ASC_ISSUER_ID"]
        path = os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{self.key_id}.p8")
        with open(path) as f:
            self._key = f.read()
        self._token = None
        self._token_time = 0

    def _auth(self):
        if not self._token or time.time() - self._token_time > 900:
            now = int(time.time())
            self._token = jwt.encode(
                {"iss": self.issuer, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
                self._key, algorithm="ES256", headers={"kid": self.key_id, "typ": "JWT"},
            )
            self._token_time = time.time()
        return {"Authorization": f"Bearer {self._token}"}

    def request(self, method, path, body=None, params=None, ok=(200, 201, 204)):
        url = path if path.startswith("http") else API + path
        for attempt in range(5):
            response = requests.request(method, url, headers={**self._auth(), "Content-Type": "application/json"},
                                        data=json.dumps(body) if body is not None else None, params=params, timeout=120)
            if response.status_code == 429 or response.status_code >= 500:
                time.sleep(2 + attempt * 3)
                continue
            break
        if response.status_code not in ok:
            raise RuntimeError(f"{method} {path} → {response.status_code}: {response.text[:800]}")
        return response.json() if response.content else {}

    def get(self, path, **params):
        return self.request("GET", path, params=params or None)

    def get_all(self, path, **params):
        items, url, first = [], path, True
        while url:
            page = self.request("GET", url, params=params if first else None)
            items += page.get("data", [])
            url = page.get("links", {}).get("next")
            first = False
        return items

    def post(self, path, body):
        return self.request("POST", path, body)

    def patch(self, path, body):
        return self.request("PATCH", path, body)

    def delete(self, path):
        return self.request("DELETE", path)

    # --- uploads ---------------------------------------------------------------

    def upload_screenshot(self, set_id, file_path):
        """Reserves, uploads and commits one screenshot into a screenshot set."""
        data = open(file_path, "rb").read()
        reservation = self.post("/v1/appScreenshots", {"data": {
            "type": "appScreenshots",
            "attributes": {"fileName": os.path.basename(file_path), "fileSize": len(data)},
            "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": set_id}}},
        }})["data"]
        for operation in reservation["attributes"]["uploadOperations"]:
            chunk = data[operation["offset"]:operation["offset"] + operation["length"]]
            headers = {h["name"]: h["value"] for h in operation.get("requestHeaders", [])}
            for attempt in range(4):
                put = requests.request(operation["method"], operation["url"], headers=headers, data=chunk, timeout=300)
                if put.status_code < 300:
                    break
                time.sleep(2 + attempt * 3)
            else:
                raise RuntimeError(f"upload chunk failed: {put.status_code}")
        self.patch(f"/v1/appScreenshots/{reservation['id']}", {"data": {
            "type": "appScreenshots", "id": reservation["id"],
            "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()},
        }})
        return reservation["id"]


if __name__ == "__main__":
    asc = ASC()
    print(json.dumps(asc.get(sys.argv[1]), indent=1)[:4000])
