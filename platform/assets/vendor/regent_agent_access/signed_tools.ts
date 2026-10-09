// Transport only. SIWA's existing signer owns keys, receipts and signatures.
export type InputSchema = {
  type: string
  properties?: Record<string, InputSchema>
  required?: readonly string[]
  additionalProperties?: boolean
  items?: InputSchema
  enum?: readonly unknown[]
  minLength?: number
  maxLength?: number
  minItems?: number
  maxItems?: number
  minProperties?: number
  maxProperties?: number
  minimum?: number
  maximum?: number
  maxBytes?: number
}
export type SignedOperation = {
  name: string
  route: string
  authentication: string
  availability: string
  operation_id_field?: string
  input_schema: Omit<InputSchema, "type"> & {type?: string; properties: Record<string, InputSchema>}
  request_body?: {encoding: "raw_json"; field: string; maxBytes: number}
}
export type PreparedRequest = {
  operation: string
  audience: string
  origin: string
  method: string
  path: string
  body?: string
}
export type SignedInput = {input: Record<string, unknown>; request: PreparedRequest; proof: Record<string, string>}

const MAX_BODY_BYTES = 2_097_152
const encoder = new TextEncoder()
const plainObject = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === "object" &&
  [Object.prototype, null].includes(Object.getPrototypeOf(value))

// A deliberately small manifest subset, not a general JSON Schema engine.
function validateInput(input: Record<string, unknown>, schema: SignedOperation["input_schema"], rawField?: string,
  stringLimit = 10_000, collectionLimit = 100) {
  let nodes = 0
  let bytes = 0
  function countBytes(value: string) {
    bytes += encoder.encode(value).length
    if (bytes > MAX_BODY_BYTES) throw new Error("body_too_large")
  }
  function validate(value: unknown, field: InputSchema | undefined, key: string, depth: number): void {
    if (++nodes > 10_000 || depth > 16) throw new Error("input_complexity_exceeded")
    const invalid = () => {throw new Error(`invalid_field:${key}`)}
    if (field && typeof field.type !== "string") throw new Error("unsupported_field_type")
    const type = field?.type ?? (value === null ? "null" : Array.isArray(value) ? "array" : typeof value)
    switch (type) {
      case "string":
        if (typeof value !== "string" || value.length < (field?.minLength ?? 0) ||
            value.length > Math.min(field?.maxLength ?? (key === rawField ? MAX_BODY_BYTES : stringLimit), MAX_BODY_BYTES)) invalid()
        // Raw text has its own exact byte check; do not count its input wrapper.
        if (key !== rawField) countBytes(value as string)
        break
      case "integer":
      case "number":
        if (typeof value !== "number" || !Number.isFinite(value) ||
            (type === "integer" && !Number.isSafeInteger(value)) ||
            value < (field?.minimum ?? -Infinity) || value > (field?.maximum ?? Infinity)) invalid()
        break
      case "boolean":
        if (typeof value !== "boolean") invalid()
        break
      case "null":
        if (value !== null) invalid()
        break
      case "array": {
        if (!Array.isArray(value)) return invalid()
        if (value.length < (field?.minItems ?? 0) || value.length > Math.min(field?.maxItems ?? collectionLimit, 10_000) ||
            (field && !field.items) || Object.keys(value).length !== value.length) invalid()
        for (let index = 0; index < value.length; index++) validate(value[index], field?.items, `${key}[${index}]`, depth + 1)
        break
      }
      case "object": {
        if (!plainObject(value)) return invalid()
        const keys = Object.keys(value)
        if (keys.length < (field?.minProperties ?? 0) || keys.length > Math.min(field?.maxProperties ?? collectionLimit, 10_000)) invalid()
        for (const required of field?.required ?? []) {
          if (!Object.hasOwn(value, required)) throw new Error(`missing_field:${key ? key + "." : ""}${required}`)
        }
        for (const entry of keys) {
          countBytes(entry)
          const child = field?.properties && Object.hasOwn(field.properties, entry) ? field.properties[entry] : undefined
          if (field && !child && field.additionalProperties !== true) throw new Error(`invalid_field:${key ? key + "." : ""}${entry}`)
          validate(value[entry], child, key ? `${key}.${entry}` : entry, depth + 1)
        }
        break
      }
      default: throw new Error(`unsupported_field_type:${type}`)
    }
    if (field?.enum && !field.enum.some(entry => JSON.stringify(entry) === JSON.stringify(value))) invalid()
    if (field?.maxBytes !== undefined && encoder.encode(typeof value === "string" ? value : JSON.stringify(value)).length > field.maxBytes) invalid()
  }
  if (schema.type && schema.type !== "object") throw new Error(`unsupported_field_type:${schema.type}`)
  validate(input, {...schema, type: "object", additionalProperties: false}, "", 0)
}

