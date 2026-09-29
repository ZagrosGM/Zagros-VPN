# Mandatory connection lifecycle

Every client connection implementation must preserve the SDK reliability and lease contract. Flutter orchestrates this behavior; it must not duplicate or weaken it.

## 1. Immediate list → select → consume

A config list response contains short-lived consume authority. Every new list call supersedes previous unconsumed grants. The client must therefore:

1. list available descriptors;
2. select one descriptor locally; and
3. immediately consume that descriptor without another list request in between.

## 2. Bounded transparent expiry recovery

Config envelopes may expire after approximately 30 seconds and grants after approximately 60 seconds. Latency-prone networks, including unreliable networks in Iran, must not leave a user with an opaque expiry error. On a recognized pre-connect envelope/grant expiry, invoke the SDK's bounded fresh-authority recovery path, safely repeat list → select → consume, and preserve the user's selected logical config where still available.

Retry must be bounded, cancelable, and limited to explicitly retryable authority-expiry failures. Authentication, policy, revocation, signature, pinning, and malformed-response failures fail closed and are not converted into retry loops.

## 3. Proactive lease renewal

Application-mode connection leases are short lived: 60–300 seconds, with a default of 120 seconds. Start the SDK lifecycle coordinator after authoritative tunnel establishment, renew before expiry using its calculated schedule, and terminate the tunnel if authority is revoked or a terminal renewal failure occurs. Network failures use bounded SDK backoff and may not extend server authority indefinitely.

## State ownership

- SDK: acquisition authority, consume/decrypt, retry classification, renewal schedule, and lease semantics.
- Flutter: user intent, cancelation, and presentation of safe lifecycle state.
- Native adapter: OS/engine tunnel establishment, traffic counters where available, disconnect, and authoritative native status.

A running process, open port, or listener is not proof of a VPN. Acceptance requires authenticated delivery, tunnel establishment, real routed traffic, and observed enforcement/accounting.
