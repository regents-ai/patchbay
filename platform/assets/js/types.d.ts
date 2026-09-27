declare module "phoenix" {
  export const Socket: unknown
}

declare module "phoenix_html"

declare module "phoenix-colocated/patchbay" {
  export const hooks: Record<string, object>
}

declare module "*.css"

// esbuild replaces this with "development" or "production" when it bundles.
declare const process: {env: {NODE_ENV: string}}
