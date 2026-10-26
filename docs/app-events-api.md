# App events API

The app reports anonymous usage counts so hideip.net can see its funnel
(opened, added a server, tunnel came up, saw the plans) and how many phones
use the app, with which kind of server and from which country. The client is
`lib/core/app_telemetry.dart`; this document is the contract the hideip.net
backend implements (`src/app/api/app/events`, tables `hideip.app_event_daily`
and `hideip.app_usage_daily`).

## Privacy

The store declarations say "Data Not Collected". What keeps that true is
what the server does with a request, not only what the request holds:

- The body is the event name, the platform and labels from the closed lists
  below. Never a device or advertising identifier, an account number, a
  server address, a link, a name or a precise time.
- The server never stores the request. It turns it into a few "+1"s on daily
  totals, each total keyed by the day, the platform and at most two labels
  from a fixed list of pairs, and drops it. It sets no cookie and keeps the
  IP only in the in-memory rate limiter.
- The country is a two-letter code the phone reports (mobile network, SIM or
  region setting). The server does not look up the IP: through a tunnel that
  would be the exit server's country.
- One-shot events are sent at most once per install, the active ping at most
  once per local day. A local flag remembers each.
- The user can switch it off in Settings ("Anonymous usage counts"). Off
  means no request is made at all.

## Endpoint

`POST https://hideip.net/api/app/events`

```
{"event": "first_open", "platform": "android", "country": "IR", "channel": "play"}
{"event": "first_profile", "platform": "ios", "kind": "own", "source": "sub"}
{"event": "first_connect", "platform": "android", "country": "IR", "kind": "own"}
{"event": "first_paywall", "platform": "ios", "from": "locations"}
{"event": "active", "platform": "android", "kind": "own", "source": "sub",
 "proto": "vless", "channel": "play", "version": "1.2.1", "country": "IR",
 "age": "d7_29", "new_week": true, "new_month": false}
```

`event` is one of `first_open`, `first_profile`, `first_connect`,
`first_paywall`, `active`. `platform` is `android` or `ios`. Version 1
clients (1.2.0 and older) send only those two fields; they are still
accepted and counted as totals.

| Field       | Values                                                                 |
|-------------|------------------------------------------------------------------------|
| `kind`      | `own`, `premium`, `free` (required for `active`)                       |
| `source`    | `sub`, `link`, `wg`, `paste`, `premium`, `free`                        |
| `proto`     | `vless`, `vmess`, `trojan`, `shadowsocks`, `shadowtls`, `hysteria2`, `tuic`, `wireguard`, `socks`, `http`, `anytls`, `other` |
| `channel`   | `play`, `appstore`, `apk`, `fdroid`                                    |
| `from`      | `onboarding`, `home`, `locations`, `settings`, `account`, `trial_expired`, `other` |
| `age`       | `d0`, `d1_6`, `d7_29`, `d30` (days since install)                      |
| `country`   | ISO 3166-1 alpha-2, omitted when the phone has none                    |
| `version`   | the app version, `x.y.z`                                               |
| `new_week`  | true on the first accepted `active` ping of the phone's ISO week       |
| `new_month` | true on the first accepted `active` ping of the phone's month          |

A value outside its list is counted as `other` (country `ZZ`) rather than
refused, so a newer client still lands. The pairs the server keeps:

| Event           | Pairs                                                               |
|-----------------|---------------------------------------------------------------------|
| `first_open`    | country; channel                                                    |
| `first_profile` | kind × source                                                       |
| `first_connect` | country × kind                                                      |
| `first_paywall` | from                                                                |
| `active`        | country × kind; kind × source; kind × proto; channel × version; age × kind, each as `dau`, plus `wau` / `mau` when the flag is set |

Summing `wau` over a calendar week and `mau` over a calendar month gives
unique phones without an identifier.

Responses: `200 {"ok": true}` on success; `400 {"error": "invalid_event"}`
(unknown event or platform, or `active` without `kind`); `429` with
`Retry-After` when rate limited; `503` when the database is down. The client
treats anything but 200 as "try again on the next trigger".

## Triggers in the app

| Event           | When                                                        |
|-----------------|-------------------------------------------------------------|
| `first_open`    | first `AppState.init()` after install                        |
| `first_profile` | first time servers are added (kind and source of the first) |
| `first_connect` | first time the tunnel reaches `connected`                   |
| `first_paywall` | first time the plans screen opens                           |
| `active`        | a tunnel reaches `connected`, or the app finds one already up; once per local day |

Trial starts and purchases are not app events: the stores report them to the
provisioning backend, which counts them server-side.