export function signedTools(config: {
  origin: string
  trustedOrigins: readonly string[]
  audience: string
  operations: readonly SignedOperation[]
  proofHeaders: readonly string[]
}) {
  const origin = new URL(config.origin).origin
  if (origin !== config.origin || !config.trustedOrigins.includes(origin)) throw new Error("untrusted_origin")
  if (!/^https:\/\//.test(origin) && !/^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(origin)) {
    throw new Error("insecure_origin")
  }

  function prepare(name: string, input: Record<string, unknown>): PreparedRequest {
    const operation = config.operations.find(entry => entry.name === name)
    if (!operation || operation.authentication !== "siwa_per_request" || operation.availability !== "available") {
      throw new Error("operation_unavailable")
    }
    if (!plainObject(input)) throw new Error("invalid_input")
    const raw = operation.request_body
    if (raw && (raw.encoding !== "raw_json" || !Number.isSafeInteger(raw.maxBytes) ||
        raw.maxBytes < 1 || raw.maxBytes > MAX_BODY_BYTES ||
        !Object.hasOwn(operation.input_schema.properties, raw.field) ||
        operation.input_schema.properties[raw.field].type !== "string")) throw new Error("invalid_operation")
    validateInput(input, operation.input_schema, raw?.field)
    const [method, template, extra] = operation.route.split(" ")
    if (extra || !["GET", "POST", "PATCH", "DELETE"].includes(method)) throw new Error("invalid_operation")
    const body = {...input}
    const path = template.replace(/\{([a-z_]+)\}/g, (_match, field: string) => {
      const value = body[field]
      if (!Object.hasOwn(body, field) || typeof value !== "string" || !value || value === "." || value === ".." || field === raw?.field) throw new Error(`invalid_path_field:${field}`)
      delete body[field]
      return encodeURIComponent(value)
    })
    // No arbitrary destinations, redirects, fragments or unsigned queries.
    const target = new URL(path, origin)
    if (!path.startsWith("/") || path.startsWith("//") || target.origin !== origin ||
        target.pathname !== path || target.search || target.hash || /[{}\\]/.test(path)) throw new Error("invalid_path")
    if (method === "GET" && Object.keys(body).length) throw new Error("unexpected_read_body")
    const request: PreparedRequest = {operation: name, audience: config.audience, origin, method, path}
    if (method !== "GET") {
      if (raw) {
        const text = body[raw.field]
        if (typeof text !== "string" || Object.keys(body).some(key => key !== raw.field)) throw new Error("invalid_raw_body")
        const bytes = encoder.encode(text)
        if (bytes.length > raw.maxBytes) throw new Error("body_too_large")
        // Reject text that fetch would change when converting it to UTF-8.
        if (new TextDecoder().decode(bytes) !== text) throw new Error("invalid_raw_body")
        let parsed: unknown
        try {parsed = JSON.parse(text)} catch {throw new Error("invalid_raw_body")}
        // The original text stays untouched; parsing only checks JSON and bounds.
        validateInput({value: parsed}, {properties: {value: {type: "object", additionalProperties: true}}}, undefined, MAX_BODY_BYTES, 10_000)
        if (operation.operation_id_field && (!plainObject(parsed) || !parsed[operation.operation_id_field])) throw new Error("operation_id_required")
        request.body = text
      } else {
        if (operation.operation_id_field && !body[operation.operation_id_field]) throw new Error("operation_id_required")
        request.body = JSON.stringify(body)
        if (encoder.encode(request.body).length > MAX_BODY_BYTES) throw new Error("body_too_large")
      }
    }
    return Object.freeze(request)
  }

  async function execute(name: string, signed: SignedInput, signal?: AbortSignal): Promise<Response> {
    if (!signed || typeof signed !== "object") throw new Error("signed_request_required")
    const expected = prepare(name, signed.input)
    if (!signed.request || Object.keys(signed.request).some(key => !Object.hasOwn(expected, key)) ||
        Object.entries(expected).some(([key, value]) => signed.request[key as keyof PreparedRequest] !== value)) {
      throw new Error("prepared_request_mismatch")
    }
    if (!signed.proof || typeof signed.proof !== "object" || Array.isArray(signed.proof)) throw new Error("proof_required")
    const allowed = new Set(config.proofHeaders)
    const headers: Record<string, string> = {accept: "application/json"}
    for (const [key, value] of Object.entries(signed.proof)) {
      const name = key.toLowerCase()
      if (!allowed.has(name)) continue
      if (Object.hasOwn(headers, name) || typeof value !== "string" || !value || /[\r\n]/.test(value)) throw new Error("invalid_proof")
      headers[name] = value
    }
    for (const name of allowed) {
      if (name !== "content-digest" && !headers[name]) throw new Error("incomplete_proof")
    }
    if (expected.body !== undefined) {
      if (!headers["content-digest"]) throw new Error("body_proof_required")
      headers["content-type"] = "application/json"
    } else if (headers["content-digest"]) throw new Error("unexpected_body_proof")
    // The product verifies once through SIWA. No retry, session fallback or reserialization.
    return fetch(origin + expected.path, {
      method: expected.method, body: expected.body, headers, credentials: "omit",
      cache: "no-store", redirect: "error", signal,
    })
  }
  return {prepare, execute}
}
