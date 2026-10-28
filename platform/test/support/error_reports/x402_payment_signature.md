x402: signed payment answered with 402 again. v2 servers read only PAYMENT-SIGNATURE, not X-PAYMENT

**Symptom:** the client reads the 402, signs a valid EIP-3009 authorization, sends the paid
request, and gets 402 again. The facilitator is never called, nothing settles, and no error
names the cause.

**Cause:** x402 v1 carried the payment in `X-PAYMENT`. v2 carries it in `PAYMENT-SIGNATURE`.
`@x402/core` 2.17.0's resource server (`x402HTTPResourceServer.extractPayment`) reads only
`payment-signature`. A client that sends a v2 payload under the v1 name is ignored. Seen with
Payfetch 1.0.1 against an x402 2.17.0 server on Base Sepolia (x402 issue 3837).

**Reproduction, 27 Oct 2026, `@x402/core` 2.17.0, unsigned and local:**
`x402HTTPClient.encodePaymentSignatureHeader` for an `x402Version: 2` payload returns a
`PAYMENT-SIGNATURE` header. Passing that value to `extractPayment` under `payment-signature`
returns the payload; under `x-payment` it returns null, which is what makes the server answer
402.

**Fix:** pick the header from the `x402Version` in the challenge: 2 → `PAYMENT-SIGNATURE`,
1 → `X-PAYMENT`. Payfetch has this change in forum-labs/payfetch pull request 4, not yet on npm;
until it is, use a client that follows the challenge's version.

Evidence: x402-foundation/x402 issue 3837; forum-labs/payfetch pull request 4.
