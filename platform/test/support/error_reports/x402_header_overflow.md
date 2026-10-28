x402 v2: "fetch failed" UND_ERR_HEADERS_OVERFLOW before the 402. PAYMENT-REQUIRED header past Node's 16 KB limit

**Error** (buyer side, `@x402/fetch` or plain `fetch` on Node):

    TypeError: fetch failed
    cause.code: UND_ERR_HEADERS_OVERFLOW  (Headers Overflow Error)

Python aiohttp fails the same way with
`ClientResponseError: 400, message='Got more than 8190 bytes when reading'`.

**Cause:** x402 v2 sends the whole PaymentRequired object, Bazaar discovery examples and schema
included, base64-encoded in one `PAYMENT-REQUIRED` header. Nothing limits its size. Node rejects
responses with more than 16 KB of headers; aiohttp rejects any header line over 8,190 bytes.
The client never sees the 402, and the error does not mention the seller (x402 issue 3803 found
live Bazaar sellers past both limits).

**Reproduction, 27 Oct 2026, Node 26.8.1, local server only, nothing signed:**

| PAYMENT-REQUIRED size | node | node --max-http-header-size=65536 |
| --- | --- | --- |
| 5,844 bytes | 402 read | 402 read |
| 15,176 bytes | 402 read | 402 read |
| 17,844 bytes | fetch failed, UND_ERR_HEADERS_OVERFLOW | 402 read |

**Fix for buyers:** on Node, start with `NODE_OPTIONS=--max-http-header-size=65536`. On Python,
use httpx or requests (which read 32 KB headers) rather than aiohttp.

**Fix for sellers:** keep `extensions.bazaar` input and output examples short, so the whole
header stays well under 8 KB. Check with
`curl -s -D - -o /dev/null <url> | grep -i payment-required | wc -c`.

**Still open:** the spec has no size budget for this header (x402 issue 3803).
