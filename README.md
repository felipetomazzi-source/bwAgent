# BW Agent

A read-only agent that runs inside SAP BW (NetWeaver / ABAP) and bridges the
BW system to an external application over outbound HTTP(S).

The BW application server has outbound internet access even though interactive
(RDP) sessions do not, so **BW always initiates** every connection. The
external application never has to reach into BW. Communication follows a
**polling bridge** pattern:

1. BW polls the external app for pending work (HTTP `GET`).
2. BW executes the work locally (later phases: read BW metadata via the
   `/sap/bw/modeling/...` ADT services).
3. BW posts the result back to the external app (HTTP `POST`).

> Scope: this agent is **read-only** by design. It is intended to read BW
> metadata (e.g. ADSO definitions, BW query definitions). It does **not**
> trigger process chains, run DTPs, or change data.

## Phase 1 - connectivity test (this repo)

Phase 1 only proves the pipe works. It contains:

| Object | Type | Purpose |
|--------|------|---------|
| `ZCL_BW_AGENT_HTTP_CLIENT` | Class | Thin wrapper over `CL_HTTP_CLIENT` for outbound `GET`/`POST` with headers, optional API-key auth, timeout, and structured response/error capture. |
| `ZBW_AGENT_PING` | Report | Runs one `GET` (poll) + one `POST` (result/heartbeat) against the external app and prints the outcome. Changes nothing in BW. |

## External app contract (phase 1 default)

The report uses these two endpoints by default (both configurable on the
selection screen):

### `GET {base}/agent/poll`
Returns pending work, or an empty envelope when there is nothing to do. In
phase 1 the body is only displayed, not interpreted. A suggested shape for
later phases:

```json
{ "commands": [] }
```

### `POST {base}/agent/result`
Accepts a result / heartbeat. Phase 1 sends a fixed heartbeat payload so the
external side can confirm it received a `POST` from BW:

```json
{
  "agent": "ZBW_AGENT_PING",
  "host": "<app server host>",
  "sysid": "<SAP system id>",
  "client": "<client>",
  "user": "<executing user>",
  "timestamp": "YYYYMMDDThhmmss",
  "poll_ok": true,
  "poll_http_code": 200
}
```

The external app should return any `2xx` status to signal success.

## Running the test

1. Import the repo into the BW system with **abapGit** (`STARTING_FOLDER` is
   `/src/`, folder logic `PREFIX`). Assign a package when prompted.
2. Activate the objects.
3. Run report **`ZBW_AGENT_PING`** (`SA38` / `SE38`) and fill the selection
   screen:

   | Parameter | Meaning | Example |
   |-----------|---------|---------|
   | `P_BASE` | Base URL of the external app | `https://ext.example.com/api` |
   | `P_POLL` | Poll path (`GET`) | `/agent/poll` |
   | `P_RESP` | Result path (`POST`) | `/agent/result` |
   | `P_KEY` | API key (optional) | `abc123...` |
   | `P_KEYHDR` | Header name for the API key | `X-API-Key` |
   | `P_TOUT` | Receive timeout in seconds | `30` |

4. Read the output. It prints the HTTP code, reason and body for each step and
   ends with `RESULT: round-trip OK` or `FAILED`.

## HTTPS / infrastructure notes

Outbound HTTPS from ABAP requires the external site's certificate chain to be
trusted by the SAP server:

- Import the external site's certificate(s) into the **SSL Client (Standard)**
  PSE via transaction **`STRUST`**. The client uses SSL id `ANONYM`; adjust in
  `ZCL_BW_AGENT_HTTP_CLIENT->create_client` if your system uses a different
  SSL client PSE.
- If the app server reaches the internet through a **proxy**, set it on the
  HTTP client (`set_proxy(...)`) - not yet wired into the wrapper; add it in
  `create_client` if needed.
- Authentication in phase 1 is an optional **API key** header. Bearer/OAuth can
  be added later by passing extra headers to `get`/`post`.

Common failure causes if the test reports `FAILED`:

- TLS certificate not trusted (STRUST) - typically an SSL handshake error.
- Wrong base URL, or a proxy is required.
- Auth rejected by the external app (`401`/`403`).

## Roadmap (later phases, not in this repo yet)

- **Phase 2:** call the local `/sap/bw/modeling/...` ADT endpoints to read
  metadata (ADSO, query definitions), returning the result to the external app.
- **Phase 3:** a dispatcher mapping a small, explicit **allow-list** of
  read-only commands to specific modeling endpoints, plus scheduling as a
  background job (`SM36`) and logging (BAL / `SLG1`).
